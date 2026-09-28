import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';

// The iOS speech channel reports its own texts: a hard-coded German "busy"
// message and `localizedDescription` in the SYSTEM language. The coach used
// to show `PlatformException.message` verbatim, so an English UI could read
// "Spracherkennung laeuft bereits." Every failure now maps to an ARB text of
// the app language.

const MethodChannel _channel = MethodChannel('eatova/speech');

void _answer(PlatformException error) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async => throw error);
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
}

Future<String> _messageFor(AppLocalizations l10n) async {
  try {
    await const CoachSpeechInput().listen(l10n: l10n);
  } on CoachSpeechException catch (e) {
    return e.message;
  }
  fail('listen() haette werfen muessen');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final l10n in [deL10n, enL10n]) {
    group('Sprache ${l10n.localeName}', () {
      test('laufende Erkennung nennt den Grund in der App-Sprache', () async {
        _answer(
          PlatformException(
            code: 'busy',
            message: 'Spracherkennung laeuft bereits.',
          ),
        );
        expect(await _messageFor(l10n), l10n.coachSpeechBusy);
      });

      test('Systemtext eines Erkennungsfehlers erreicht die UI nicht', () async {
        _answer(
          PlatformException(
            code: 'recognition_failed',
            message: 'Erkennung fehlgeschlagen (kAFAssistantErrorDomain 1110)',
          ),
        );
        expect(await _messageFor(l10n), l10n.coachSpeechFailed);
      });

      test('Berechtigung und Verfuegbarkeit bleiben unterschieden', () async {
        _answer(PlatformException(code: 'permission_denied'));
        expect(await _messageFor(l10n), l10n.coachSpeechPermissionDenied);
        _answer(PlatformException(code: 'unavailable'));
        expect(await _messageFor(l10n), l10n.coachSpeechUnavailable);
      });
    });
  }

  test('die beiden Texte unterscheiden sich je Sprache', () {
    expect(deL10n.coachSpeechBusy, isNot(enL10n.coachSpeechBusy));
    expect(deL10n.coachSpeechBusy, isNot(deL10n.coachSpeechFailed));
  });
}
