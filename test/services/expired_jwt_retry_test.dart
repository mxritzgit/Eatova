import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/services/expired_jwt_retry.dart';

// Sentry FLUTTER-9 (2026-08-26): a cold-start boot load came back with
// `PGRST303` (JWT expired) and failed for good — the auto-refresh seconds
// later healed nothing in the past. Rule pinned here: an expired-JWT rejection
// triggers exactly ONE session refresh and ONE retry; everything else passes
// through untouched.

PostgrestException _pg(String code) =>
    PostgrestException(message: 'rejected', code: code);

void main() {
  group('ExpiredJwtRetry', () {
    test('PGRST303 -> Refresh -> zweiter Versuch liefert das Ergebnis',
        () async {
      var refreshes = 0;
      var loads = 0;
      final retry = ExpiredJwtRetry(() async => refreshes++);

      final result = await retry.run<String>(() async {
        loads++;
        if (loads == 1) throw _pg('PGRST303');
        return 'frisch';
      });

      expect(result, 'frisch');
      expect(refreshes, 1);
      expect(loads, 2);
    });

    test('der aeltere Code PGRST301 wird genauso behandelt', () async {
      var refreshes = 0;
      var loads = 0;
      final retry = ExpiredJwtRetry(() async => refreshes++);

      final result = await retry.run<int>(() async {
        loads++;
        if (loads == 1) throw _pg('PGRST301');
        return 42;
      });

      expect(result, 42);
      expect(refreshes, 1);
      expect(loads, 2);
    });

    test('andere PostgREST-Fehler gehen ohne Refresh durch', () async {
      var refreshes = 0;
      var loads = 0;
      final retry = ExpiredJwtRetry(() async => refreshes++);

      await expectLater(
        retry.run<void>(() async {
          loads++;
          throw _pg('PGRST100');
        }),
        throwsA(isA<PostgrestException>()),
      );
      expect(refreshes, 0);
      expect(loads, 1);
    });

    test('Netzfehler gehen ohne Refresh durch', () async {
      var refreshes = 0;
      final retry = ExpiredJwtRetry(() async => refreshes++);

      await expectLater(
        retry.run<void>(() async => throw const SocketException('offline')),
        throwsA(isA<SocketException>()),
      );
      expect(refreshes, 0);
    });

    test('bleibt der Token nach dem Refresh abgelehnt, gibt es KEINE Schleife',
        () async {
      var refreshes = 0;
      var loads = 0;
      final retry = ExpiredJwtRetry(() async => refreshes++);

      await expectLater(
        retry.run<void>(() async {
          loads++;
          throw _pg('PGRST303');
        }),
        throwsA(isA<PostgrestException>()),
      );
      expect(refreshes, 1);
      expect(loads, 2);
    });

    test('ein gescheiterter Refresh ist der Fehler, den der Aufrufer sieht',
        () async {
      var loads = 0;
      final retry = ExpiredJwtRetry(
          () async => throw AuthRetryableFetchException(message: 'offline'));

      await expectLater(
        retry.run<void>(() async {
          loads++;
          throw _pg('PGRST303');
        }),
        throwsA(isA<AuthRetryableFetchException>()),
      );
      // No retry without a fresh token: the read would fail the same way.
      expect(loads, 1);
    });

    test('parallele Boot-Loads teilen sich EINEN Refresh', () async {
      var refreshes = 0;
      final refreshDone = Completer<void>();
      final retry = ExpiredJwtRetry(() {
        refreshes++;
        return refreshDone.future;
      });

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
      // Let all three hit the rejection and queue up behind the refresh.
      await Future<void>.delayed(Duration.zero);
      expect(refreshes, 1);

      tokenFresh = true;
      refreshDone.complete();

      expect(await pending, ['profile', 'meals', 'weight']);
      expect(refreshes, 1);
    });

    test(
        'nach einem abgeschlossenen Refresh startet ein spaeterer Treffer '
        'einen neuen', () async {
      var refreshes = 0;
      final retry = ExpiredJwtRetry(() async => refreshes++);

      Future<int> flaky() {
        var calls = 0;
        return retry.run<int>(() async {
          calls++;
          if (calls == 1) throw _pg('PGRST303');
          return calls;
        });
      }

      await flaky();
      await flaky();
      expect(refreshes, 2);
    });
  });
}
