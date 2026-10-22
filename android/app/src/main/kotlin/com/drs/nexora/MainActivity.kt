package com.drs.nexora

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity (was FlutterActivity): required by
 * local_auth's biometric prompt (FragmentActivity APIs).
 *
 * Hosts the "com.drs.nexora/security" method channel used by
 * DeviceSecurityService to toggle FLAG_SECURE (screenshot blocking).
 * Both operations are idempotent and never throw back into Dart.
 */
class MainActivity : FlutterFragmentActivity() {
    private val securityChannel = "com.drs.nexora/security"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, securityChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        window.setFlags(
                            WindowManager.LayoutParams.FLAG_SECURE,
                            WindowManager.LayoutParams.FLAG_SECURE
                        )
                        result.success(true)
                    }
                    "clearSecure" -> {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
