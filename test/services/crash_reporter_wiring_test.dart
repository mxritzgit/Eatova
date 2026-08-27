// C1, leak 3: the wiring guard.
//
// Deleting the beforeSend assignment from `main.dart` once left 84 tests green
// and `flutter analyze` clean — the whole filter was dead and nothing noticed.
//
// The configuration lives in `configureSentry` instead of a closure in
// `main.dart` because `main()` is not callable in a test (it initialises the
// binding and would spin up real Sentry with a DSN set). A named function
// taking `SentryFlutterOptions` is the seam.
//
// The BEHAVIOUR layers live here: run `configureSentry` on real options and
// assert every security-relevant assignment (Lage 1), and check the services
// actually injected into the built widget (Lage 3).
//
// The SOURCE layer — `main.dart` must pass `configureSentry` to
// `SentryFlutter.init` and must not touch `options` itself, which Lage 1 alone
// would wave through — moved to test/repo_rules_test.dart with the other
// source-text guards.

import 'package:eatova/main.dart' show buildEatovaApp;
import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('Lage 1 — configureSentry setzt die Schutzschalter wirklich', () {
    late SentryFlutterOptions options;

    setUp(() {
      options = SentryFlutterOptions();
      configureSentry(options);
    });

    test('beforeSend haengt an sanitizeSentryEvent', () {
      // Exactly the line that once went missing.
      expect(options.beforeSend, isNotNull);
      expect(options.beforeSend, sanitizeSentryEvent);
    });

    test('beforeBreadcrumb haengt an sanitizeSentryBreadcrumb', () {
      expect(options.beforeBreadcrumb, isNotNull);
      expect(options.beforeBreadcrumb, sanitizeSentryBreadcrumb);
    });

    test('enablePrintBreadcrumbs ist aus — die DebugPrintIntegration '
        'installiert sich sonst genau im Release-Build', () {
      // debug_print_integration.dart:21-27; the default is true.
      expect(options.enablePrintBreadcrumbs, isFalse);
    });

    test('keine PII, keine Screenshots, keine View-Hierarchie', () {
      expect(options.sendDefaultPii, isFalse);
      expect(options.attachScreenshot, isFalse);
      // ignore: experimental_member_use
      expect(options.attachViewHierarchy, isFalse);
    });

    test('kein Performance-Tracing und kein Session-Replay', () {
      // tracesSampleRate stays null: spans carry transaction names and thus
      // potentially routes with ids.
      expect(options.tracesSampleRate, isNull);
      expect(options.replay.sessionSampleRate, isNull);
      expect(options.replay.onErrorSampleRate, isNull);
    });

    test('der DSN kommt aus CrashReporter.dsn', () {
      expect(options.dsn, CrashReporter.dsn);
    });

    test('die Umgebung ist gesetzt — sonst laufen Dev-Crashes in Production',
        () {
      expect(options.environment, isNotEmpty);
    });

    test('configureSentry ist idempotent und wirft nicht', () {
      expect(() => configureSentry(options), returnsNormally);
      expect(options.beforeSend, sanitizeSentryEvent);
    });
  });

  // ---------------------------------------------------------------------
  // Same class of gap as C1, one level up: `EatovaApp` defaults both services
  // to their Noop variants, no test constructs it WITH the parameters, and the
  // real implementations appear nowhere else. Dropping one constructor
  // argument gives a fully green suite and the D1 damage: no scheduled
  // reminder on any device, and Apple Health dead app-wide.
  //
  // The guard checks the actually injected types on the built widget, not the
  // source, via `buildEatovaApp()` in `main.dart`.
  group('Lage 3 — main.dart komponiert die App mit den ECHTEN Diensten', () {
    test('notificationService ist LocalNotificationService (D1)', () {
      final EatovaApp app = buildEatovaApp();

      expect(app.notificationService, isNotNull,
          reason: 'null bedeutet NoopNotificationService — keine einzige '
              'geplante Erinnerung, auf jedem Geraet, an jedem Tag');
      expect(app.notificationService, isA<LocalNotificationService>());
      expect(app.notificationService, isNot(isA<NoopNotificationService>()));
    });

    test('healthService ist AppleHealthService (B3)', () {
      final EatovaApp app = buildEatovaApp();

      expect(app.healthService, isNotNull,
          reason: 'null bedeutet NoopHealthService — Apple Health app-weit '
              'tot, und der unverified-Zustand aus Welle 2 laeuft ins Leere');
      expect(app.healthService, isA<AppleHealthService>());
    });

    test('das Schadensbild ist real: ohne die Argumente greifen die Noops', () {
      // Makes the guard's rationale executable instead of asserted.
      const EatovaApp ohne = EatovaApp();

      expect(ohne.notificationService, isNull);
      expect(ohne.healthService, isNull);
    });

    test('buildEatovaApp hat keine Seiteneffekte und ist mehrfach aufrufbar',
        () {
      // The function sits in the boot path and must not initialise anything,
      // or the extraction itself would be the bigger risk.
      final EatovaApp a = buildEatovaApp();
      final EatovaApp b = buildEatovaApp();

      expect(a.notificationService, isNot(same(b.notificationService)),
          reason: 'frische Instanzen, kein geteilter Zustand');
      expect(a.healthService, isNot(same(b.healthService)));
    });
  });
}
