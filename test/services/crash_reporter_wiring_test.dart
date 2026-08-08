// C1, Leck 3 (REVIEW-2026-08-08, Welle 6): der Verdrahtungs-Waechter.
//
// Verifizierer V3 hat in Welle 5 die Zeile `options.beforeSend =
// sanitizeSentryEvent;` aus `main.dart` geloescht — 84 Tests blieben gruen und
// `flutter analyze` sauber (der Import bleibt wegen `CrashReporter.dsn`
// benutzt, es gab nicht einmal eine unused_import-Warnung). Der komplette
// Filter war also tot und NICHTS hat es gemerkt.
//
// Warum die Konfiguration jetzt in `configureSentry` steckt und nicht mehr als
// Closure in `main.dart`: `main()` ist nicht aufrufbar (es ruft
// `WidgetsFlutterBinding.ensureInitialized`, liest den compile-time-konstanten
// `SENTRY_DSN` und wuerde bei gesetztem DSN echtes Sentry initialisieren).
// Eine benannte Funktion, die `SentryFlutterOptions` entgegennimmt, ist die
// Naht, an der sich die Verdrahtung ohne DSN, ohne Netz und ohne Hub direkt
// pruefen laesst.
//
// Der Waechter hat deshalb zwei Lagen:
//   1. VERHALTEN — `configureSentry` auf ein echtes SentryFlutterOptions
//      loslassen und jede sicherheitsrelevante Zuweisung nachweisen.
//      Loescht jemand eine Zeile daraus, wird genau ein Test rot.
//   2. QUELLTEXT — `main.dart` muss `configureSentry` auch wirklich an
//      `SentryFlutter.init` uebergeben und darf `options` nicht mehr selbst
//      anfassen. Lage 1 allein wuerde eine nie aufgerufene Funktion
//      durchwinken. Das ist die schwaechere Form, aber die einzige, die den
//      Aufruf selbst abdeckt.

