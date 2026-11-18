package com.example.bussinessfinder

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.view.WindowManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build

class MainActivity : FlutterActivity() {
    private var callRingtone: Ringtone? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "spotlight/privacy"
        ).setMethodCallHandler { call, result ->
            if (call.method != "setSecureScreen") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val enabled = call.argument<Boolean>("enabled") ?: false
            runOnUiThread {
                if (enabled) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spotlight/calls")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRinging" -> {
                        if (callRingtone == null) {
                            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                            callRingtone = RingtoneManager.getRingtone(applicationContext, uri)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) callRingtone?.isLooping = true
                            callRingtone?.play()
                        }
                        result.success(null)
                    }
                    "stopRinging" -> {
                        callRingtone?.stop()
                        callRingtone = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        callRingtone?.stop()
        callRingtone = null
        super.onDestroy()
    }
}
