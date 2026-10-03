part of 'coach_chat_screen.dart';

/// Why a recording ended, as far as the user needs a hint.
enum CoachSpeechEnd {
  /// Stopped or cancelled by Dart, or finished by the recognizer.
  stopped,

  /// Apple's server path ended the task after about a minute.
  limit,

  /// The dictated text reached the coach input cap.
  length,
}

/// Dart side of `eatova/speech` (EatovaSpeechPlugin, ios/Runner/AppDelegate.swift).
///
/// `listen {localeId, token}` completes with `{text, reason}`; meanwhile the
/// plugin calls `partial {token, text}` with the whole transcript so far.
/// Transcripts are never logged here.
class CoachSpeechInput {
  const CoachSpeechInput();

  static const MethodChannel _channel = MethodChannel('eatova/speech');

  /// Receiver of `partial` calls: only the newest [listen] has one.
  static _PartialBinding? _binding;

  /// [l10n] is passed in because [CoachSpeechInput] has no `BuildContext`.
  ///
  /// [token] must be unique per call: `partial` calls carrying another token
  /// belong to an older recording and are dropped before [onPartial].
  /// [onEnd] reports why the recording ended before the text is returned.
  Future<String?> listen({
    String localeId = 'de_DE',
    required AppLocalizations l10n,
    int token = 0,
    ValueChanged<String>? onPartial,
    ValueChanged<CoachSpeechEnd>? onEnd,
  }) async {
    final binding = _PartialBinding(token, onPartial);
    _binding = binding;
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'listen',
        <String, Object?>{'localeId': localeId, 'token': token},
      );
      onEnd?.call(switch (result?['reason']) {
        'limit' => CoachSpeechEnd.limit,
        'length' => CoachSpeechEnd.length,
        _ => CoachSpeechEnd.stopped,
      });
      final text = result?['text'];
      return text is String ? text : null;
    } on PlatformException catch (e) {
      final code = e.code.toLowerCase();
      if (code.contains('permission') || code.contains('denied')) {
        throw CoachSpeechException(l10n.coachSpeechPermissionDenied);
      }
      if (code.contains('unavailable')) {
        throw CoachSpeechException(l10n.coachSpeechUnavailable);
      }
      if (code == 'busy') {
        throw CoachSpeechException(l10n.coachSpeechBusy);
      }
      // Never the platform's `message`: iOS sends hard-coded German or the
      // system language, not the app language.
      throw CoachSpeechException(l10n.coachSpeechFailed);
    } on MissingPluginException {
      throw CoachSpeechException(l10n.coachSpeechUnavailable);
    } finally {
      if (identical(_binding, binding)) _binding = null;
    }
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

  /// Graceful: the audio ends and the running [listen] completes with the
  /// final result (the plugin waits up to 1.5 s for it).
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Best effort: the running listen() future still yields the last
      // recognised text or fails on its own.
    }
  }

  /// Immediate (lifecycle, dispose, language switch): the running [listen]
  /// completes at once with what was recognised so far.
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {
      // Best effort, like [stop].
    }
  }
}

/// One per [CoachSpeechInput.listen] call; its identity marks the call.
class _PartialBinding {
  _PartialBinding(this.token, this.onPartial);
  final int token;
  final ValueChanged<String>? onPartial;
}

class CoachSpeechException implements Exception {
  const CoachSpeechException(this.message);
  final String message;
}
