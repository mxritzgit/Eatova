import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart'
    show kProfileMode, kReleaseMode, visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'sync_error_messages.dart';
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
/// niemals Nutzerdaten wie Gewicht, Mahlzeiten oder Health-Werte.
///
/// Diese Zusage ist seit REVIEW-2026-08-08 (C1) kein Kommentar mehr, sondern
/// steht auf DREI Beinen — die Facade ist naemlich laengst nicht der einzige
/// Weg nach Sentry:
///
/// 1. [sanitizeForReport] — alles, was durch [capture] laeuft.
///    (`test/services/crash_reporter_sanitize_test.dart`)
/// 2. [sanitizeSentryEvent] als `beforeSend` — unbehandelte Fehler, die
///    `FlutterErrorIntegration`, `OnErrorIntegration` und
///    `RunZonedGuardedIntegration` an der Facade vorbei abgreifen.
///    (`test/services/crash_reporter_before_send_test.dart`)
/// 3. [sanitizeSentryBreadcrumb] als `beforeBreadcrumb` — der
///    Breadcrumb-Strom, den `beforeSend` NICHT abdeckt: Breadcrumbs werden
///    in den nativen Scope gespiegelt, und ein nativer Crash-Report geht
///    ohne jeden Dart-Hook hinaus.
///    (`test/services/crash_reporter_breadcrumb_test.dart`)
///
/// Verdrahtet werden 2 und 3 von [configureSentry]; dass `main.dart` das auch
/// wirklich aufruft, sichert
/// `test/services/crash_reporter_wiring_test.dart`.
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

  /// Meldet einen fehlgeschlagenen Sync-Write — aber NUR, wenn er etwas
  /// bedeutet.
  ///
  /// Ein reiner Netzausfall auf diesem Pfad ist kein Vorfall, sondern der
  /// vorgesehene Ablauf: die Op liegt in der persistierten Warteschlange, der
  /// Nutzer hat den Hinweis gesehen, der Replay holt es nach. Bis 2026-08-10
  /// ging trotzdem jeder dieser Faelle als Fehler mit Prioritaet „hoch" an
  /// Sentry — der Feed zeigte drei Issues aus einer halben Stunde
  /// Flugmodus-Test, alle aus demselben Pfad.
  ///
  /// Das ist nicht nur Laerm. Wer in der U-Bahn eine Mahlzeit eintraegt,
  /// erzeugte einen Crash-Report; bei genug Nutzern verschwinden echte Fehler
  /// zwischen erwarteten Netzausfaellen, und das Kontingent ist verbraucht,
  /// bevor der erste echte Absturz ankommt.
  ///
  /// Die Klassifizierung ist BEWUSST dieselbe wie die fuer die Nutzer-Meldung
  /// ([isNetworkSyncError]) — ein zweiter Schwellenwert waere ein zweiter Ort,
  /// an dem beides auseinanderlaeuft.
  static Future<void> captureSyncFailure(
    Object error,
    StackTrace stack, {
    String? context,
  }) async {
    if (isNetworkSyncError(error)) {
      dev.log(
        'Sync-Write offline gescheitert — eingereiht, nicht gemeldet',
        error: error,
        name: 'eatova_sync',
      );
      return;
    }
    await capture(error, stack, context: context);
  }

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
      unawaited(Sentry.addBreadcrumb(buildBreadcrumb(message)));
    } catch (e) {
      try {
        dev.log('CrashReporter.breadcrumb failed',
            name: 'crash_reporter', error: e);
      } catch (_) {
        // Bewusst schlucken: breadcrumb darf unter keinen Umstaenden werfen.
      }
    }
  }

  /// Kategorie aller Breadcrumbs, die aus dieser Facade stammen.
  ///
  /// Ohne sie waeren die eigenen Kontextspuren nicht von fremden zu
  /// unterscheiden und wuerden vom eigenen Filter
  /// ([sanitizeSentryBreadcrumb]) mit verworfen — der laesst per Allowlist nur
  /// Kategorien durch, deren Inhalt bekannt ist.
  static const String breadcrumbCategory = 'eatova';

  /// Baut den Breadcrumb, den [breadcrumb] an Sentry gibt.
  ///
  /// Eigene Methode, damit der Test belegen kann, dass die eigenen
  /// Breadcrumbs den eigenen Filter ueberleben — sonst haette der Filter die
  /// einzige bewusst gepflegte Kontextspur der App stillschweigend
  /// abgeschaltet.
  @visibleForTesting
  static Breadcrumb buildBreadcrumb(String message) =>
      Breadcrumb(message: message, category: breadcrumbCategory);
}

