import Adyen
import Adyen3DS2
import Flutter
import Foundation
import PassKit
import UIKit

struct PaymentError: Error {

}
struct PaymentCancelled: Error {

}
public class SwiftFlutterAdyenPlugin: NSObject, FlutterPlugin {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_adyen", binaryMessenger: registrar.messenger())
    let instance = SwiftFlutterAdyenPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  var dropInComponent: DropInComponent?
  var baseURL: String?
  var authToken: String?
  var merchantAccount: String?
  var clientKey: String?
  var currency: String?
  var amount: Int?
  var returnUrl: String?
  var reference: String?
  var applePay: String?
  var mResult: FlutterResult?
  var topController: UIViewController?
  var environment: String?
  var shopperReference: String?
  var lineItemJson: [String: String]?
  var shopperLocale: String?
  var additionalData: [String: String]?
  var shopperCountry: String?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method.elementsEqual("openDropIn") else { return }

    let arguments = call.arguments as? [String: Any]
    let paymentMethodsResponse = arguments?["paymentMethods"] as? String
    baseURL = arguments?["baseUrl"] as? String
    additionalData = arguments?["additionalData"] as? [String: String]
    clientKey = arguments?["clientKey"] as? String
    currency = arguments?["currency"] as? String
    amount = Int((arguments?["amount"] as? String)!)
    lineItemJson = arguments?["lineItem"] as? [String: String]
    environment = arguments?["environment"] as? String
    reference = arguments?["reference"] as? String
    applePay = arguments?["applePay"] as? String
    returnUrl = arguments?["returnUrl"] as? String
    shopperReference = arguments?["shopperReference"] as? String
    shopperLocale = String((arguments?["locale"] as? String)?.split(separator: "_").last ?? "DE")
    shopperCountry = arguments?["country"] as? String
    mResult = result

    guard let paymentData = paymentMethodsResponse?.data(using: .utf8),
      let paymentMethods = try? JSONDecoder().decode(PaymentMethods.self, from: paymentData)
    else {
      return
    }

    var apiContext = APIContext(environment: Environment.test, clientKey: clientKey!)

    if environment == "LIVE_US" {
      apiContext = APIContext(environment: Environment.liveUnitedStates, clientKey: clientKey!)
    } else if environment == "LIVE_AUSTRALIA" {
      apiContext = APIContext(environment: Environment.liveAustralia, clientKey: clientKey!)
    } else if environment == "LIVE_EUROPE" {
      apiContext = APIContext(environment: Environment.liveEurope, clientKey: clientKey!)
    }

    let dropInConfiguration = DropInComponent.Configuration(apiContext: apiContext)
    dropInConfiguration.card.showsHolderNameField = true

    // A set of line items that explain recurring payments, additional charges, and discounts.
    // https://developer.apple.com/documentation/apple_pay_on_the_web/applepaypaymentrequest/1916120-lineitems
    let summaryItems = [
        PKPaymentSummaryItem(label: lineItemJson!["description"] ?? "Product", amount: NSDecimalNumber.init(value: amount! / 100), type: .final)
    ]

    // See Apple Pay documentation https://docs.adyen.com/payment-methods/apple-pay/enable-apple-pay#create-merchant-identifier
    let applePayConfiguration = ApplePayComponent.Configuration(
      summaryItems: summaryItems,
      merchantIdentifier: applePay!)
    dropInConfiguration.applePay = applePayConfiguration
    let payment = Payment(
      amount: Adyen.Amount(
        value: amount!, currencyCode: currency!, localeIdentifier: shopperLocale!),
      countryCode: shopperCountry!
    )
    dropInConfiguration.payment = payment

    dropInComponent = DropInComponent(
      paymentMethods: paymentMethods, configuration: dropInConfiguration)
    dropInComponent?.finalizeIfNeeded(with: true)
    dropInComponent?.delegate = self

    if var topController = UIApplication.shared.keyWindow?.rootViewController,
      let dropIn = dropInComponent
    {
      self.topController = topController
      while let presentedViewController = topController.presentedViewController {
        topController = presentedViewController
      }
      topController.present(dropIn.viewController, animated: true)
    }
  }
}

extension SwiftFlutterAdyenPlugin: DropInComponentDelegate {
  public func didComplete(from component: DropInComponent) {
    self.topController?.dismiss(animated: true, completion: nil)
  }

