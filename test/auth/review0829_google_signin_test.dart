import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/google_id_token_provider.dart';

// The native Google flow (Review 2026-08-29, P4-01 + P4-04).
//
// P4-04: `initialize()` may run only once per process, so its future is
// cached. Cached with `??=` it also kept a FAILED run: after one bad moment
// (Play Services mid-update, a freshly flashed device, a work profile) every
// later login re-awaited the same rejected future and dropped into the web
// OAuth sheet — the sheet showing "…supabase.co", i.e. exactly what the native
// flow exists to avoid — until the app was restarted.
//
// P4-01 is documentation: the design spec justified the missing nonce with a
// claim about google_sign_in that no longer holds. The SECURITY half of that
// finding was refuted (the client picks the nonce and supplies both sides,
// GoTrue only checks a nonce a token actually carries), so the fix is an
// honest document — not a nonce sold as a closed gap.

/// The shape a dead Play Services layer really has: google_sign_in surfaces it
/// as a [PlatformException] off the platform channel.
PlatformException _playServicesTot() => PlatformException(
      code: 'sign_in_failed',
      message: 'com.google.android.gms.common.api.ApiException: 10',
    );

void main() {
  group('P4-04 — ein gescheitertes initialize() bleibt nicht gescheitert', () {
    test('nach einem Fehlschlag startet der naechste Login wirklich neu',
        () async {
      final tor = RetryableInitialization();
      var laeufe = 0;

      await expectLater(
        tor.run(() async {
          laeufe++;
          throw _playServicesTot();
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(tor.isRemembered, isFalse,
          reason: 'ein Fehler-Future darf nicht als "erledigt" liegen '
              'bleiben — sonst faellt jeder Login bis zum App-Neustart auf '
              'den Web-OAuth-Sheet zurueck');

      await tor.run(() async => laeufe++);
      expect(laeufe, 2, reason: 'der zweite Versuch muss initialize() '
          'wirklich noch einmal aufrufen');
      expect(tor.isRemembered, isTrue);
    });

    test('ein Erfolg laeuft genau einmal (initialize darf nur einmal laufen)',
        () async {
      final tor = RetryableInitialization();
      var laeufe = 0;

      await tor.run(() async => laeufe++);
      await tor.run(() async => laeufe++);
      await tor.run(() async => laeufe++);

      expect(laeufe, 1,
          reason: 'google_sign_in verlangt genau einen initialize()-Aufruf '
              'pro Prozess');
    });

    test('parallele Aufrufe teilen sich EINEN Lauf und erben seinen Fehler',
        () async {
      final tor = RetryableInitialization();
      final tuer = Completer<void>();
      var laeufe = 0;

      Future<void> starte() {
        laeufe++;
        return tuer.future;
      }

      final erster = tor.run(starte);
      final zweiter = tor.run(starte);
      tuer.completeError(_playServicesTot());

      await expectLater(erster, throwsA(isA<PlatformException>()));
      await expectLater(zweiter, throwsA(isA<PlatformException>()));
      expect(laeufe, 1, reason: 'zwei gleichzeitige Logins duerfen nicht zwei '
          'initialize()-Aufruf ausloesen');
      expect(tor.isRemembered, isFalse,
          reason: 'und der gemeinsame Fehlschlag wird trotzdem vergessen');
    });

    test('ein zweiter Fehlschlag wird genauso vergessen wie der erste',
        () async {
      final tor = RetryableInitialization();
      var laeufe = 0;

      for (var versuch = 0; versuch < 3; versuch++) {
        await expectLater(
          tor.run(() async {
            laeufe++;
            throw _playServicesTot();
          }),
          throwsA(isA<PlatformException>()),
        );
      }
      expect(laeufe, 3);
    });
  });

  group('P4-01 — das Design-Dokument steht auf dem Stand von google_sign_in 7',
      () {
    const String pfad =
        'docs/superpowers/specs/2026-08-05-google-native-signin-design.md';

    test('die widerlegte Begruendung steht nicht mehr als Begruendung da', () {
      final datei = File(pfad);
      expect(datei.existsSync(), isTrue,
          reason: '$pfad fehlt (aufgeloest von ${Directory.current.path})');
      final text = datei.readAsStringSync();

      expect(
        text.contains('**Nonce:** `google_sign_in` unterstützt kein Nonce'),
        isFalse,
        reason: 'google_sign_in 7.2.0 nimmt in initialize() ein nonce '
            'entgegen, und signInWithIdToken hat den Parameter — die alte '
            'Zeile war schlicht falsch',
      );
      expect(
        text,
        contains('genau einmal pro Prozess'),
        reason: 'der wirkliche Grund gehoert ins Dokument: initialize() laeuft '
            'einmal pro Prozess und authenticate() nimmt kein Nonce, ein '
            'gesetztes waere also eine Prozess-Konstante',
      );
    });
  });
}
