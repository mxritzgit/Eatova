package com.eatova.app

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (statt FlutterActivity), weil das health-Plugin
// eine ComponentActivity braucht - mit FlutterActivity schlug seine
// Registrierung mit ClassCastException fehl (Health-Sync auf Android tot).
class MainActivity : FlutterFragmentActivity() {

    // Screenshot-/Recents-Schutz (Sicherheits-Audit 2026-08-09): der
    // Dart-Guard [SecureScreenGuard] schaltet FLAG_SECURE, solange ein
    // sensibler Screen (Auth-Code, Passwort, Gesundheitsdaten) sichtbar ist.
    // FLAG_SECURE haelt den Fensterinhalt aus dem Recents-Thumbnail und
    // blockiert Screenshots/Screen-Recording auf Systemebene.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "eatova/secure_screen"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    runOnUiThread {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                "disable" -> {
                    runOnUiThread {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
