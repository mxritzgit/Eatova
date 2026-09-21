package com.eatova.app

import android.content.Intent
import android.widget.Toast
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

internal class RecipeShareBridge(private val activity: MainActivity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "eatova/recipe_share")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "consumePending" && call.method != "clearPending") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val arguments = call.arguments as? Map<*, *>
            val requestedOwner = arguments?.get("owner")
            if (arguments == null || !arguments.containsKey("owner") ||
                (requestedOwner != null &&
                    (requestedOwner !is String || !OWNER_PATTERN.matches(requestedOwner)))) {
                result.error("invalid_share_owner", "The share owner is invalid.", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "consumePending" -> {
                    if (owner != null && owner != requestedOwner) pending.clear()
                    owner = requestedOwner as String?
                    val values = pending.toList()
                    pending.clear()
                    result.success(values)
                }
                "clearPending" -> {
                    pending.clear()
                    owner = requestedOwner as String?
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun receive(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") return
        val raw = try {
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
        } catch (_: RuntimeException) {
            null
        }
        // Do not replay this share after activity recreation or consume auth URLs.
        intent.removeExtra(Intent.EXTRA_TEXT)
        if (raw == null || raw.isBlank()) return
        if (raw.length > MAX_TEXT_LENGTH || raw.contains('\u0000')) {
            Toast.makeText(activity, R.string.recipe_share_invalid, Toast.LENGTH_LONG).show()
            return
        }
        if (pending.size >= MAX_PENDING) {
            Toast.makeText(activity, R.string.recipe_share_queue_full, Toast.LENGTH_LONG).show()
            return
        }
        pending.add(mapOf("id" to UUID.randomUUID().toString(), "text" to raw.toString().trim()))
        channel.invokeMethod("sharesAvailable", null)
    }

    fun close() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val MAX_TEXT_LENGTH = 20000
        private const val MAX_PENDING = 8
        private val OWNER_PATTERN = Regex("^[0-9a-f]{64}$")
        private var owner: String? = null
        // Process-local only: shared source text never enters plaintext preferences.
        private val pending = ArrayDeque<Map<String, String>>()
    }
}
