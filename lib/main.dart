import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'src/app/eatova_app.dart';
import 'src/config/supabase_config.dart';
import 'src/services/apple_health_service.dart';
import 'src/services/crash_reporter.dart';
import 'src/services/notification_service.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/app_tokens.dart';

export 'src/app/eatova_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Always install: without a Sentry DSN these keep unhandled framework/async
  // errors visible in the dart:developer log. With Sentry they are chained,
  // not replaced (capture first, then our log).
  _installGlobalErrorHandlers();
  // Layouts are portrait-only. This is a request, not a guarantee:
  //  * Android: from targetSdk 36 on, Android 16 ignores orientation limits on
  //    displays with smallestWidth >= 600dp, so tablets and unfolded foldables
  //    still rotate (Review E6). No crash, just an untested layout.
  //  * iOS: the portrait-only set in ios/Runner/Info.plist holds because
  //    TARGETED_DEVICE_FAMILY = "1" makes this an iPhone-only bundle.
  //    Re-enabling iPad means bringing back the ~ipad keys.
  //  * Desktop/Web ignore setPreferredOrientations (no-op).
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);

  if (CrashReporter.dsn.isEmpty) {
    // No SENTRY_DSN (dev build, CI, tests): skip Sentry entirely — no init,
    // no network.
    await _bootAndRun();
    return;
  }

  // SentryFlutter.init does its own error zoning (appRunner +
  // OnErrorIntegration), so deliberately no runZonedGuarded around it.
  //
  // Config lives in `configureSentry` (crash_reporter.dart), not in a closure
  // here: a closure in `main()` cannot be called and therefore cannot be
  // tested. See test/services/crash_reporter_wiring_test.dart.
  await SentryFlutter.init(
    configureSentry,
    appRunner: _bootAndRun,
  );
}

Future<void> _bootAndRun() async {
  try {
    await EatovaSupabaseConfig.initialize();
  } catch (error, stack) {
    // Without this catch a boot error (missing --dart-define values,
    // unreachable Supabase) lands before runApp and iOS hangs on the white
    // launch screen. Fail visibly instead.
    //
    // `dev.log`, not `debugPrint`: in release builds Sentry's
    // DebugPrintIntegration turns debugPrint into a breadcrumb collector, so
    // the raw error and stack would reach Sentry past all sanitisation.
    // dart:developer output stays local.
    dev.log(
      'Eatova boot failed',
      name: 'boot',
      error: error,
      stackTrace: stack,
      level: 1000, // SEVERE
    );
    await CrashReporter.capture(error, stack, context: 'boot');
    runApp(_BootErrorApp(error: error));
    return;
  }
  runApp(buildEatovaApp());
}

/// The production composition of the app.
///
/// Injects the real on-device services; both are platform-gated (no-op outside
/// iOS/Android). Tests build `EatovaApp` without these parameters and get the
/// Noop implementations.
///
/// A named function, not an inline expression in [_bootAndRun], so a guard can
/// assert the injected types on the built widget
/// (`test/services/crash_reporter_wiring_test.dart`). Dropping the arguments
/// here would leave the suite green while silently killing notifications and
/// Apple Health on every device.
@visibleForTesting
EatovaApp buildEatovaApp() => EatovaApp(
      healthService: AppleHealthService(),
      notificationService: LocalNotificationService(),
    );

/// Installs the global error handlers, independently of the Sentry DSN.
///
/// Called only from `main()`; widget tests keep the test framework's own
/// `FlutterError.onError`.
void _installGlobalErrorHandlers() {
  final FlutterExceptionHandler? previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    dev.log(
      'Unbehandelter Flutter-Framework-Fehler',
      name: 'crash',
      error: details.exception,
      stackTrace: details.stack,
      level: 1000, // SEVERE
    );
    // Keep the default behaviour (console dump in debug builds).
    previousOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    dev.log(
      'Unbehandelter Platform-/Async-Fehler',
      name: 'crash',
      error: error,
      stackTrace: stack,
      level: 1000, // SEVERE
    );
    // true = handled: suppresses the platform default (abort). Sentry still
    // captures it — OnErrorIntegration wraps this handler and sends the event
    // regardless of the return value.
    return true;
  };
}

class _BootErrorApp extends StatelessWidget {
  const _BootErrorApp({required this.error});

  final Object error;

  /// Debug/profile: raw error text plus dart-define hint. Release: generic
  /// message, because '$error' can carry internal URLs or stack fragments.
  /// The error itself is already reported via CrashReporter.capture.
  static const bool showDetails = !kReleaseMode;

  @override
  Widget build(BuildContext context) {
    // Theme tokens instead of hardcoded colors, so this screen follows light
    // mode. Safe here: `buildEatovaTheme` is a pure function over
    // `AppTokens.light/dark` and depends on none of the services whose failure
    // leads to this screen.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Eatova',
      theme: buildEatovaTheme(Brightness.light),
      darkTheme: buildEatovaTheme(Brightness.dark),
      home: Builder(
        builder: (context) {
          final t = context.t;
          return Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, color: t.danger, size: 56),
                    const SizedBox(height: 16),
                    Text(
                      'Eatova konnte nicht starten',
                      style: AppType.display(
                        22,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (showDetails) ...[
                      SelectableText(
                        '$error',
                        style: AppType.ui(14, color: t.ink2),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Build braucht SUPABASE_URL + SUPABASE_ANON_KEY via\n'
                        '--dart-define-from-file=dart_defines.json.\n'
                        'Vorlage: dart_defines.example.json, Details: '
                        'README.md.',
                        style: AppType.ui(13, color: t.ink2),
                      ),
                    ] else
                      Text(
                        'Beim Start ist ein Fehler aufgetreten. Bitte starte '
                        'die App neu.\nWenn das Problem bleibt, erreichst du '
                        'uns unter support@eatova.de.',
                        style: AppType.ui(14, color: t.ink2),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