/// Die vollstaendige Sentry-Konfiguration der App — die Naht, an der sich die
/// Verdrahtung testen laesst.
///
/// `main.dart` uebergibt ausschliesslich diese Funktion an
/// `SentryFlutter.init` und fasst `options` selbst nicht mehr an. Grund:
/// Verifizierer V3 hat in Welle 5 die Zeile `options.beforeSend =
/// sanitizeSentryEvent;` aus der Inline-Closure in `main.dart` geloescht — 84
/// Tests blieben gruen und `flutter analyze` sauber. Eine Closure in `main()`
/// ist nicht aufrufbar und damit auch nicht pruefbar; eine benannte Funktion
/// mit `SentryFlutterOptions`-Parameter ist es
/// (`test/services/crash_reporter_wiring_test.dart`).
void configureSentry(SentryFlutterOptions options) {
  options.dsn = CrashReporter.dsn;

  // Konservative Konfiguration — die App verarbeitet Gesundheitsdaten, es
  // darf nichts Sensibles automatisch mitgehen.
  options.sendDefaultPii = false;
  options.attachScreenshot = false;
  // Bewusst explizit, obwohl der Default `false` ist: das hier ist die Liste
  // der Schalter, die niemals umkippen duerfen. `experimental_member_use` ist
  // in Kauf genommen — ein Default-Flip in einer kuenftigen sentry_flutter-
  // Version waere deutlich teurer als diese Warnung.
  // ignore: experimental_member_use
  options.attachViewHierarchy = false;

  // C1, Leck 1 — Prevention an der Quelle. `DebugPrintIntegration` ersetzt
  // `debugPrint` durch einen Breadcrumb-Sammler und installiert sich
  // AUSGERECHNET nur im Release-Build (debug_print_integration.dart:21-27:
  // `if (isDebug || !enablePrintBreadcrumbs) return;`). Der Default ist
  // `true` (sentry_options.dart:331). In Release schreibt Flutters eigenes
  // `presentError` -> `dumpErrorToConsole` den ROHEN `toString()` jedes
  // unbehandelten Framework-Fehlers via `debugPrintStack` — also genau die
  // `ArgumentError.invalidValue`-, `FormatException.source`- und
  // `FlutterError`-Texte, die [sanitizeForReport] auf der Exception-Seite
  // zurueckhaelt.
  options.enablePrintBreadcrumbs = false;

  // C1, Leck 1 — Backstop. `enablePrintBreadcrumbs` allein reicht nicht:
  // Breadcrumbs erreichen den Hub auch aus dem nativen Scope
  // (load_contexts_integration.dart:254) und werden umgekehrt via
  // `NativeScopeObserver` IN den nativen Scope gespiegelt — ein nativer
  // Crash-Report geht dann komplett ohne Dart-`beforeSend` hinaus.
  // `Scope._addBreadCrumbSync` (scope.dart:215) ruft `beforeBreadcrumb` VOR
  // den Scope-Observern; nur dort sind beide Richtungen zu erwischen.
  options.beforeBreadcrumb = sanitizeSentryBreadcrumb;

  // C1, Leck 2/3: CrashReporter.capture sanitisiert nur, was durch die
  // Facade laeuft. FlutterErrorIntegration, OnErrorIntegration und
  // RunZonedGuardedIntegration greifen unbehandelte Fehler DIREKT ab.
  options.beforeSend = sanitizeSentryEvent;

  // Bewusst NICHT gesetzt und deshalb im Wiring-Test festgenagelt:
  // `tracesSampleRate` (Spans tragen Transaktionsnamen, also Routen) und
  // `replay.*` (Session-Replay filmt den Bildschirm). Beide Defaults sind
  // aus; hier stuende sonst der teuerste Datenschutz-Unfall der App.
  options.environment = kReleaseMode
      ? 'production'
      : kProfileMode
          ? 'profile'
          : 'development';
}

