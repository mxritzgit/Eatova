import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/services/stale_auth_retry.dart';

// Sentry FLUTTER-9/-A/-B (2026-08-26): at three cold starts the six boot loads
// went out ~1.1 s after a successful token refresh, and each time exactly ONE
// random load came back 401 (PGRST303 / bare 401) — a server-side flake on a
// brand-new token, not an expired one. Rules pinned here: first retry waits
// only, second retry refreshes then waits, a third rejection reaches the
// caller; everything that is not a stale-auth rejection passes through.

PostgrestException _pg(String code) =>
    PostgrestException(message: 'rejected', code: code);

/// Harness: counts refreshes, records waits (without really waiting) and
/// scripts the load outcomes in order.
class _Harness {
  int refreshes = 0;
  final waits = <Duration>[];
  int loads = 0;
  final List<Object?> script;
  Completer<void>? refreshGate;

  _Harness(this.script);

  StaleAuthRetry get retry => StaleAuthRetry(() {
        refreshes++;
        return refreshGate?.future ?? Future<void>.value();
      }, delay: (d) async => waits.add(d));

  Future<String> load() async {
    final step = script[loads++];
    if (step is Object && step is! String) throw step;
    return step as String;
  }
}

void main() {
  group('StaleAuthRetry', () {
    // All three rejections mean the same thing — a token the server did not
    // accept — so the whole escalation runs once per code. A code that stops
    // counting as stale auth names itself in the failure.
    // Bare HTTP status = the gateway answered, not PostgREST (FLUTTER-B).
    for (final code in const <String>['PGRST303', 'PGRST301', '401']) {
      test('$code: eine Ablehnung -> nur warten, KEIN Refresh, zweiter '
          'Versuch liefert', () async {
        final h = _Harness([_pg(code), 'ok']);
        expect(await h.retry.run(h.load), 'ok');
        expect(h.loads, 2);
        expect(h.refreshes, 0,
            reason:
                'der Token war frisch — ein Refresh praegt nur den naechsten');
        expect(h.waits, [StaleAuthRetry.firstRetryDelay]);
      });

      test('$code: zwei Ablehnungen -> Refresh + warten, dritter Versuch '
          'liefert', () async {
        final h = _Harness([_pg(code), _pg(code), 'ok']);
        expect(await h.retry.run(h.load), 'ok');
        expect(h.loads, 3);
        expect(h.refreshes, 1);
        expect(h.waits,
            [StaleAuthRetry.firstRetryDelay, StaleAuthRetry.secondRetryDelay]);
      });

      test('$code: drei Ablehnungen -> der Fehler erreicht den Aufrufer, '
          'KEINE Schleife', () async {
        final h = _Harness([_pg(code), _pg(code), _pg(code)]);
        await expectLater(
            h.retry.run(h.load), throwsA(isA<PostgrestException>()));
        expect(h.loads, 3);
        expect(h.refreshes, 1);
      });
    }

    test('andere PostgREST-Fehler gehen sofort durch: kein Warten, kein Refresh',
        () async {
      final h = _Harness([_pg('PGRST100'), 'nie']);
      await expectLater(h.retry.run(h.load), throwsA(isA<PostgrestException>()));
      expect(h.loads, 1);
      expect(h.waits, isEmpty);
      expect(h.refreshes, 0);
    });

    test('Netzfehler gehen sofort durch', () async {
      final h = _Harness([const SocketException('offline'), 'nie']);
      await expectLater(h.retry.run(h.load), throwsA(isA<SocketException>()));
      expect(h.loads, 1);
      expect(h.waits, isEmpty);
    });

    test('ein Nicht-Auth-Fehler NACH der ersten Wiederholung geht durch',
        () async {
      final h = _Harness([_pg('PGRST303'), const SocketException('weg')]);
      await expectLater(h.retry.run(h.load), throwsA(isA<SocketException>()));
      expect(h.loads, 2);
      expect(h.refreshes, 0);
    });

    test('ein gescheiterter Refresh ist der Fehler, den der Aufrufer sieht',
        () async {
      var loads = 0;
      final retry = StaleAuthRetry(
        () async => throw AuthRetryableFetchException(message: 'offline'),
        delay: (_) async {},
      );
      await expectLater(
        retry.run<void>(() async {
          loads++;
          throw _pg('PGRST303');
        }),
        throwsA(isA<AuthRetryableFetchException>()),
      );
      // No third read without a fresh token: it would fail the same way.
      expect(loads, 2);
    });

    test('parallele Boot-Loads teilen sich EINEN Refresh', () async {
      var refreshes = 0;
      final refreshDone = Completer<void>();
      final retry = StaleAuthRetry(() {
        refreshes++;
        return refreshDone.future;
      }, delay: (_) async {});

      var tokenFresh = false;
      Future<String> load(String name) async {
        if (!tokenFresh) throw _pg('PGRST303');
        return name;
      }

      final pending = Future.wait<String>([
        retry.run(() => load('profile')),
        retry.run(() => load('meals')),
        retry.run(() => load('weight')),
      ]);
      // Let all three run into the second rejection and queue up behind the
      // refresh.
      await pumpEventQueue();
      expect(refreshes, 1);

      tokenFresh = true;
      refreshDone.complete();

      expect(await pending, ['profile', 'meals', 'weight']);
      expect(refreshes, 1);
    });

    test('nach einem abgeschlossenen Refresh startet ein spaeterer Treffer '
        'einen neuen', () async {
      var refreshes = 0;
      final retry =
          StaleAuthRetry(() async => refreshes++, delay: (_) async {});

      Future<int> twiceRejected() {
        var calls = 0;
        return retry.run<int>(() async {
          calls++;
          if (calls <= 2) throw _pg('PGRST303');
          return calls;
        });
      }

      await twiceRejected();
      await twiceRejected();
      expect(refreshes, 2);
    });

    test('die Wartezeiten passen in das 8-s-Boot-Budget', () {
      expect(
          StaleAuthRetry.firstRetryDelay + StaleAuthRetry.secondRetryDelay,
          lessThan(const Duration(seconds: 8)));
    });
  });
}
