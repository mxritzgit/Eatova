// C1, leak 1: breadcrumbs — the second, unfiltered route to Sentry, and its
// most dangerous producer installs itself in the RELEASE build:
// `debug_print_integration.dart` routes `debugPrint` into
// `Breadcrumb.console`, and in release `FlutterError.presentError` calls
// `debugPrintStack(label: details.exception.toString())`. That turns the RAW
// `toString()` of every unhandled framework error into a breadcrumb — exactly
// what `sanitizeForReport` holds back on the exception side.
//
// Why a filter and not just `enablePrintBreadcrumbs = false`: breadcrumbs also
// arrive from the native scope and are mirrored back into it, so a native
// crash report leaves without Dart's `beforeSend`. `beforeBreadcrumb` runs
// before the scope observers and is the only place catching both directions.

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('sanitizeSentryBreadcrumb — console (der Release-Kanal)', () {
    test(
        'ein console-Breadcrumb aus einem unbehandelten ArgumentError traegt '
        'den getippten Gewichtswert und wird deshalb komplett verworfen', () {
      // Exactly what `debugPrintStack(label: exception.toString())` produces
      // when the user types 187.4 instead of 87.4 kg.
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
      // Default branch: unknown origin -> dropped. Allowlist, not blocklist.
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
      // Otherwise the filter would kill the app's only deliberately
      // maintained context trail.
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

    test('die native Request-Zeile in `message` faellt weg — sie ist die URL '
        'noch einmal', () {
      // Only `data` was ever inspected. Under native instrumentation the whole
      // request line sits in the free-text `message`, which travels around the
      // data allowlist untouched: dropping that one line changed nothing here.
      final crumb = Breadcrumb(
        category: 'http',
        type: 'http',
        message: 'GET https://abcdefg.supabase.co/rest/v1/logged_meals'
            '?user_id=eq.0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0 [200]',
        data: <String, dynamic>{
          'url': 'https://abcdefg.supabase.co/rest/v1/logged_meals'
              '?user_id=eq.0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
          'method': 'GET',
        },
      );

      final gefiltert = sanitizeSentryBreadcrumb(crumb, Hint())!;
      expect(gefiltert.message, isNull);
      expect(gefiltert.data!['url'], 'https://abcdefg.supabase.co');
      expect(gefiltert.data!['method'], 'GET');
    });

    test('http ohne data ueberlebt ohne Absturz', () {
      final crumb = Breadcrumb(category: 'http', type: 'http');
      final gefiltert = sanitizeSentryBreadcrumb(crumb, Hint());
      expect(gefiltert, isNotNull);
      expect(gefiltert!.message, isNull,
          reason: 'auch ohne data darf die Request-Zeile nicht stehenbleiben');
    });
  });

  group('sanitizeSentryBreadcrumb — Robustheit', () {
    test('der Filter wirft nie, sondern verwirft im Zweifel', () {
      // A throw inside beforeBreadcrumb is caught by the scope but lets the
      // breadcrumb THROUGH, so the closing must happen here.
      final crumb = Breadcrumb(
        category: 'http',
        data: <String, dynamic>{'url': Object()},
      );

      expect(() => sanitizeSentryBreadcrumb(crumb, Hint()), returnsNormally);
    });
  });
}
