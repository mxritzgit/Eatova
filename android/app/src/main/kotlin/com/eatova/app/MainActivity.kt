package com.eatova.app

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity, not FlutterActivity: the health plugin needs a
// ComponentActivity, otherwise its registration throws ClassCastException.
class MainActivity : FlutterFragmentActivity() {
    private var healthConnectBridge: HealthConnectBridge? = null
    private var recipeShareBridge: RecipeShareBridge? = null
    private var speechBridge: SpeechBridge? = null

    // The Activity Result API needs registration before STARTED. Field
    // initialization is the documented safe point. configureFlutterEngine is
    // not: FlutterFragmentActivity adds its FlutterFragment with commit(), so
    // on a fresh launch the fragment attaches (and configures the engine) only
    // inside FragmentActivity.onStart, which is too close to rely on.
    private val speechLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            speechBridge?.onRecognizerResult(result.resultCode, result.data)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) recipeShareBridge?.receive(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        recipeShareBridge?.receive(intent)
    }

    override fun onResume() {
        super.onResume()
        speechBridge?.onHostResumed()
    }

    // Screenshot/recents protection: the Dart-side SecureScreenGuard toggles
    // FLAG_SECURE while a sensitive screen is visible.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        healthConnectBridge = HealthConnectBridge(this, flutterEngine)
        recipeShareBridge = RecipeShareBridge(this, flutterEngine)
        speechBridge = SpeechBridge(this, flutterEngine, speechLauncher)
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
        speechBridge?.close()
        super.onDestroy()
    }
}
