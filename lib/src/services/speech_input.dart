// Dart side of the `eatova/speech` channel, shared by the Coach and the meal
// description. Contract: docs/MEAL-DESCRIBE.md (Speech).
//
// Native sides: EatovaSpeechPlugin (ios/Runner/AppDelegate.swift) and
// SpeechBridge (android/app/src/main/kotlin/com/eatova/app/SpeechBridge.kt).
// `listen {localeId, token, vocabulary, maxUnits}` completes with
// `{text, reason}`; on iOS the plugin meanwhile calls `partial {token, text}`
// with the whole transcript so far. Transcripts are never logged here.

import 'package:flutter/services.dart';

/// Why a recording ended, as far as the user needs a hint.
enum SpeechEnd {
  /// Stopped by Dart, finished by the recognizer, or the system dialog
  /// returned (with text, or having heard nothing).
  stopped,

  /// Ended without an answer to give: the user dismissed Android's system
  /// dialog, which spoke for itself, or Dart cancelled.
  dismissed,

  /// Apple's server path ended the task after about a minute.
  limit,

  /// The text reached the caller's [SpeechInput.listen] `maxChars`.
  length,
}

/// Words that bias recognition (iOS only; Android ignores it).
enum SpeechVocabulary { gym, food }

/// Typed failure; callers pick the localized message.
enum SpeechFailure { permissionDenied, unavailable, busy, failed }

class SpeechInputException implements Exception {
  const SpeechInputException(this.failure);
  final SpeechFailure failure;

  @override
  String toString() => 'SpeechInputException(${failure.name})';
}

class SpeechInput {
  const SpeechInput();

  static const MethodChannel _channel = MethodChannel('eatova/speech');

  /// Receiver of `partial` calls: only the newest [listen] has one. Static
  /// because the channel has one handler for every caller.
  static _PartialBinding? _binding;

  /// Platforms with a native `eatova/speech` implementation.
  static bool supportedOn(TargetPlatform platform) =>
      platform == TargetPlatform.iOS || platform == TargetPlatform.android;

  /// Whether partial transcripts stream while listening (iOS) or the text
  /// arrives only at the end (Android system dialog).
  static bool streamsPartialsOn(TargetPlatform platform) =>
      platform == TargetPlatform.iOS;

  /// Listens once. [token] must be unique per call; partials of an older
  /// call are dropped. Returns null when nothing was recognized or the user
  /// dismissed the recognizer. Throws [SpeechInputException].
  ///
  /// [maxChars] counts UTF-16 units. iOS stops gracefully once the transcript
  /// reaches it, so words recognized while it drains can exceed it; Android
  /// cuts the text to it. Either way [onEnd] reports [SpeechEnd.length].
  /// [onEnd] runs before the text is returned.
  Future<String?> listen({
    required String localeId,
    required int token,
    SpeechVocabulary vocabulary = SpeechVocabulary.gym,
    int maxChars = 1000,
    ValueChanged<String>? onPartial,
    ValueChanged<SpeechEnd>? onEnd,
  }) async {
    assert(maxChars > 0, 'maxChars must be positive');
    final binding = _PartialBinding(token, onPartial);
    _binding = binding;
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      final result = await _channel
          .invokeMapMethod<String, Object?>('listen', <String, Object?>{
            'localeId': localeId,
            'token': token,
            'vocabulary': vocabulary.name,
            'maxUnits': maxChars,
          });
      onEnd?.call(switch (result?['reason']) {
        'limit' => SpeechEnd.limit,
        'length' => SpeechEnd.length,
        'cancel' => SpeechEnd.dismissed,
        _ => SpeechEnd.stopped,
      });
      final text = result?['text'];
      return text is String && text.trim().isNotEmpty ? text : null;
    } on PlatformException catch (e) {
      // Never the platform's `message`: iOS sends hard-coded German or the
      // system language, not the app language.
      throw SpeechInputException(_failureFor(e.code));
    } on MissingPluginException {
      throw const SpeechInputException(SpeechFailure.unavailable);
    } finally {
      if (identical(_binding, binding)) _binding = null;
    }
  }

  static SpeechFailure _failureFor(String platformCode) {
    final code = platformCode.toLowerCase();
    if (code.contains('permission') || code.contains('denied')) {
      return SpeechFailure.permissionDenied;
    }
    if (code.contains('unavailable')) return SpeechFailure.unavailable;
    if (code == 'busy') return SpeechFailure.busy;
    return SpeechFailure.failed;
  }

  static Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'partial') throw MissingPluginException();
    final args = call.arguments;
    final binding = _binding;
    if (args is! Map || binding == null || args['token'] != binding.token) {
      return null;
    }
    final text = args['text'];
    if (text is String) binding.onPartial?.call(text);
    return null;
  }

  /// Whether a recognizer can run now: iOS checks [localeId], Android whether
  /// any app handles the system dialog. False when the platform has no
  /// channel or the check fails.
  Future<bool> available({String localeId = 'de_DE'}) async {
    try {
      final value = await _channel.invokeMethod<bool>(
        'available',
        <String, Object?>{'localeId': localeId},
      );
      return value ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Graceful: the running [listen] completes with the final result (iOS
  /// waits up to 1.5 s for it). Android leaves the system dialog running; it
  /// completes [listen] when the user finishes or dismisses it.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Best effort: the running listen() future still yields the last
      // recognised text or fails on its own.
    }
  }

  /// Immediate: the running [listen] completes with what it has. Android
  /// leaves the system dialog running, as for [stop]: the lifecycle pause the
  /// dialog itself causes must not drop what the user is about to say.
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {
      // Best effort, like [stop].
    }
  }
}

/// One per [SpeechInput.listen] call; its identity marks the call.
class _PartialBinding {
  _PartialBinding(this.token, this.onPartial);
  final int token;
  final ValueChanged<String>? onPartial;
}