import 'dart:io';

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
      // Genau die Zeile, die V3 geloescht hat.
      expect(options.beforeSend, isNotNull);
      expect(options.beforeSend, sanitizeSentryEvent);
    });

    test('beforeBreadcrumb haengt an sanitizeSentryBreadcrumb', () {
      expect(options.beforeBreadcrumb, isNotNull);
      expect(options.beforeBreadcrumb, sanitizeSentryBreadcrumb);
    });

    test('enablePrintBreadcrumbs ist aus — die DebugPrintIntegration '
        'installiert sich sonst genau im Release-Build', () {
      // sentry_flutter-9.26.0/.../debug_print_integration.dart:21-27.
      // Der Default ist true (sentry_options.dart:331).
      expect(options.enablePrintBreadcrumbs, isFalse);
    });

    test('keine PII, keine Screenshots, keine View-Hierarchie', () {
      expect(options.sendDefaultPii, isFalse);
      expect(options.attachScreenshot, isFalse);
      // ignore: experimental_member_use
      expect(options.attachViewHierarchy, isFalse);
    });

    test('kein Performance-Tracing und kein Session-Replay', () {
      // tracesSampleRate bleibt null: Spans tragen Transaktionsnamen und
      // damit potenziell Routen mit IDs.
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

  group('Lage 2 — main.dart reicht die Konfiguration auch wirklich weiter', () {
    // `flutter test` laeuft mit dem Paketwurzelverzeichnis als CWD.
    final String quelle =
        File('lib/main.dart').readAsStringSync().replaceAll('\r\n', '\n');
    // Kommentarzeilen raus: der Fix wird in `main.dart` ausfuehrlich
    // begruendet, und diese Begruendung zitiert genau die Zeilen, nach denen
    // hier gesucht wird ('options.beforeSend', 'debugPrint'). Ein Kommentar
    // konfiguriert nichts und darf den Waechter deshalb weder ausloesen noch
    // beruhigen.
    final String code = quelle
        .split('\n')
        .where((String zeile) => !zeile.trimLeft().startsWith('//'))
        .join('\n');
    final String kompakt = code.replaceAll(RegExp(r'\s+'), ' ');

    test('lib/main.dart ist ueberhaupt lesbar (sonst prueft Lage 2 nichts)',
        () {
      expect(quelle, contains('SentryFlutter.init'));
      expect(code, contains('SentryFlutter.init'),
          reason: 'sonst hat das Kommentar-Filter zu viel weggeworfen');
    });

    test('SentryFlutter.init bekommt configureSentry als erstes Argument', () {
      expect(kompakt, contains('SentryFlutter.init( configureSentry,'),
          reason: 'ohne diesen Aufruf ist der ganze Filter tot — genau die '
              'Mutation, die V3 in Welle 5 unbemerkt durchbekommen hat');
    });

    test('main.dart konfiguriert die Optionen nicht mehr an configureSentry '
        'vorbei', () {
      // Eine wieder eingefuehrte Inline-Closure wuerde configureSentry
      // ersetzen, ohne dass Lage 1 es merkt.
      expect(kompakt, isNot(contains('options.')),
          reason: 'die gesamte Sentry-Konfiguration gehoert in '
              'configureSentry, wo sie testbar ist');
    });

    test('main.dart ruft debugPrint nicht mehr auf', () {
      // C1, Leck 1b: `debugPrint('Eatova boot failed: ...')` stand zwei
      // Zeilen vor dem sauberen CrashReporter.capture — und die
      // DebugPrintIntegration haette daraus im Release-Build einen
      // console-Breadcrumb mit dem rohen Fehler und dem ganzen Stack gemacht.
      expect(code, isNot(contains('debugPrint')),
          reason: 'dart:developer verlaesst das Geraet nie, debugPrint schon');
    });

    test('der Boot-Fehler wird weiterhin lokal geloggt UND gemeldet', () {
      // Der Fix darf die Entwickler-Diagnose beim Boot-Fehler nicht einfach
      // ersatzlos streichen.
      expect(kompakt, contains("name: 'boot'"));
      expect(kompakt, contains("CrashReporter.capture(error, stack, context: "
          "'boot')"));
    });
  });

  // ---------------------------------------------------------------------
  // Nachtrag Welle 6 (Fund von W6-02): dieselbe Klasse von Luecke wie C1,
  // nur eine Ebene hoeher. `runApp(EatovaApp(...))` setzte die echten
  // Dienste per Konstruktor-Argument ein — und BEIDE Argumente waren
  // ungeschuetzt:
  //
  //   * `EatovaApp` defaultet auf `notificationService ?? const
  //     NoopNotificationService()` (eatova_app.dart:89) bzw. auf
  //     `NoopHealthService`;
  //   * `LocalNotificationService` kommt in `test/`, `tool/` und den
  //     CI-Workflows NULL Mal vor;
  //   * alle Tests konstruieren `EatovaApp` absichtlich OHNE die Parameter.
  //
  // Wer das eine Argument streicht, bekommt eine vollstaendig gruene Suite
  // und sauberes `flutter analyze` — und exakt das D1-Schadensbild: auf
  // jedem Geraet, an jedem Tag keine geplante Benachrichtigung. Beim
  // healthService dasselbe fuer Apple Health und die ganze B3-Arbeit aus
  // Welle 2.
  //
  // Der Waechter ist bewusst STARK: er prueft die tatsaechlich eingesetzten
  // Typen am gebauten Widget, nicht den Quelltext. Moeglich wird das durch
  // `buildEatovaApp()` in `main.dart` — eine reine Extraktion desselben
  // Ausdrucks, die den Boot-Pfad um genau eine Indirektion erweitert.
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
      // Macht die Begruendung des Waechters ausfuehrbar statt behauptet.
      const EatovaApp ohne = EatovaApp();

      expect(ohne.notificationService, isNull);
      expect(ohne.healthService, isNull);
    });

    test('buildEatovaApp hat keine Seiteneffekte und ist mehrfach aufrufbar',
        () {
      // Die Funktion sitzt im Boot-Pfad; sie darf nichts initialisieren,
      // sonst waere die Extraktion selbst das groessere Risiko.
      final EatovaApp a = buildEatovaApp();
      final EatovaApp b = buildEatovaApp();

      expect(a.notificationService, isNot(same(b.notificationService)),
          reason: 'frische Instanzen, kein geteilter Zustand');
      expect(a.healthService, isNot(same(b.healthService)));
    });
  });
}
