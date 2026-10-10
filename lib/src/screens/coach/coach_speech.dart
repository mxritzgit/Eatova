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

/// The Coach's view of [SpeechInput] (`eatova/speech`): gym vocabulary, the
/// composer cap and localized [CoachSpeechException] messages.
///
/// `listen {localeId, token}` completes with `{text, reason}`; meanwhile the
/// plugin calls `partial {token, text}` with the whole transcript so far.
/// Transcripts are never logged here.
class CoachSpeechInput {
  const CoachSpeechInput();

  static const SpeechInput _speech = SpeechInput();

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
    try {
      return await _speech.listen(
        localeId: localeId,
        token: token,
        vocabulary: SpeechVocabulary.gym,
        maxChars: kCoachMaxInputChars,
        onPartial: onPartial,
        onEnd: onEnd == null
            ? null
            : (end) => onEnd(switch (end) {
                // The Coach drops a cancelled recording by its generation.
                SpeechEnd.stopped ||
                SpeechEnd.dismissed => CoachSpeechEnd.stopped,
                SpeechEnd.limit => CoachSpeechEnd.limit,
                SpeechEnd.length => CoachSpeechEnd.length,
              }),
      );
    } on SpeechInputException catch (e) {
      throw CoachSpeechException(switch (e.failure) {
        SpeechFailure.permissionDenied => l10n.coachSpeechPermissionDenied,
        SpeechFailure.unavailable => l10n.coachSpeechUnavailable,
        SpeechFailure.busy => l10n.coachSpeechBusy,
        SpeechFailure.failed => l10n.coachSpeechFailed,
      });
    }
  }

  /// Graceful: the audio ends and the running [listen] completes with the
  /// final result (the plugin waits up to 1.5 s for it).
  Future<void> stop() => _speech.stop();

  /// Immediate (lifecycle, dispose, language switch): the running [listen]
  /// completes at once with what was recognised so far.
  Future<void> cancel() => _speech.cancel();
}

class CoachSpeechException implements Exception {
  const CoachSpeechException(this.message);
  final String message;
}
