import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, FunctionException, PostgrestException, StorageException;

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
/// niemals Nutzerdaten wie Gewicht, Mahlzeiten oder Health-Werte. Diese
/// Zusage ist seit REVIEW-2026-08-08 (C1) nicht mehr nur ein Kommentar,
/// sondern wird von [sanitizeForReport] durchgesetzt und in
/// `test/services/crash_reporter_sanitize_test.dart` nachgewiesen.
class CrashReporter {
  const CrashReporter._();

  /// Sentry-DSN aus `--dart-define=SENTRY_DSN=...`. Default leer:
  /// Crash-Reporting bleibt komplett aus.
  static const String dsn = String.fromEnvironment('SENTRY_DSN');

  /// True, wenn ein DSN gesetzt ist UND `SentryFlutter.init` (main.dart)
  /// erfolgreich durchgelaufen ist. In Tests immer false — dort ist der
  /// DSN leer und es existiert nur der No-Op-Hub.
  static bool get isActive => dsn.isNotEmpty && Sentry.isEnabled;

  /// Testnaht. Ist sie gesetzt, geht das Objekt, das SONST an
  /// `Sentry.captureException` ginge, stattdessen hierher — mit exakt
  /// demselben Inhalt und an exakt derselben Stelle im Ablauf.
  ///
  /// Produktiv ist sie IMMER `null` (der Pfad existiert dann nicht). Sie ist
  /// die einzige Moeglichkeit, ohne DSN, ohne Netz und ohne Sentry-Hub zu
  /// belegen, WAS Sentry bekommen wuerde — und damit die einzige Moeglichkeit,
  /// die Datenschutz-Zusage im Klassen-Header zu TESTEN statt sie nur zu
  /// behaupten. Sie sitzt bewusst VOR der [isActive]-Schranke: mit leerem DSN
  /// waere hinter der Schranke nie etwas zu beobachten.
  @visibleForTesting
  static void Function(Object error, StackTrace stack, String? context)?
      debugSentrySink;

  /// Testnaht fuer [breadcrumb], analog zu [debugSentrySink].
  @visibleForTesting
  static void Function(String message)? debugBreadcrumbSink;

