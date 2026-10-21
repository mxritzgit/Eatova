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
import 'package:eatova/src/services/app_shortcuts.dart';
import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/android_health_service.dart';
import 'package:flutter/foundation.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  test('Lage 1 — configureSentry setzt jeden Schutzschalter wirklich', () {
    final options = SentryFlutterOptions();
    configureSentry(options);

    // Exactly the line that once went missing.
    expect(options.beforeSend, sanitizeSentryEvent);
    expect(options.beforeBreadcrumb, sanitizeSentryBreadcrumb);
    expect(options.enablePrintBreadcrumbs, isFalse,
        reason: 'the DebugPrintIntegration would otherwise install itself '
            'in exactly the release build (default true)');
    expect(options.sendDefaultPii, isFalse);
    expect(options.attachScreenshot, isFalse);
    // ignore: experimental_member_use
    expect(options.attachViewHierarchy, isFalse);
    // Spans carry transaction names and thus potentially routes with ids.
    expect(options.tracesSampleRate, isNull);
    expect(options.replay.sessionSampleRate, isNull);
    expect(options.replay.onErrorSampleRate, isNull);
    // Review P10-01: session envelopes are built by the NATIVE SDKs and
    // never pass beforeSend. PRIVACY.md promises "errors, not usage" and
    // PrivacyInfo.xcprivacy declares no ProductInteraction; the SDK default
    // is true, so the option must be set.
    expect(options.enableAutoSessionTracking, isFalse);
    expect(options.dsn, CrashReporter.dsn);
    expect(options.environment, isNotEmpty,
        reason: 'otherwise dev crashes land in production');
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

    test('appShortcuts ist PlatformAppShortcuts', () {
      // Null puts nothing on the app icon and clears nothing at sign-out.
      expect(buildEatovaApp().appShortcuts, isA<PlatformAppShortcuts>());
    });

    test('healthService ist AppleHealthService (B3)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final EatovaApp app = buildEatovaApp();

      expect(app.healthService, isNotNull,
          reason: 'null bedeutet NoopHealthService — Apple Health app-weit '
              'tot, und der unverified-Zustand aus Welle 2 laeuft ins Leere');
      expect(app.healthService, isA<AppleHealthService>());
    });

    test('healthService uses Health Connect on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(buildEatovaApp().healthService, isA<AndroidHealthService>());
    });
  });
}
