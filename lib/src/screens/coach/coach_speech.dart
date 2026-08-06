part of 'coach_chat_screen.dart';

class CoachSpeechInput {
  const CoachSpeechInput();

  static const MethodChannel _channel = MethodChannel('eatova/speech');

  Future<String?> listen({String localeId = 'de_DE'}) async {
    try {
      return await _channel.invokeMethod<String>('listen', <String, dynamic>{
        'localeId': localeId,
      });
    } on PlatformException catch (e) {
      final code = e.code.toLowerCase();
      if (code.contains('permission') || code.contains('denied')) {
        throw const CoachSpeechException(
          'Mikrofon oder Spracherkennung wurde nicht erlaubt. Du kannst die Berechtigung in den iOS-Einstellungen wieder aktivieren.',
        );
      }
      if (code.contains('unavailable')) {
        throw const CoachSpeechException(
          'Spracherkennung ist auf diesem Gerät gerade nicht verfügbar.',
        );
      }
      throw CoachSpeechException(e.message ?? 'Spracherkennung fehlgeschlagen.');
    } on MissingPluginException {
      throw const CoachSpeechException(
        'Spracherkennung ist auf diesem Gerät gerade nicht verfügbar.',
      );
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