  /// Meldet einen behandelten Fehler. Loggt immer via `dart:developer`;
  /// an Sentry geht — sanitisiert — nur, wenn [isActive]. Wirft nie selbst:
  /// die aufrufenden Fehlerpfade duerfen durch Reporting nicht kaputtgehen.
  ///
  /// Was Sentry bekommt, entscheidet [sanitizeForReport], nicht der Aufrufer.
  /// Damit ist es egal, ob ein Aufrufer weiss, dass sein `error` gerade eine
  /// halbe `profiles`-Zeile mitschleppt.
  static Future<void> capture(
    Object error,
    StackTrace stack, {
    String? context,
  }) async {
    try {
      // Bewusst das ROHE Objekt: dart:developer schreibt ausschliesslich in
      // die lokale Geraete-/IDE-Konsole und verlaesst das Geraet nie. Sentry
      // liest dart:developer nicht (die Integrationen haengen an `print`,
      // `FlutterError.onError` und `PlatformDispatcher.onError`). Beim
      // Entwickeln bleibt so die volle Fehlermeldung sichtbar.
      dev.log(
        context == null ? 'capture' : 'capture ($context)',
        name: 'crash_reporter',
        error: error,
        stackTrace: stack,
        level: 1000, // SEVERE
      );
      final sink = debugSentrySink;
      // Ohne Senke und ohne aktives Sentry hat niemand einen Abnehmer — dann
      // gar nicht erst sanitisieren. Das ist der Normalfall in Dev, CI und
      // Tests, und `capture` sitzt in Fehlerpfaden, die in Schleifen laufen
      // koennen (Outbox-Replay).
      if (sink == null && !isActive) return;

      final SanitizedError sanitized = sanitizeForReport(error);
      if (sink != null) {
        sink(sanitized, stack, context);
        return;
      }
      await Sentry.captureException(
        // Nie `error` — siehe sanitizeForReport.
        sanitized,
        // Der Stacktrace bleibt ROH und vollstaendig. Ein Dart-Stacktrace
        // besteht aus Bibliotheks-URIs, Klassen-/Methodennamen und
        // Zeilennummern — alles zur Uebersetzungszeit festgelegt. Laufzeit-
        // WERTE (Argumente, Feldinhalte, Empfaenger) stehen nirgends darin,
        // also auch keine Gewichte, Mahlzeiten oder E-Mail-Adressen. Ohne
        // ihn waere ein sanitisierter Report nicht mehr zuzuordnen — der
        // Stack ist nach dem Zumachen die eigentliche Diagnose.
        stackTrace: stack,
        withScope: (scope) {
          if (context != null) scope.setTag('context', context);
          // Sentry setzt den Event-`type` aus `runtimeType`, das waere jetzt
          // fuer JEDEN Report `SanitizedError`. Der echte Typ steht im
          // `value` (siehe SanitizedError.toString) und zusaetzlich hier als
          // Tag, damit man in Sentry danach filtern und gruppieren kann.
          scope.setTag('error_type', sanitized.type);
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
  ///
  /// [message] ist bewusst NICHT sanitisierbar — ein Freitext laesst sich
  /// nicht automatisch von Nutzerdaten trennen. Die Verantwortung liegt beim
  /// Aufrufer: hier gehoeren nur Konstanten und Zaehler hinein, nie Werte aus
  /// Profil, Mahlzeiten oder Gewichtsreihe. Die beiden realen Aufrufer
  /// (`home_store.dart:306`, `home_store_sync.dart:194`) interpolieren
  /// ausschliesslich `capped.dropped.length`.
  static void breadcrumb(String message) {
    try {
      dev.log(message, name: 'crash_reporter');
      final sink = debugBreadcrumbSink;
      if (sink != null) {
        sink(message);
        return;
      }
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

/// Das EINZIGE Fehlerobjekt, das diese Facade an Sentry weitergibt.
///
/// Sentry baut sein Event aus genau zwei Strings des Throwables
/// (`sentry_exception_factory.dart:60/64`): `value = throwable.toString()`
/// und `type = throwable.runtimeType.toString()`. Beides ist hier
/// konstruktionsbedingt frei von Nutzerdaten, weil die Klasse nur zwei
/// bereits gefilterte Strings haelt.
class SanitizedError implements Exception {
  const SanitizedError(this.type, [this.detail]);

  /// Der Laufzeittyp des urspruenglichen Fehlers, z.B. `PostgrestException`.
  final String type;

  /// Die durchgelassenen technischen Felder, z.B. `code=23514`. Null, wenn
  /// der Typ nicht auf der Allowlist steht.
  final String? detail;

  @override
  String toString() => detail == null ? type : '$type $detail';
}

/// Typnamen app-EIGENER Fehlerobjekte, die per Konstruktion schon sanitisiert
/// sind und deren `toString()` deshalb komplett durchgelassen wird.
///
/// Aktuell nur `UndecryptableCacheSlot` (`secure_cache_store.dart`): dessen
/// Felder sind ein Fehlertypname und ein bereits per `redactUserSegment`
/// um die User-UUID gekuerzter Slot-Key. Wuerde er in den Default-Zweig
/// fallen, ginge genau die Information verloren, fuer die er gebaut wurde —
/// WELCHER Slot sich nicht entschluesseln liess.
///
/// Bewusst ueber den Namen und nicht ueber `is UndecryptableCacheSlot`:
/// `secure_cache_store.dart` importiert bereits `crash_reporter.dart`, der
/// typisierte Weg waere ein Importzyklus zwischen einer Facade und einem
/// Service, der auf ihr aufsetzt. Der Namensvergleich schlaegt unter
/// `--obfuscate` fehl — und faellt dann in den zumachenden Default-Zweig,
/// also in die sichere Richtung.
const Set<String> _sanitisiertPerKonstruktion = <String>{
  'UndecryptableCacheSlot',
};

/// Reduziert ein beliebiges Fehlerobjekt auf das, was Sentry sehen darf.
///
/// **Allowlist, nicht Blocklist.** Ein unbekannter Typ liefert ausschliesslich
/// seinen Typnamen; nichts vom Inhalt. Eine neue Abhaengigkeit mit einem
/// geschwaetzigen `toString()` (der Regelfall, siehe unten) kann damit nichts
/// aufreissen, ohne dass jemand hier bewusst einen Zweig ergaenzt.
///
/// Warum das noetig ist — die `toString()`s, die real bei [CrashReporter
/// .capture] ankommen, tragen fast alle Fremddaten:
///
/// | Typ | `toString()` enthaelt | durchgelassen |
/// |---|---|---|
/// | `PostgrestException` | message, code, **details**, hint | `code` |
/// | `AuthException` (+ alle Subklassen) | **message**, statusCode, code, originalError, reasons | `statusCode`, `code` |
/// | `StorageException` | **message**, statusCode, error | `statusCode` |
/// | `FunctionException` (+ Subklassen) | status, **details**, reasonPhrase | `status` |
/// | `PlatformException` | code, **message**, **details** | `code` |
/// | `TimeoutException` | **message**, duration | `duration` |
/// | `TypeError` | nur Typnamen | alles |
/// | alles andere | unbekannt | nur `runtimeType` |
///
/// Das gefaehrlichste Feld ist `PostgrestException.details`: PostgREST fuellt
/// es aus PostgreSQLs `DETAIL`, und bei einer CHECK-Verletzung (23514) ist
/// das `Failing row contains (<uuid>, <email>, <name>, …, 25, 178, 34)` —
/// Identitaet plus Art.-9-Gesundheitswerte in einem String.
///
/// Was NICHT durchgelassen wird und warum:
/// * jede `message` — bei Supabase serverseitig erzeugt und regelmaessig mit
///   der E-Mail-Adresse darin ("A user with this email address … has already
///   been registered");
/// * jede `uri` — die PostgREST-Query traegt die User-UUID im Filter;
/// * `FormatException.source` und `JsonUnsupportedObjectError` — das ist der
///   rohe Response-Body bzw. das nicht kodierbare Objekt selbst;
/// * `ArgumentError.invalidValue` / `RangeError` — genau der getippte
///   Gewichts- oder Groessenwert, der den Fehler ausgeloest hat;
/// * `NoSuchMethodError` — enthaelt Empfaenger UND Argumente;
/// * `AssertionError`/`FlutterError` — rendern ihren Diagnostics-Baum inkl.
///   Widget-Beschreibungen und damit potenziell angezeigten Nutzertext.
///
/// [TypeError] ist die einzige Ausnahme mit vollem `toString()`: den Text
/// erzeugt die Dart-Laufzeit aus Typnamen ("type 'Null' is not a subtype of
/// type 'String'"). Er kann keine Werte enthalten und ist zugleich die
/// wertvollste Diagnose ueberhaupt.
/// `beforeSend`-Hook fuer `SentryFlutter.init` — die zweite Haelfte von C1.
///
/// [CrashReporter.capture] ist NICHT der einzige Weg nach Sentry:
/// `SentryFlutter.init` installiert `FlutterErrorIntegration`,
/// `OnErrorIntegration` und `RunZonedGuardedIntegration`, die unbehandelte
/// Fehler direkt abgreifen und an dieser Facade vorbeilaufen. Eine
/// `PostgrestException` aus einem nicht gefangenen Future ginge sonst roh
/// hinaus, samt `Failing row contains (<uuid>, <email>, ..., 25, 178, 34)`.
///
/// Sentry baut `SentryException.value` aus `throwable.toString()`
/// (`sentry_exception_factory.dart:60`) — genau dieser Wert wird hier durch
/// die sanitisierte Fassung ersetzt. `type` bleibt stehen, damit die
/// Gruppierung in Sentry weiter funktioniert.
///
/// Absichtlich eine benannte Top-Level-Funktion statt einer Closure in
/// `main.dart`: nur so ist der Hook testbar.
SentryEvent? sanitizeSentryEvent(SentryEvent event, Hint hint) {
  final List<SentryException>? exceptions = event.exceptions;
  if (exceptions == null || exceptions.isEmpty) return event;
  for (final SentryException e in exceptions) {
    // Direkte Zuweisung statt copyWith: `copyWith` ist in sentry 9.26
    // deprecated ("Assign values directly to the instance"), und `value` ist
    // ein mutables Feld (`sentry_exception.dart:12`). Das Event geht direkt
    // im Anschluss raus, ein geteiltes Objekt ist hier also unkritisch.
    //
    // `throwable` bleibt stehen: es wird nicht serialisiert (`toJson` kennt
    // nur type/value/module/stacktrace/mechanism/thread_id), verlaesst das
    // Geraet also nie, und Sentrys Gruppierung liest es noch.
    //
    // Ohne `throwable` (Events aus dem nativen Layer) darf `e.type` NICHT
    // durch sanitizeForReport laufen: das ist ein String und liefe in den
    // Default-Zweig, der `String` zurueckgaebe statt `PostgrestException`.
    // `type` ist per Konstruktion ein Typname
    // (`sentry_exception_factory.dart:64`), also selbst schon sauber — die
    // Nutzerdaten stecken ausschliesslich in `value`.
    e.value = e.throwable == null
        ? SanitizedError(e.type ?? 'Exception').toString()
        : sanitizeForReport(e.throwable as Object).toString();
  }
  return event;
}

/// Nicht `@visibleForTesting`: [sanitizeSentryEvent] braucht die Funktion
/// produktiv, und `secure_cache_store` filtert bereits selbst vor.
SanitizedError sanitizeForReport(Object error) {
  try {
    // Idempotent: doppelt sanitisieren aendert nichts. Wichtig, weil Aufrufer
    // (z.B. secure_cache_store) schon selbst vorfiltern duerfen.
    if (error is SanitizedError) return error;

    final String typ = error.runtimeType.toString();

    if (_sanitisiertPerKonstruktion.contains(typ)) {
      return SanitizedError(typ, error.toString());
    }

    if (error is PostgrestException) {
      // Der SQLSTATE ist die Diagnose: 23514 = CHECK-Verletzung,
      // 23505 = Unique, 42501 = RLS. Kein Nutzerinhalt.
      return SanitizedError(typ, _feld('code', error.code));
    }
    if (error is AuthException) {
      // Deckt AuthApiException, AuthSessionMissingException,
      // AuthRetryableFetchException, AuthWeakPasswordException,
      // AuthInvalidJwtException, AuthPKCEGrantCodeExchangeError und
      // AuthUnknownException mit ab — `typ` haelt die konkrete Subklasse
      // fest. `originalError` (eine rohe http.Response samt Body) und
      // `reasons` bleiben bewusst aussen vor.
      return SanitizedError(
        typ,
        _felder(<String, Object?>{
          'statusCode': error.statusCode,
          'code': error.code,
        }),
      );
    }
    if (error is StorageException) {
      // `error` (der Server-Slug) bleibt draussen: er kommt roh aus der
      // Antwort und ist damit nicht kontrollierbar.
      return SanitizedError(typ, _feld('statusCode', error.statusCode));
    }
    if (error is FunctionException) {
      // `details` ist der rohe Function-Response-Body. Bei analyze-meal ist
      // das die erkannte Mahlzeit des Nutzers.
      return SanitizedError(typ, _feld('status', error.status));
    }
    if (error is PlatformException) {
      // `code` ist ein vom Plugin vergebener Konstant-String
      // ("sign_in_failed", "camera_access_denied"). `details` ist beliebig.
      return SanitizedError(typ, _feld('code', error.code));
    }
    if (error is TimeoutException) {
      return SanitizedError(typ, _feld('duration', error.duration));
    }
    if (error is TypeError) {
      return SanitizedError(typ, error.toString());
    }

    // Default: zu. Nur der Typname.
    return SanitizedError(typ);
  } catch (_) {
    // Selbst `runtimeType.toString()` darf hier nichts umbringen. Ein
    // nutzloser Report ist besser als ein verlorener — und besser als ein
    // Throw aus einem Fehlerpfad heraus.
    return const SanitizedError('<Fehlertyp nicht ermittelbar>');
  }
}

String? _feld(String name, Object? wert) => wert == null ? null : '$name=$wert';

String? _felder(Map<String, Object?> werte) {
  final Iterable<String> gesetzt = werte.entries
      .where((e) => e.value != null)
      .map((e) => '${e.key}=${e.value}');
  return gesetzt.isEmpty ? null : gesetzt.join(' ');
}
