import 'dart:io';

import 'package:clock/clock.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException;

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

// Sentry feed finding (2026-08-10): three high-priority socket-exception
// issues from the meal-insert sync path, all produced in airplane mode — the
// exact case the outbox queue handles: the write is queued, the user is
// informed, nothing is lost.
//
// Left alone, every meal logged on a train becomes a crash report, burying
// real errors and burning the Sentry quota.
//
// Rule these tests pin: a pure network error on the sync path does NOT go to
// Sentry. Everything else does.

void main() {
  final gemeldet = <Object>[];

  setUp(() {
    gemeldet.clear();
    CrashReporter.debugSentrySink = (error, stack, context) {
      gemeldet.add(error);
    };
  });

  tearDown(() => CrashReporter.debugSentrySink = null);

  group('Netzfehler sind kein Crash', () {
    test('ein SocketException aus dem Sync-Pfad geht NICHT an Sentry',
        () async {
      // The exact error from the feed: the socket drops mid-write.
      await CrashReporter.captureSyncFailure(
        const SocketException('Connection failed'),
        StackTrace.current,
        context: 'meal-insert',
      );

      expect(gemeldet, isEmpty,
          reason: 'die Op liegt in der Warteschlange — das ist kein Vorfall');
    });

    test('auch ein ClientException (http-Paket) zaehlt als Netzfehler',
        () async {
      // The classifier checks TYPES, not message text — hence the real type
      // from package:http.
      await CrashReporter.captureSyncFailure(
        ClientException('Failed host lookup'),
        StackTrace.current,
        context: 'recipe-upsert',
      );

      expect(gemeldet, isEmpty);
    });

    test('ein ECHTER Serverfehler geht weiterhin an Sentry', () async {
      // 500s, constraint violations, broken responses: real errors nobody
      // else would notice.
      await CrashReporter.captureSyncFailure(
        Exception('PostgrestException: 42501 permission denied'),
        StackTrace.current,
        context: 'meal-insert',
      );

      // The sink gets the SANITIZED error, never the raw object (it could
      // carry half a profiles row), so this asserts THAT it reported.
      expect(gemeldet, hasLength(1));
    });

    test('die Klassifizierung ist dieselbe wie fuer die Nutzer-Meldung', () {
      // A second threshold would be a second place to drift: what the user is
      // told is "offline" must not reach Sentry as an incident, and vice
      // versa.
      expect(isNetworkSyncError(const SocketException('x')), isTrue);
      expect(
        isNetworkSyncError(Exception('PostgrestException: 42501')),
        isFalse,
      );
    });
  });

  // GoTrue wraps every answer >= 500 in the same AuthRetryableFetchException
  // it throws for a dead socket. The outbox rightly retries both, but only
  // the socket is "offline": a 5xx means the server answered, i.e. a real
  // auth outage, and it used to stay invisible in Sentry.
  group('GoTrue-5xx ist ein Serverausfall, kein Funkloch', () {
    AuthRetryableFetchException gotrue503() => AuthRetryableFetchException(
          message: '{"code":503,"message":"upstream connect error"}',
          statusCode: '503',
        );

    setUp(CrashReporter.debugResetAuthServerFaultThrottle);
    tearDown(CrashReporter.debugResetAuthServerFaultThrottle);

    test('ein GoTrue-5xx aus dem Sync-Pfad geht an Sentry', () async {
      await CrashReporter.captureSyncFailure(
        gotrue503(),
        StackTrace.current,
        context: 'auth-state-stream',
      );

      expect(gemeldet, hasLength(1),
          reason: 'der Server hat geantwortet — das ist ein Vorfall');
      final gesendet = gemeldet.single as SanitizedError;
      expect(gesendet.type, 'AuthRetryableFetchException');
      expect(gesendet.detail, 'statusCode=503');
      expect('$gesendet', isNot(contains('upstream')),
          reason: 'die Server-Nachricht bleibt draussen');
    });

    test('der Transport-Wrapper ohne Status bleibt ein Funkloch', () async {
      await CrashReporter.captureSyncFailure(
        AuthRetryableFetchException(message: 'Failed host lookup'),
        StackTrace.current,
        context: 'auth-state-stream',
      );

      expect(gemeldet, isEmpty);
    });

    test('ein Ausfall meldet sich einmal pro Fenster, nicht pro Refresh-Takt',
        () async {
      // The SDK's auto-refresh retries every 10 s during an outage, and each
      // failure reaches the auth stream again.
      final start = DateTime(2026, 10, 4, 12);
      Future<void> melden(DateTime jetzt) => withClock(
            Clock.fixed(jetzt),
            () => CrashReporter.captureSyncFailure(
              gotrue503(),
              StackTrace.current,
              context: 'auth-state-stream',
            ),
          );

      await melden(start);
      await melden(start.add(const Duration(seconds: 10)));
      await melden(start.add(CrashReporter.authServerFaultReportInterval -
          const Duration(seconds: 1)));
      expect(gemeldet, hasLength(1));

      await melden(start.add(CrashReporter.authServerFaultReportInterval));
      expect(gemeldet, hasLength(2));
    });
  });

  test('capture() selbst bleibt unveraendert — es meldet ALLES', () async {
    // The general path is unaffected: a network error outside the sync path
    // (e.g. an image upload) can well be an incident.
    await CrashReporter.capture(
      const SocketException('Connection failed'),
      StackTrace.current,
      context: 'irgendwas-anderes',
    );

    expect(gemeldet, hasLength(1));
  });
}