/// Breadcrumb-Kategorien, deren Inhalt bekannt und frei von Nutzerdaten ist.
///
/// Allowlist, nicht Blocklist — dieselbe Linie wie bei [sanitizeForReport].
/// Eine neue Sentry-Version oder ein neues Plugin, das eine bisher unbekannte
/// Kategorie erzeugt, faellt damit in den zumachenden Default-Zweig.
///
/// | Kategorie | Erzeuger | Inhalt | Entscheidung |
/// |---|---|---|---|
/// | `eatova` | [CrashReporter.breadcrumb] | Konstanten + Zaehler | durch |
/// | `app.lifecycle` | `widgets_binding_observer.dart:82` | `resumed`/`paused` | durch |
/// | `ui.lifecycle` | Android-Activity-Lifecycle | auf Flutter immer `MainActivity` | durch |
/// | `device.screen` | `widgets_binding_observer.dart:130` | Groesse, DPR | durch |
/// | `device.event` | `widgets_binding_observer.dart:153` | Helligkeit, textScaleFactor, Locale | durch |
/// | `device.orientation` | nativ | portrait/landscape | durch |
/// | `device.connectivity` | `connectivity_integration.dart:29` | wifi/cellular/none | durch |
/// | `console` | `debug_print_integration.dart:59` | **beliebiger Freitext** | VERWORFEN |
/// | `navigation` | `SentryNavigatorObserver` | Routennamen — `/meal/<uuid>` waere eine Nutzerkennung | VERWORFEN |
/// | `ui.click` | `sentry_user_interaction_widget.dart:375` | Widget-Label = angezeigter Nutzertext | VERWORFEN |
/// | `http` | native Netzwerk-Instrumentierung | URL mit User-UUID im Filter | GEKUERZT |
/// | (alles andere, inkl. `category == null`) | | unbekannt | VERWORFEN |
///
/// `navigation` und `ui.click` entstehen heute nicht — die App registriert
/// weder `SentryNavigatorObserver` noch `SentryUserInteractionWidget`. Sie
/// hier trotzdem zuzumachen kostet nichts und schliesst genau den Fall, in
/// dem jemand spaeter eine Route `/meal/<id>` oder einen Mahlzeiten-Button
/// hinzufuegt und der Breadcrumb-Strom lautlos Inhalte mitnimmt.
const Set<String> _erlaubteBreadcrumbKategorien = <String>{
  CrashReporter.breadcrumbCategory,
  'app.lifecycle',
  'ui.lifecycle',
  'device.screen',
  'device.event',
  'device.orientation',
  'device.connectivity',
  'sentry.event',
  'sentry.transaction',
};

/// Felder aus `Breadcrumb.http`, die keine Laufzeitwerte tragen.
///
/// Nicht dabei: `reason` (die rohe Server-Begruendung), `http.query` und
/// `http.fragment` (die PostgREST-Query traegt die User-UUID im Filter) sowie
/// `url`, das gesondert auf `scheme://host` gekuerzt wird.
const Set<String> _erlaubteHttpDatenfelder = <String>{
  'method',
  'status_code',
  'duration',
  'request_body_size',
  'response_body_size',
  'start_timestamp',
  'end_timestamp',
};

/// `beforeBreadcrumb`-Hook fuer [configureSentry] — C1, Leck 1.
///
/// Laeuft in `Scope._addBreadCrumbSync` (scope.dart:215) und damit VOR den
/// Scope-Observern, die den Breadcrumb in den nativen Scope spiegeln. Nur an
/// dieser Stelle erwischt man auch die Breadcrumbs, die spaeter in einem
/// NATIVEN Crash-Report landen — der geht komplett ohne Dart-`beforeSend`
/// hinaus.
///
/// Wirft nie: `Scope` faengt einen Throw zwar ab (scope.dart:228-238), laesst
/// den Breadcrumb dann aber DURCH. Zumachen muss also hier passieren.
Breadcrumb? sanitizeSentryBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  try {
    if (breadcrumb == null) return null;
    final String? kategorie = breadcrumb.category;
    // Ohne Kategorie ist die Herkunft unbekannt — das trifft u.a. den
    // `print()`-Breadcrumb-Pfad und jedes handgebaute `Breadcrumb(message:)`
    // aus einer Fremdbibliothek.
    if (kategorie == null) return null;
    if (kategorie == 'http') return _kuerzeHttpBreadcrumb(breadcrumb);
    if (!_erlaubteBreadcrumbKategorien.contains(kategorie)) return null;
    return breadcrumb;
  } catch (_) {
    // Im Zweifel verwerfen: ein fehlender Breadcrumb kostet Diagnose, ein
    // durchgelassener kostet Gesundheitsdaten.
    return null;
  }
}

