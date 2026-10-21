import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/google_id_token_provider.dart';

// The native Google flow's one-time initialization (Review 2026-08-29, P4-04).
//
// `initialize()` may run only once per process, so its future is cached.
// Cached with `??=` it also kept a FAILED run: after one bad moment (Play
// Services mid-update, a freshly flashed device, a work profile) every later
// login re-awaited the same rejected future and dropped into the web OAuth
// sheet — the sheet showing "…supabase.co", i.e. exactly what the native flow
// exists to avoid — until the app was restarted.

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
  });
}
