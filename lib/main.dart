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
  // Globale Fehler-Handler IMMER installieren — auch ohne Sentry-DSN sind
  // unbehandelte Framework-/Async-Fehler damit wenigstens im
  // dart:developer-Log sichtbar. Laeuft Sentry (unten), chaint es diese
  // Handler statt sie zu ersetzen: erst Sentry-Capture, dann unser Log
  // (FlutterErrorIntegration / OnErrorIntegration rufen den Vorgaenger auf).
  _installGlobalErrorHandlers();
  // Die Layouts sind nur fuer Hochformat ausgelegt. Das hier ist die Bitte um
  // Portrait — eine app-weite GARANTIE ist es NICHT, entgegen dem, was hier
  // frueher stand:
  //  * Android: ab targetSdk 36 (flutter.targetSdkVersion, siehe
  //    android/app/build.gradle.kts:49) ignoriert Android 16
  //    Orientierungs- und Resizability-Beschraenkungen auf Displays mit
  //    smallestWidth >= 600dp — Tablet und aufgeklapptes Foldable rotieren
  //    also trotzdem (Review E6). Kein Crash (configChanges deckt es ab),
  //    aber ein Layout, das dafuer nie gebaut wurde.
  //  * iOS: das Portrait-only-Set in ios/Runner/Info.plist greift, weil das
  //    Bundle seit TARGETED_DEVICE_FAMILY = "1" nur noch iPhone ist. Ein iPad
  //    laeuft im iPhone-Kompatibilitaetsmodus. Wer iPad reaktiviert, muss die
  //    ~ipad-Schluessel wieder mitdenken.
  //  * Desktop/Web ignorieren setPreferredOrientations ohnehin (No-Op).
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);

  if (CrashReporter.dsn.isEmpty) {
    // Kein SENTRY_DSN (Dev-Build, CI, Tests): Sentry komplett ueberspringen —
    // kein Init, kein Netzwerk, App startet exakt wie bisher.
    await _bootAndRun();
    return;
  }

  // SentryFlutter.init uebernimmt das Error-Zoning selbst (appRunner +
  // OnErrorIntegration statt runZonedGuarded) — deshalb hier bewusst KEIN
  // eigenes runZonedGuarded drumherum.
  //
  // Die Konfiguration steht bewusst NICHT mehr als Closure hier, sondern in
  // `configureSentry` (crash_reporter.dart). Eine Closure in `main()` ist
  // nicht aufrufbar und damit auch nicht pruefbar — genau deshalb konnte in
  // Welle 5 die Zeile `options.beforeSend = sanitizeSentryEvent;` ersatzlos
  // verschwinden, ohne dass ein Test rot wurde. Siehe
  // test/services/crash_reporter_wiring_test.dart.
  await SentryFlutter.init(
    configureSentry,
    appRunner: _bootAndRun,
  );
}