/// `http`-Breadcrumbs werden gekuerzt statt verworfen: Methode, Status und
/// Dauer sind die eigentliche Diagnose eines Sync-Fehlers, und die stecken
/// nicht in der URL. Weg muessen Pfad und Query — `?user_id=eq.<uuid>` bei
/// PostgREST, `meal-images/<uuid>/...` bei Storage.
Breadcrumb _kuerzeHttpBreadcrumb(Breadcrumb breadcrumb) {
  // Der Freitext eines http-Breadcrumbs ist bei nativer Instrumentierung die
  // ganze Request-Zeile.
  breadcrumb.message = null;
  final Map<String, dynamic>? daten = breadcrumb.data;
  if (daten == null) return breadcrumb;
  final Map<String, dynamic> gefiltert = <String, dynamic>{};
  for (final MapEntry<String, dynamic> feld in daten.entries) {
    if (_erlaubteHttpDatenfelder.contains(feld.key)) {
      gefiltert[feld.key] = feld.value;
    }
  }
  gefiltert['url'] = _nurHerkunft(daten['url']);
  breadcrumb.data = gefiltert;
  return breadcrumb;
}

/// Reduziert eine URL auf `scheme://host`. Alles, was sich nicht sicher als
/// http(s)-URL mit Host lesen laesst, faellt auf den Platzhalter — nie auf
/// den Rohwert.
String _nurHerkunft(Object? url) {
  const String entfernt = '<URL entfernt>';
  if (url is! String) return entfernt;
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return entfernt;
  if (uri.scheme != 'http' && uri.scheme != 'https') return entfernt;
  return '${uri.scheme}://${uri.host}';
}

/// Kontext-Schluessel, die Sentry serialisieren darf.
///
/// `Contexts.toJson` (contexts.dart:315-318) schiebt jeden UNBEKANNTEN
/// Schluessel im `default:`-Zweig unveraendert hinaus — genau darueber geht
/// `flutter_error_details` (flutter_error_integration.dart:72) samt dem
/// gerenderten `informationCollector`-Text raus.
///
/// Durchgelassen bleibt die echte Diagnostik: Geraet, OS, Runtime, App,
/// Browser, GPU, Kultur und der Trace-Kontext. Verworfen werden
/// * `flutter_error_details` und jeder andere unbekannte Schluessel;
/// * `feedback` — `SentryFeedback` haelt woertlichen Nutzertext plus
///   Kontakt-E-Mail und Namen; die App hat gar keinen Feedback-Flow, ein
///   gefuelltes Feld waere also immer ein Unfall;
/// * `response` — HTTP-Antwort-Metadaten inkl. Header, wird nur ueber
///   `Hint.response` gefuellt und von der App nie;
/// * `flags` — Feature-Flag-Auswertungen sind Nutzersegmentierung.
const Set<String> _erlaubteContextSchluessel = <String>{
  'app',
  'device',
  'os',
  'runtime',
  'runtimes',
  'browser',
  'gpu',
  'culture',
  'trace',
};

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

