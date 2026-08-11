part of 'coach_chat_screen.dart';

class CoachSpeechInput {
  const CoachSpeechInput();

  static const MethodChannel _channel = MethodChannel('eatova/speech');

  /// [l10n] fehlt bewusst nicht in der Signatur: [CoachSpeechInput] hat
  /// keinen `BuildContext` (MethodChannel-Klasse, ohne Widget-Baum) — der
  /// Aufrufer (`_toggleSpeechInput` in coach_chat_screen.dart, hat Context)
  /// reicht die Uebersetzungen durch, statt hier ein eigenes Lookup zu bauen.
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
      // Stop ist best-effort; die laufende listen()-Future liefert sonst den
      // letzten erkannten Text oder laeuft mit ihrem eigenen Fehler aus.
    }
  }
}

class CoachSpeechException implements Exception {
  const CoachSpeechException(this.message);
  final String message;
}
