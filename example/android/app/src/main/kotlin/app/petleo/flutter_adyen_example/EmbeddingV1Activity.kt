package io.flutter.plugins.batteryexample

import dev.flutter.plugins.e2e.E2EPlugin
import io.flutter.app.FlutterActivity
import io.flutter.plugins.battery.BatteryPlugin

class EmbeddingV1Activity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        GeneratedPluginRegistrant.registerWith(this)
    }
}