Future<void> _bootAndRun() async {
  try {
    await EatovaSupabaseConfig.initialize();
  } catch (error, stack) {
    // Ohne den Catch wuerde ein Boot-Fehler (fehlende --dart-define-Werte,
    // unerreichbares Supabase, …) vor runApp landen und iOS bliebe auf dem
    // weissen Launch-Screen haengen. Lieber sichtbar fehlschlagen.
    //
    // C1, Leck 1b: hier stand `debugPrint('Eatova boot failed: $error\n$stack')`
    // — zwei Zeilen vor dem sauberen CrashReporter.capture. Im RELEASE-Build
    // ersetzt Sentrys DebugPrintIntegration `debugPrint` durch einen
    // Breadcrumb-Sammler (debug_print_integration.dart:38), der rohe Fehler
    // samt Stack waere also als console-Breadcrumb an der ganzen
    // Sanitisierung vorbei nach Sentry gegangen. `dev.log` schreibt
    // ausschliesslich in die lokale Geraete-/IDE-Konsole; Sentry liest
    // dart:developer nicht. Die Entwickler-Diagnose beim Boot-Fehler bleibt
    // damit vollstaendig erhalten.
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

/// Die Produktions-Komposition der App.
///
/// PROD-1: echte on-device-Notification-Schicht nur in Production injizieren.
/// LocalNotificationService ist plattform-gegated (Noop ausserhalb
/// iOS/Android), ein Konstruktor-Aufruf hier ist also auch auf Desktop/Web
/// gefahrlos. Tests konstruieren `EatovaApp` bewusst OHNE diese Parameter und
/// bekommen dann `NoopNotificationService`/`NoopHealthService`.
///
/// Warum das eine eigene, aufrufbare Funktion ist und kein Inline-Ausdruck in
/// [_bootAndRun] (Fund von W6-02, Welle 6): genau darin lag dieselbe Klasse
/// von Luecke wie in C1, nur eine Ebene hoeher. `LocalNotificationService`
/// kommt in `test/`, `tool/` und den CI-Workflows NULL Mal vor, und alle
/// Tests bauen `EatovaApp` ohne den Parameter — wer das Argument hier
/// streicht, bekommt eine vollstaendig gruene Suite, sauberes
/// `flutter analyze` und exakt das D1-Schadensbild: auf jedem Geraet, an
/// jedem Tag keine geplante Benachrichtigung. Beim `healthService` dasselbe
/// fuer Apple Health und die B3-Arbeit aus Welle 2.
///
/// Die Extraktion ist eine reine Umstellung desselben Ausdrucks — der
/// Boot-Pfad bekommt genau eine Indirektion dazu, kein neues Verhalten. Der
/// Waechter dagegen ist stark: er prueft in
/// `test/services/crash_reporter_wiring_test.dart` die tatsaechlich
/// eingesetzten Typen am gebauten Widget, nicht den Quelltext.
@visibleForTesting
EatovaApp buildEatovaApp() => EatovaApp(
      healthService: AppleHealthService(),
      notificationService: LocalNotificationService(),
    );

/// Installiert die globalen Error-Handler. Bewusst unabhaengig vom DSN:
/// Ohne Sentry loggen sie via `dart:developer`, mit Sentry werden sie von
/// dessen Integrationen gechaint (Capture passiert dann zusaetzlich dort).
/// Wird nur aus `main()` aufgerufen — Widget-Tests bleiben unberuehrt, dort
/// verwaltet das Test-Framework `FlutterError.onError` selbst.
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
    // Default-Verhalten erhalten (Konsolen-Dump im Debug-Build).
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
    // true = behandelt: verhindert den Plattform-Default (Abort). Sentry
    // captured den Fehler trotzdem, weil OnErrorIntegration diesen Handler
    // wrappt und das Event unabhaengig vom Rueckgabewert verschickt.
    return true;
  };
}

class _BootErrorApp extends StatelessWidget {
  const _BootErrorApp({required this.error});

  final Object error;

  /// Debug/Profile: roher Fehlertext + dart-define-Hinweis (Entwickler-Gold).
  /// Release: generische Meldung — '$error' kann interne URLs oder
  /// Stacktrace-Fragmente enthalten, das gehoert nicht auf Nutzer-Screens.
  /// Der Fehler selbst ist zu diesem Zeitpunkt bereits via
  /// CrashReporter.capture(context: 'boot') gemeldet.
  static const bool showDetails = !kReleaseMode;

  @override
  Widget build(BuildContext context) {
    // Design-Refactor 2026-08-09: Dieser Screen stand als einzige Flaeche
    // ausserhalb von lib/src/theme/ noch auf harten Farbwerten (#111114,
    // #FF5C5C, Colors.white*). Auf einem Geraet im Hell-Modus war der
    // Bildschirm damit tiefschwarz — ausgerechnet in dem Moment, in dem der
    // Nutzer ohnehin nicht versteht, was los ist.
    //
    // Die Tokens sind hier gefahrlos: `buildEatovaTheme` ist eine reine
    // Funktion ueber `AppTokens.light/dark` und haengt an keinem der Dienste,
    // deren Ausfall ueberhaupt erst zu diesem Screen fuehrt.
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
