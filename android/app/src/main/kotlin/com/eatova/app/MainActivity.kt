package com.eatova.app

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity, not FlutterActivity: the health plugin needs a
// ComponentActivity, otherwise its registration throws ClassCastException.
class MainActivity : FlutterFragmentActivity() {
    private var healthConnectBridge: HealthConnectBridge? = null
    private var recipeShareBridge: RecipeShareBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) recipeShareBridge?.receive(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        recipeShareBridge?.receive(intent)
    }

    // Screenshot/recents protection: the Dart-side SecureScreenGuard toggles
    // FLAG_SECURE while a sensitive screen is visible.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        healthConnectBridge = HealthConnectBridge(this, flutterEngine)
        recipeShareBridge = RecipeShareBridge(this, flutterEngine)
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
        // Keep-awake while a timed interval runs or while dictating (Dart:
        // ScreenAwake). A window flag: no permission, cleared with the window.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "eatova/screen"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepAwake" -> {
                    val on = call.argument<Boolean>("on") == true
                    runOnUiThread {
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        healthConnectBridge?.close()
        recipeShareBridge?.close()
        super.onDestroy()
    }
}
