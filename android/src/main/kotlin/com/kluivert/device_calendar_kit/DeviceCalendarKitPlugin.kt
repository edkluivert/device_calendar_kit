package com.kluivert.device_calendar_kit

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * The entry point the app registers when its engine starts, because
 * pubspec.yaml names it under `dartnative: plugin: platforms: android:`.
 *
 * Loads libdevice_calendar_kit.so before any Dart runs, which also runs the
 * C++ bridge's JNI_OnLoad on this thread, and hands the bridge the
 * application context. Nothing here talks to Dart.
 */
class DeviceCalendarKitPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            System.loadLibrary("device_calendar_kit")
        } catch (e: UnsatisfiedLinkError) {
            Log.e("DeviceCalendarKit", "libdevice_calendar_kit.so did not load: ${e.message}")
        }
        DeviceCalendarKitBridge.attach(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        DeviceCalendarKitBridge.detach()
    }
}
