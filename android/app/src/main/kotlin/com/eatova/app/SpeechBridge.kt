package com.eatova.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.speech.RecognizerIntent
import androidx.activity.result.ActivityResultLauncher
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * `eatova/speech` on Android: the system recognizer dialog
 * (RecognizerIntent.ACTION_RECOGNIZE_SPEECH). The recognizer app records with
 * its own permission, so Eatova holds no RECORD_AUDIO. Dart side:
 * lib/src/services/speech_input.dart; contract: docs/MEAL-DESCRIBE.md.
 *
 * - listen {localeId, token, vocabulary, maxUnits} completes once with
 *   {text, reason}: final, length (text cut to maxUnits) or cancel (dialog
 *   dismissed or nothing recognized; text null). No partial calls; token and
 *   vocabulary are ignored. Errors: busy, unavailable, recognition_failed.
 * - stop and cancel leave a running dialog alone: it sits in front of Flutter
 *   and always returns a result, and the lifecycle pause the dialog itself
 *   causes must not drop what the user is about to say. The pending listen
 *   completes with cancel only once the dialog can no longer deliver to this
 *   bridge: the activity is back in front without a result ([onHostResumed])
 *   or goes away ([close]).
 * - available: whether any app handles the dialog intent.
 * The transcript is never logged.
 */
internal class SpeechBridge(
    private val activity: Activity,
    engine: FlutterEngine,
    private val launcher: ActivityResultLauncher<Intent>,
) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "eatova/speech")
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingMaxUnits = DEFAULT_MAX_UNITS

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listen" -> listen(call.arguments as? Map<*, *>, result)
                // See the class comment: the dialog delivers the result.
                "stop", "cancel" -> result.success(null)
                "available" -> result.success(isAvailable())
                else -> result.notImplemented()
            }
        }
    }

    private fun listen(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "Speech recognition is already running.", null)
            return
        }
        val intent = recognizerIntent(languageTag(arguments?.get("localeId")))
        if (!resolves(intent)) {
            result.error("unavailable", "No speech recognizer is installed.", null)
            return
        }
        pendingMaxUnits = (arguments?.get("maxUnits") as? Number)?.toInt()
            ?.takeIf { it > 0 } ?: DEFAULT_MAX_UNITS
        pending = result
        try {
            launcher.launch(intent)
        } catch (_: ActivityNotFoundException) {
            fail("unavailable", "No speech recognizer is installed.")
        } catch (_: RuntimeException) {
            fail("recognition_failed", "The speech recognizer could not be started.")
        }
    }

    /** MainActivity's launcher callback. A result without a pending listen is dropped. */
    fun onRecognizerResult(resultCode: Int, data: Intent?) {
        val reply = pending ?: return
        pending = null
        when (resultCode) {
            Activity.RESULT_OK -> {
                val text = try {
                    data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                        ?.firstOrNull { !it.isNullOrBlank() }
                } catch (_: RuntimeException) {
                    // The extras come from another app and may not unparcel.
                    reply.error("recognition_failed", "The recognizer result was unreadable.", null)
                    return
                }
                if (text == null) {
                    reply.success(CANCELLED)
                    return
                }
                val clipped = clip(text, pendingMaxUnits)
                reply.success(
                    mapOf("text" to clipped, "reason" to if (clipped == text) "final" else "length")
                )
            }
            Activity.RESULT_CANCELED, RecognizerIntent.RESULT_NO_MATCH -> reply.success(CANCELLED)
            else -> reply.error("recognition_failed", "Speech recognition failed.", null)
        }
    }

    /**
     * MainActivity.onResume. Android delivers activity results before
     * onResume, so a listen still pending here got no answer from the dialog
     * (it never showed, or ran outside this task) and the user sees Flutter
     * again: end it instead of leaving the mic busy. Checked one message
     * later, so a result delivered anywhere in this resume still wins.
     */
    fun onHostResumed() {
        val stale = pending ?: return
        mainHandler.post { if (pending === stale) cancelPending() }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        mainHandler.removeCallbacksAndMessages(null)
        // The dialog's result goes to the next activity's launcher, not here.
        // The engine is still attached (MainActivity calls this before
        // super.onDestroy), so the reply still reaches Dart.
        cancelPending()
    }

    private fun cancelPending() {
        val reply = pending ?: return
        pending = null
        reply.success(CANCELLED)
    }

    private fun fail(code: String, message: String) {
        val reply = pending ?: return
        pending = null
        reply.error(code, message, null)
    }

    private fun isAvailable(): Boolean = resolves(recognizerIntent(DEFAULT_LANGUAGE))

    /** Needs the RECOGNIZE_SPEECH <queries> entry on Android 11+. */
    private fun resolves(intent: Intent): Boolean = try {
        intent.resolveActivity(activity.packageManager) != null
    } catch (_: RuntimeException) {
        false
    }

    private fun recognizerIntent(languageTag: String): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)

    companion object {
        /** Mirrors the iOS default and kCoachMaxInputChars (UTF-16 units). */
        private const val DEFAULT_MAX_UNITS = 1000
        private const val DEFAULT_LANGUAGE = "de-DE"
        /** How far a cut may move back to end on a word instead of inside one. */
        private const val WORD_BACKTRACK = 40
        private val LOCALE_PATTERN = Regex("^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$")
        private val CANCELLED = mapOf<String, Any?>("text" to null, "reason" to "cancel")

        /** `de_DE` (Dart's locale id) -> `de-DE` (BCP 47 for EXTRA_LANGUAGE). */
        internal fun languageTag(localeId: Any?): String {
            val id = localeId as? String
            return if (id != null && LOCALE_PATTERN.matches(id)) id.replace('_', '-') else DEFAULT_LANGUAGE
        }

        /**
         * Cuts [text] to at most [maxUnits] UTF-16 units, never inside a
         * surrogate pair, and at a word break when one is close.
         */
        internal fun clip(text: String, maxUnits: Int): String {
            if (text.length <= maxUnits) return text
            var end = maxUnits
            if (Character.isHighSurrogate(text[end - 1])) end--
            val space = text.lastIndexOf(' ', end)
            if (space > 0 && end - space <= WORD_BACKTRACK) end = space
            return text.substring(0, end).trimEnd()
        }
    }
}
