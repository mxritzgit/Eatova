import 'dart:async';
import 'dart:developer' as dev;

import 'package:sentry_flutter/sentry_flutter.dart';

/// Schlanke, statische Facade fuer Crash-Reporting.
///
/// Der Rest der App haengt NUR an dieser Klasse, nie direkt an Sentry:
/// Fehlerpfade rufen [capture], Kontextspuren [breadcrumb]. Ob dahinter
/// wirklich Sentry sitzt, entscheidet allein das Build-Flag `SENTRY_DSN`
/// (via `--dart-define` bzw. `--dart-define-from-file=dart_defines.json`).
///
/// Ohne DSN — also in Dev-Builds, CI und Tests — ist die Facade ein
/// sauberer No-Op mit `dart:developer`-Logging: kein Netzwerk, kein Init,
/// kein Throw. `SentryFlutter.init` wird ausschliesslich in `main.dart`
/// aufgerufen (und auch dort nur bei nicht-leerem DSN).
///
/// Privacy: Die App verarbeitet Gesundheitsdaten. In [capture]/[breadcrumb]
/// gehoeren deshalb nur technische Angaben (Operation, Fehlertyp, Stack) —
/// niemals Nutzerdaten wie Gewicht, Mahlzeiten oder Health-Werte.
class CrashReporter {
  const CrashReporter._();

  /// Sentry-DSN aus `--dart-define=SENTRY_DSN=...`. Default leer:
  /// Crash-Reporting bleibt komplett aus.
  static const String dsn = String.fromEnvironment('SENTRY_DSN');

  /// True, wenn ein DSN gesetzt ist UND `SentryFlutter.init` (main.dart)
  /// erfolgreich durchgelaufen ist. In Tests immer false — dort ist der
  /// DSN leer und es existiert nur der No-Op-Hub.
  static bool get isActive => dsn.isNotEmpty && Sentry.isEnabled;

  /// Meldet einen behandelten Fehler. Loggt immer via `dart:developer`;
  /// an Sentry geht der Fehler nur, wenn [isActive]. Wirft nie selbst —
  /// die aufrufenden Fehlerpfade duerfen durch Reporting nicht kaputtgehen.
  static Future<void> capture(
    Object error,
    StackTrace stack, {
    String? context,
  }) async {
    try {
      dev.log(
        context == null ? 'capture' : 'capture ($context)',
        name: 'crash_reporter',
        error: error,
        stackTrace: stack,
        level: 1000, // SEVERE
      );
      if (!isActive) return;
      await Sentry.captureException(
        error,
        stackTrace: stack,
        withScope: (scope) {
          if (context != null) scope.setTag('context', context);
        },
      );
    } catch (e, s) {
      // Reporting-Fehler nie propagieren — bestenfalls lokal sichtbar machen.
      // Der innere try faengt auch pathologische Fehlerobjekte ab (z.B.
      // toString(), das selbst wirft).
      try {
        dev.log('CrashReporter.capture failed',
            name: 'crash_reporter', error: e, stackTrace: s);
      } catch (_) {
        // Bewusst schlucken: capture darf unter keinen Umstaenden werfen.
      }
    }
  }

  /// Haengt eine Kontextspur an den naechsten Report (z.B. "outbox replay
  /// started"). Ohne aktives Sentry nur ein `dart:developer`-Log.
  /// Wirft nie.
  static void breadcrumb(String message) {
    try {
      dev.log(message, name: 'crash_reporter');
      if (!isActive) return;
      unawaited(Sentry.addBreadcrumb(Breadcrumb(message: message)));
    } catch (e) {
      try {
        dev.log('CrashReporter.breadcrumb failed',
            name: 'crash_reporter', error: e);
      } catch (_) {
        // Bewusst schlucken: breadcrumb darf unter keinen Umstaenden werfen.
      }
    }
  }
}
