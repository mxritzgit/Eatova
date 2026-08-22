part of 'coach_chat_screen.dart';

class CoachSpeechInput {
  const CoachSpeechInput();

  static const MethodChannel _channel = MethodChannel('eatova/speech');

  /// [l10n] is passed in because [CoachSpeechInput] has no `BuildContext`;
  /// the caller (`_toggleSpeechInput`) supplies the translations.
  Future<String?> listen({
    String localeId = 'de_DE',
    required AppLocalizations l10n,
  }) async {
    try {
      return await _channel.invokeMethod<String>('listen', <String, dynamic>{
        'localeId': localeId,
      });
    } on PlatformException catch (e) {
      final code = e.code.toLowerCase();
      if (code.contains('permission') || code.contains('denied')) {
        throw CoachSpeechException(l10n.coachSpeechPermissionDenied);
      }
      if (code.contains('unavailable')) {
        throw CoachSpeechException(l10n.coachSpeechUnavailable);
      }
      throw CoachSpeechException(e.message ?? l10n.coachSpeechFailed);
    } on MissingPluginException {
      throw CoachSpeechException(l10n.coachSpeechUnavailable);
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Best effort: the running listen() future still yields the last
      // recognised text or fails on its own.
    }
  }
}

class CoachSpeechException implements Exception {
  const CoachSpeechException(this.message);
  final String message;
}