  public func didSubmit(
    _ data: PaymentComponentData, for paymentMethod: PaymentMethod, from component: DropInComponent
  ) {
    guard let baseURL = baseURL, let url = URL(string: baseURL + "payments") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    // prepare json data
    let paymentMethod = data.paymentMethod.encodable
    let lineItem = try? JSONDecoder().decode(LineItem.self, from: JSONSerialization.data(withJSONObject: lineItemJson ?? ["":""]) )
    if lineItem == nil {
      self.didFail(with: PaymentError(), from: component)
      return
    }

    let paymentRequest = PaymentRequest(
      payment: AdyenPayment(
        paymentMethod: paymentMethod, lineItem: lineItem ?? LineItem(id: "", description: ""),
        currency: currency ?? "", amount: amount!, returnUrl: returnUrl ?? "",
        storePayment: data.storePaymentMethod, shopperReference: shopperReference,
        countryCode: shopperLocale, reference: reference ?? ""),
      additionalData: additionalData ?? [String: String]())

    do {
      let jsonData = try JSONEncoder().encode(paymentRequest)

      request.httpBody = jsonData
      URLSession.shared.dataTask(with: request) { data, response, error in
        if let data = data {
          self.finish(data: data, component: component)
        }
        if error != nil {
          self.didFail(with: PaymentError(), from: component)
        }
      }.resume()

    } catch {
      didFail(with: PaymentError(), from: component)
    }

  }

  func finish(data: Data, component: DropInComponent) {
    DispatchQueue.main.async {
      guard let response = try? JSONDecoder().decode(PaymentsResponse.self, from: data) else {
        self.didFail(with: PaymentError(), from: component)
        return
      }
      if let action = response.action {
        component.stopLoadingIfNeeded()
        component.handle(action)
      } else {
        component.stopLoadingIfNeeded()
        if response.resultCode == .authorised || response.resultCode == .received
          || response.resultCode == .pending, let result = self.mResult
        {
          result(response.resultCode.rawValue)
          self.topController?.dismiss(animated: false, completion: nil)
        } else if response.resultCode == .error || response.resultCode == .refused {
          self.didFail(with: PaymentError(), from: component)
        } else {
          self.didFail(with: PaymentCancelled(), from: component)
        }
      }
    }
  }

  public func didProvide(_ data: ActionComponentData, from component: DropInComponent) {
    guard let baseURL = baseURL, let url = URL(string: baseURL + "payments/details") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    let detailsRequest = DetailsRequest(
      paymentData: data.paymentData ?? "", details: data.details.encodable)
    do {
      let detailsRequestData = try JSONEncoder().encode(detailsRequest)
      request.httpBody = detailsRequestData
      URLSession.shared.dataTask(with: request) { data, response, error in
        if let response = response as? HTTPURLResponse {
          if response.statusCode != 200 {
            self.didFail(with: PaymentError(), from: component)
          }
        }
        if let data = data {
          self.finish(data: data, component: component)
        }

      }.resume()
    } catch {
      self.didFail(with: PaymentError(), from: component)
    }
  }

  public func didFail(with error: Error, from component: DropInComponent) {
    DispatchQueue.main.async {
      if error is PaymentCancelled {
        self.mResult?("PAYMENT_CANCELLED")
      } else if let componentError = error as? ComponentError,
        componentError == ComponentError.cancelled
      {
        self.mResult?("PAYMENT_CANCELLED")
      } else {
        self.mResult?("PAYMENT_ERROR")
      }
      self.topController?.dismiss(animated: true, completion: nil)
    }
  }
}

struct DetailsRequest: Encodable {
  let paymentData: String
  let details: AnyEncodable
}

struct PaymentRequest: Encodable {
  let payment: AdyenPayment
  let additionalData: [String: String]
}

struct AdyenPayment: Encodable {
  let paymentMethod: AnyEncodable
  let lineItems: [LineItem]
  let channel: String = "iOS"
  let additionalData = ["allow3DS2": "true"]
  let amount: Amount
  let reference: String
  let returnUrl: String
  let storePaymentMethod: Bool
  let shopperReference: String?
  let countryCode: String?

  init(
    paymentMethod: AnyEncodable, lineItem: LineItem, currency: String, amount: Int,
    returnUrl: String, storePayment: Bool, shopperReference: String?, countryCode: String?,
    reference: String
  ) {
    self.paymentMethod = paymentMethod
    self.lineItems = [lineItem]
    self.amount = Amount(currency: currency, value: amount)
    self.returnUrl = returnUrl
    self.shopperReference = shopperReference
    self.storePaymentMethod = storePayment
    self.countryCode = countryCode
    self.reference = reference
  }
}

struct LineItem: Codable {
  let id: String
  let description: String
}

struct Amount: Codable {
  let currency: String
  let value: Int
}

internal struct PaymentsResponse: Decodable {

  internal let resultCode: ResultCode

  internal let action: Action?

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.resultCode = try container.decode(ResultCode.self, forKey: .resultCode)
    self.action = try container.decodeIfPresent(Action.self, forKey: .action)
  }

  private enum CodingKeys: String, CodingKey {
    case resultCode
    case action
  }

}

extension PaymentsResponse {

  // swiftlint:disable:next explicit_acl
  enum ResultCode: String, Decodable {
    case authorised = "Authorised"
    case refused = "Refused"
    case pending = "Pending"
    case cancelled = "Cancelled"
    case error = "Error"
    case received = "Received"
    case redirectShopper = "RedirectShopper"
    case identifyShopper = "IdentifyShopper"
    case challengeShopper = "ChallengeShopper"
  }

}
