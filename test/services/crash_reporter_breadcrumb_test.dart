// C1, Leck 1 (REVIEW-2026-08-08, Welle 6): Breadcrumbs.
//
// `sanitizeSentryEvent` hat bis Welle 5 ausschliesslich `exceptions[].value`
// angefasst. Der zweite, voellig ungefilterte Weg nach Sentry sind
// Breadcrumbs — und der gefaehrlichste Erzeuger installiert sich AUSGERECHNET
// im Release-Build:
//
//   sentry_flutter-9.26.0/lib/src/integrations/debug_print_integration.dart:21
//     final isDebug = options.runtimeChecker.isDebugMode();
//     if (isDebug || !enablePrintBreadcrumbs) return;
//     debugPrint = _debugPrint;   // -> Breadcrumb.console(message: ...)
//
// Der Erzeuger ist nicht nur eigener Code: `FlutterError.presentError` ruft in
// Release `dumpErrorToConsole` (flutter/lib/src/foundation/assertions.dart
// :1033) und das macht `debugPrintStack(label: details.exception.toString())`.
// Damit wird der ROHE `toString()` jedes unbehandelten Framework-Fehlers zum
// Breadcrumb — also genau `ArgumentError.invalidValue` (der getippte
// Gewichtswert), `FormatException.source` (roher Response-Body) und
// `FlutterError` (Diagnostics-Baum mit angezeigtem Nutzertext), die
// `sanitizeForReport` auf der Exception-Seite zurueckhaelt.
//
// Warum ein Filter und nicht nur `enablePrintBreadcrumbs = false`: Breadcrumbs
// erreichen den Hub auch aus dem nativen Scope (load_contexts_integration
// .dart:254) und werden umgekehrt via `NativeScopeObserver` in den nativen
// Scope gespiegelt — ein nativer Crash-Report geht dann ohne Dart-`beforeSend`
// raus. `Scope._addBreadCrumbSync` (sentry-9.26.0/lib/src/scope.dart:215) ruft
// `beforeBreadcrumb` VOR den Scope-Observern; nur dort erwischt man beide
// Richtungen.

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('sanitizeSentryBreadcrumb — console (der Release-Kanal)', () {
    test(
        'ein console-Breadcrumb aus einem unbehandelten ArgumentError traegt '
        'den getippten Gewichtswert und wird deshalb komplett verworfen', () {
      // Genau die Form, die `debugPrintStack(label: exception.toString())`
      // erzeugt, wenn der Nutzer 187.4 statt 87.4 kg eintippt.
      final crumb = Breadcrumb.console(
        message: 'Invalid argument (weightKg): Must be between 30 and 300: '
            '187.4',
        level: SentryLevel.debug,
      );

      expect(sanitizeSentryBreadcrumb(crumb, Hint()), isNull,
          reason: 'console-Text ist Freitext und nicht sanitisierbar');
    });

    test(
        'auch der eigene Boot-debugPrint mit rohem Fehler und Stack wird '
        'verworfen', () {
      final crumb = Breadcrumb.console(
        message: 'Eatova boot failed: PostgrestException(message: new row for '
            'relation "profiles" ..., details: Failing row contains '
            '(0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0, max@example.com, Max '
            'Mustermann, 25, 178, 34).)\n#0 main',
      );

      expect(sanitizeSentryBreadcrumb(crumb, Hint()), isNull);
    });

    test('ein print()-Breadcrumb ohne Kategorie wird ebenfalls verworfen', () {
      // Default-Zweig: Herkunft unbekannt -> zu. Allowlist, nicht Blocklist.
      final crumb = Breadcrumb(message: 'irgendein print aus einem Plugin');

      expect(sanitizeSentryBreadcrumb(crumb, Hint()), isNull);
    });

    test('null bleibt null (die Signatur laesst es zu)', () {
      expect(sanitizeSentryBreadcrumb(null, Hint()), isNull);
    });
  });

  group('sanitizeSentryBreadcrumb — was diagnostisch wertvoll bleibt', () {
    test('app.lifecycle bleibt unveraendert (Prozesszustand, konstante Strings)',
        () {
      final crumb = Breadcrumb(
        category: 'app.lifecycle',
        type: 'navigation',
        data: <String, String>{'state': 'resumed'},
      );

      expect(sanitizeSentryBreadcrumb(crumb, Hint()), same(crumb));
    });

    test('device.connectivity bleibt — wifi/cellular/none ist Geraetezustand',
        () {
      final crumb = Breadcrumb(
        category: 'device.connectivity',
        type: 'connectivity',
        data: <String, String>{'connectivity': 'cellular'},
      );

      expect(sanitizeSentryBreadcrumb(crumb, Hint()), same(crumb));
    });

    test('device.screen und device.event bleiben (Groesse, Helligkeit, Locale)',
        () {
      for (final kategorie in <String>['device.screen', 'device.event']) {
        final crumb = Breadcrumb(category: kategorie, message: 'x');
        expect(sanitizeSentryBreadcrumb(crumb, Hint()), same(crumb),
            reason: '$kategorie ist reiner Geraetezustand');
      }
    });

    test('ui.lifecycle bleibt — auf Flutter ist das immer dieselbe Activity',
        () {
      final crumb = Breadcrumb(
        category: 'ui.lifecycle',
        data: <String, String>{'screen': 'MainActivity', 'state': 'started'},
      );

      expect(sanitizeSentryBreadcrumb(crumb, Hint()), same(crumb));
    });

    test('die eigene Kategorie ueberlebt den eigenen Filter', () {
      // Sonst haette der Filter die einzige bewusst gepflegte Kontextspur der
      // App (home_store.dart:306, home_store_sync.dart:194) mit erschlagen.
      final crumb = CrashReporter.buildBreadcrumb('outbox-cap: 3 ops dropped');

      expect(crumb.category, CrashReporter.breadcrumbCategory);
      expect(sanitizeSentryBreadcrumb(crumb, Hint()), same(crumb));
    });
  });

  group('sanitizeSentryBreadcrumb — Kategorien, die Nutzerdaten tragen', () {
    test(
        'navigation wird verworfen: eine Route wie /meal/<uuid> waere eine '
        'Nutzerkennung', () {
      final crumb = Breadcrumb(
        category: 'navigation',
        type: 'navigation',
        data: <String, String>{
          'state': 'didPush',
          'from': '/food',
          'to': '/meal/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
        },
      );

      expect(sanitizeSentryBreadcrumb(crumb, Hint()), isNull);
    });

    test('ui.click wird verworfen: das Label traegt angezeigten Nutzertext',
        () {
      final crumb = Breadcrumb.userInteraction(
        subCategory: 'click',
        viewId: 'meal_tile',
        message: 'Haferflocken mit Banane, 412 kcal',
      );

      expect(crumb.category, 'ui.click');
      expect(sanitizeSentryBreadcrumb(crumb, Hint()), isNull);
    });
  });

  group('sanitizeSentryBreadcrumb — http wird gekuerzt statt verworfen', () {
    test(
        'die PostgREST-URL traegt die User-UUID im Filter und wird auf '
        'scheme://host reduziert', () {
      final crumb = Breadcrumb.http(
        url: Uri.parse('https://abcdefg.supabase.co/rest/v1/weight_entries'
            '?user_id=eq.0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0&select=*'),
        method: 'GET',
        statusCode: 403,
        reason: 'permission denied for table weight_entries (user max@ex.com)',
      );

      final gefiltert = sanitizeSentryBreadcrumb(crumb, Hint())!;
      final data = gefiltert.data!;

      expect(data['url'], 'https://abcdefg.supabase.co');
      expect(data.containsKey('reason'), isFalse,
          reason: 'reason ist die rohe Server-Antwort');
      expect(data['method'], 'GET',
          reason: 'Methode und Status sind die eigentliche Diagnose');
      expect(data['status_code'], 403);
    });

    test('auch der Storage-Pfad meal-images/<uuid>/... faellt weg', () {
      final crumb = Breadcrumb.http(
        url: Uri.parse('https://abcdefg.supabase.co/storage/v1/object/'
            'meal-images/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0/2026-08-08.jpg'),
        method: 'POST',
        statusCode: 413,
      );

      final data = sanitizeSentryBreadcrumb(crumb, Hint())!.data!;
      expect(data['url'], 'https://abcdefg.supabase.co');
      expect(data['url'], isNot(contains('0f1e2d3c')));
      expect(data['url'], isNot(contains('meal-images')));
    });

    test('eine unparsbare URL faellt auf den Typnamen zurueck, nie auf roh',
        () {
      final crumb = Breadcrumb(
        category: 'http',
        type: 'http',
        data: <String, dynamic>{'url': 'max@example.com hat 87,4 kg', 'x': 1},
      );

      final data = sanitizeSentryBreadcrumb(crumb, Hint())!.data!;
      expect(data['url'], isNot(contains('max@example.com')));
      expect(data.containsKey('x'), isFalse,
          reason: 'auch in http gilt Allowlist, nicht Blocklist');
    });

    test('http ohne data ueberlebt ohne Absturz', () {
      final crumb = Breadcrumb(category: 'http', type: 'http');
      expect(sanitizeSentryBreadcrumb(crumb, Hint()), isNotNull);
    });
  });

  group('sanitizeSentryBreadcrumb — Robustheit', () {
    test('der Filter wirft nie, sondern verwirft im Zweifel', () {
      // beforeBreadcrumb laeuft in `Scope._addBreadCrumbSync`; ein Throw dort
      // wird zwar gefangen, laesst den Breadcrumb aber DURCH
      // (scope.dart:228-238 loggt nur). Zumachen muss also hier passieren.
      final crumb = Breadcrumb(
        category: 'http',
        data: <String, dynamic>{'url': Object()},
      );

      expect(() => sanitizeSentryBreadcrumb(crumb, Hint()), returnsNormally);
    });
  });
}