/// `beforeSend`-Hook fuer [configureSentry] — die zweite Haelfte von C1.
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
///
/// Bis Welle 5 fasste diese Funktion AUSSCHLIESSLICH `exceptions[].value` an.
/// Das ist zu wenig — die Events, die C1 aufreisst, haben oft gar keine
/// `exceptions`: `FlutterErrorIntegration` baut sein Event aus `throwable`
/// plus `contexts['flutter_error_details']`
/// (flutter_error_integration.dart:66-76). Deshalb jetzt ein Durchgang ueber
/// das ganze Event:
///
/// | Feld | Entscheidung | Grund |
/// |---|---|---|
/// | `exceptions[].value` | sanitisiert | siehe [sanitizeForReport] |
/// | `exceptions[].type`/`stackTrace` | durch | Typnamen und Zeilennummern, keine Werte |
/// | `contexts` | Allowlist | `flutter_error_details` traegt den Diagnostics-Baum |
/// | `message` | auf `template` reduziert | `formatted`/`params` SIND die Laufzeitwerte |
/// | `breadcrumbs` | gefiltert | zweite Reihe hinter [sanitizeSentryBreadcrumb] |
/// | `extra` | verworfen | beliebige Schluessel ohne Schema, von der App nie benutzt |
/// | `request` | verworfen | URL, Query, Cookies und Header in einem Feld |
/// | `user` | verworfen | die App identifiziert bewusst niemanden |
/// | `tags` | durch | nur `context` und `error_type` aus [CrashReporter.capture] |
/// | `transaction`/`culprit`/`fingerprint`/`modules`/`sdk`/`debugMeta` | durch | uebersetzungszeit-fest |
///
/// Wirft nie: `sentry_client.dart:571` loggt einen Throw aus `beforeSend` nur
/// und verwirft anschliessend das GANZE Event (`:580`). Ein kaputter Filter
/// waere also ein stiller Totalausfall des Crash-Reportings.
SentryEvent? sanitizeSentryEvent(SentryEvent event, Hint hint) {
  try {
    _sanitisiereExceptions(event);
    _sanitisiereContexts(event);
    _sanitisiereMessage(event);
    _sanitisiereBreadcrumbs(event, hint);
    // ignore: deprecated_member_use
    event.extra = null;
    event.request = null;
    event.user = null;
  } catch (_) {
    // Anders als beim Breadcrumb ist Verwerfen hier die schlechtere Option:
    // ohne Event gibt es keine Diagnose mehr. Also wenigstens die Felder
    // leeren, die ueberhaupt Freitext tragen koennen, und das Geruest
    // (Typ, Stack, Tags) stehen lassen.
    try {
      event.message = null;
      event.breadcrumbs = null;
      // ignore: deprecated_member_use
      event.extra = null;
      event.request = null;
      event.user = null;
      for (final SentryException e in event.exceptions ?? const []) {
        e.value = e.type ?? 'Exception';
      }
    } catch (_) {
      // Bewusst schlucken: beforeSend darf unter keinen Umstaenden werfen.
    }
  }
  return event;
}

void _sanitisiereExceptions(SentryEvent event) {
  final List<SentryException>? exceptions = event.exceptions;
  if (exceptions == null || exceptions.isEmpty) return;
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
}

/// C1, Leck 2. `Contexts` ist eine `MapView`; die Schluessel werden vorher
/// kopiert, sonst gaebe es eine ConcurrentModificationError beim Entfernen.
void _sanitisiereContexts(SentryEvent event) {
  final Contexts contexts = event.contexts;
  for (final String schluessel in contexts.keys.toList(growable: false)) {
    if (!_erlaubteContextSchluessel.contains(schluessel)) {
      contexts.remove(schluessel);
    }
  }
}

/// `SentryMessage.formatted` traegt die eingesetzten Laufzeitwerte,
/// `template` ist ein Literal aus dem Quelltext — und reicht Sentry zum
/// Gruppieren. Das Event ganz ohne Message zu lassen waere schlechter: dann
/// gruppiert Sentry alles zusammen.
void _sanitisiereMessage(SentryEvent event) {
  final SentryMessage? message = event.message;
  if (message == null) return;
  message.formatted = message.template ?? '<Nachricht entfernt>';
  message.params = null;
}

/// Zweite Reihe hinter [sanitizeSentryBreadcrumb]: `load_contexts_integration
/// .dart:263` schreibt native Breadcrumbs direkt nach `event.breadcrumbs`,
/// und ein Event kann auch von Hand mit Breadcrumbs gebaut werden.
void _sanitisiereBreadcrumbs(SentryEvent event, Hint hint) {
  final List<Breadcrumb>? breadcrumbs = event.breadcrumbs;
  if (breadcrumbs == null) return;
  event.breadcrumbs = breadcrumbs
      .map((Breadcrumb b) => sanitizeSentryBreadcrumb(b, hint))
      .whereType<Breadcrumb>()
      .toList();
}

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
///
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
