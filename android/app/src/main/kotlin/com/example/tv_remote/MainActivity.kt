package com.example.tv_remote

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.Settings
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** Set from Dart while the volume buttons should control the TV. */
    private var captureVolumeButtons = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tv_remote/phone").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "captureVolumeButtons" -> {
                        captureVolumeButtons = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    "openScreenCast" -> result.success(openScreenCast())
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        captureVolumeButtons = false
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val button = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> "up"
            KeyEvent.KEYCODE_VOLUME_DOWN -> "down"
            else -> null
        }
        val channel = channel
        if (button == null || !captureVolumeButtons || channel == null) {
            return super.dispatchKeyEvent(event)
        }
        // Held buttons send repeated key-downs, which repeat on the TV too.
        // Key-ups are swallowed as well, so the phone's volume panel never shows.
        if (event.action == KeyEvent.ACTION_DOWN) channel.invokeMethod("volumeButton", button)
        return true
    }

    /** Opens the system's list of screens to cast to; Chromecast TVs appear there. */
    private fun openScreenCast(): Boolean =
        try {
            startActivity(Intent(Settings.ACTION_CAST_SETTINGS))
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: SecurityException) {
            false
        }
}
