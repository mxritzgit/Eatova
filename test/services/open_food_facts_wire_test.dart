// Wire test for the OpenFoodFacts service (docs/REVIEW-2026-08-08.md, G2).
//
// Why this file differs from the other service tests: a one-token change in
// `open_food_facts_product_service.dart` (`result['id'] != 'product_found'`)
// disabled barcode scanning app-wide without turning a single test red — the
// HTTP/JSON boundary was replaced by fakes built from the same mental model as
// the code.
//
// So here:
//   * responses live as FILES next to this test and are served BYTE-WISE over a
//     real loopback HttpServer — no Dart map literal, no shortcut past
//     jsonDecode.
//   * the test drives the real chain: HttpClient -> utf8 -> jsonDecode ->
//     `result.id` -> _normalizeProduct -> MealAnalysisResult.fromOpenFoodFacts
//     -> plausibility filter.
//   * the outgoing REQUEST is checked too (fields=...), since a missing field
//     is exactly the B7 gap.
//
// FIXTURE ORIGIN: rebuilt from the OpenFoodFacts API docs (envelope, the
// `result.id` values, v3's 404-with-JSON semantics and the `nutriments` naming
// scheme). Payloads are real products in that format; the docs were copied, not
// the code.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

/// Answers both OFF endpoints with the fixture files' bytes and records every
/// incoming [Uri].
class _OffFixtureServer {
  _OffFixtureServer._(this._server);

  final HttpServer _server;
  final List<Uri> requests = <Uri>[];

  /// Barcode -> fixture file. Anything not listed is answered the way OFF does:
  /// HTTP 404 WITH a JSON body.
  static const Map<String, String> _barcodeFixtures = <String, String>{
    '3017624010701': 'open_food_facts_v3_found.json',
    '4008400290117': 'open_food_facts_v3_kj_only.json',
    '7622210449283': 'open_food_facts_v3_kcal_field_holds_kj.json',
    '4104420030008': 'open_food_facts_v3_kcal_broken_kj_valid.json',
    '4009233003204': 'open_food_facts_v3_per_serving.json',
    '4260049370019': 'open_food_facts_v3_value_per_100g.json',
    '3057640257773': 'open_food_facts_v3_zero_kcal.json',
  };

  int get port => _server.port;

  String get productBaseUrl => 'http://127.0.0.1:$port/api/v3/product';
  List<String> get searchBaseUrls => <String>[
    'http://127.0.0.1:$port/cgi/search.pl',
  ];

  static Future<_OffFixtureServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixtureServer = _OffFixtureServer._(server);
    server.listen(fixtureServer._handle);
    return fixtureServer;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri);
    final pfad = request.uri.path;

    if (pfad.endsWith('/cgi/search.pl')) {
      await _sende(request, 200, 'open_food_facts_search_pl.json');
      return;
    }

    if (pfad.endsWith('.json')) {
      final barcode = pfad.split('/').last.replaceAll('.json', '');
      final fixture = _barcodeFixtures[barcode];
      if (fixture == null) {
        // v3 semantics: not found is 404 WITH a valid JSON body.
        await _sende(request, 404, 'open_food_facts_v3_not_found.json');
      } else {
        await _sende(request, 200, fixture);
      }
      return;
    }

    request.response.statusCode = 500;
    await request.response.close();
  }

  Future<void> _sende(HttpRequest request, int status, String fixture) async {
    final bytes = fixtureBytes(fixture);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..add(bytes);
    await request.response.close();
  }
}

/// Raw bytes of the fixture file — deliberately not decoded and not
/// re-serialised: what goes over the wire is exactly the file content.
List<int> fixtureBytes(String name) {
  final datei = File('test/services/$name');
  if (!datei.existsSync()) {
    fail(
      'Fixture $name fehlt (erwartet unter test/services/$name, '
      'aufgeloest von ${Directory.current.path}).',
    );
  }
  return datei.readAsBytesSync();
}

void main() {
  late _OffFixtureServer server;
  late OpenFoodFactsProductService service;

  setUp(() async {
    server = await _OffFixtureServer.start();
    service = OpenFoodFactsProductService(
      productBaseUrl: server.productBaseUrl,
      searchBaseUrls: server.searchBaseUrls,
    );
  });

  tearDown(() => server.close());

  group('Barcode-Pfad gegen echte v3-Bytes', () {
    // THIS is the guard against G2: flipping `result['id'] == 'product_found'`
    // to `!=` drops `found` to false and turns this test red.
    test('gefundenes Produkt wird vollstaendig geparst', () async {
      final ergebnis = await service.lookupBarcode('3017624010701');

      expect(ergebnis.mealName, 'Nutella · Ferrero');
      expect(ergebnis.brand, 'Ferrero');
      expect(ergebnis.barcode, '3017624010701');
      expect(ergebnis.kcalPer100G, 539);
      // serving_quantity: 15 -> 539 * 15 / 100 = 80,85 -> 81
      expect(ergebnis.estimatedGrams, 15);
      expect(ergebnis.caloriesKcal, 81);
      expect(ergebnis.sourceLabel, 'OpenFoodFacts');
      // The macros are the other three numbers the diary shows, and nothing
      // else asserted them for the OFF path: swapping protein and fat in
      // `fromOpenFoodFacts` AND dropping the portion scaling left the whole
      // suite green. Exact strings, because the format IS the assurance —
      // portion value (not per 100 g), one decimal, German comma, unit "g".
      //   proteins_100g      6,3 * 15/100 = 0,945 -> "0,9 g"
      //   carbohydrates_100g 57,5 * 15/100 = 8,625 -> "8,6 g"
      //   fat_100g           30,9 * 15/100 = 4,635 -> "4,6 g"
      expect(ergebnis.protein, '0,9 g');
      expect(ergebnis.carbs, '8,6 g');
      expect(ergebnis.fat, '4,6 g');
    });

    test('unbekannter Barcode (404 mit JSON) wirft ProductNotFoundException',
        () async {
      await expectLater(
        service.lookupBarcode('0000000000000'),
        throwsA(isA<ProductNotFoundException>()),
      );
    });

    test('kaputter Body (kein JSON) wirft weiterhin HttpException', () async {
      final kaputt = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => kaputt.close(force: true));
      kaputt.listen((request) async {
        request.response
          ..statusCode = 502
          ..write('<html>Bad Gateway</html>');
        await request.response.close();
      });

      final svc = OpenFoodFactsProductService(
        productBaseUrl: 'http://127.0.0.1:${kaputt.port}/api/v3/product',
        searchBaseUrls: server.searchBaseUrls,
      );

      await expectLater(
        svc.lookupBarcode('3017624010701'),
        throwsA(isA<HttpException>()),
      );
    });
  });

  group('B7 — Bezugsgroesse, kJ und Obergrenze', () {
    test('_fields fragt nutrition_data_per an (Barcode-Pfad)', () async {
      await service.lookupBarcode('3017624010701');

      final fields = server.requests.single.queryParameters['fields'];
      expect(fields, isNotNull);
      expect(
        fields!.split(','),
        contains('nutrition_data_per'),
        reason:
            'Ohne nutrition_data_per kann die App die Bezugsgroesse von '
            'energy-kcal_value prinzipiell nicht kennen (B7).',
      );
    });

    test('_fields fragt nutrition_data_per an (Suchpfad)', () async {
      await service.searchProducts('salami');

      final fields = server.requests.single.queryParameters['fields'];
      expect(fields, isNotNull);
      expect(fields!.split(','), contains('nutrition_data_per'));
    });

    test(
      'explizite 0 kcal (Wasser) sind loggbar — die 0 heisst hier '
      '"gemessen 0", nicht "unbekannt"', () async {
      final ergebnis = await service.lookupBarcode('3057640257773');

      expect(ergebnis.mealName, contains('Volvic'));
      expect(ergebnis.kcalPer100G, 0);
      expect(ergebnis.caloriesKcal, 0);
      expect(ergebnis.estimatedGrams, 250,
          reason: 'serving_quantity 250 ml — Wasser wird als Portion geloggt');
    });

    test(
      'Barcode mit kJ-Zahl im kcal-Feld wird als unplausibel abgelehnt',
      () async {
        // energy-kcal_100g: 2180 is the kJ figure for 521 kcal. Unchecked,
        // serving_quantity 30 would log 654 instead of 156 kcal.
        await expectLater(
          service.lookupBarcode('7622210449283'),
          throwsA(
            isA<ProductWithoutNutritionException>()
                .having((e) => e.isImplausible, 'isImplausible', isTrue)
                .having((e) => e.barcode, 'barcode', '7622210449283'),
          ),
        );
      },
    );

    test('Barcode ohne kcal-Feld liefert nie ein 0-kcal-Ergebnis', () async {
      // The bar carries only energy_100g: 1611 (kJ). Two outcomes are correct,
      // depending on whether the model's kJ fallback is in place:
      //   * without it -> ProductWithoutNutritionException
      //   * with it    -> 1611 / 4.184 = 385 kcal, a normal result
      // Only a 0-kcal result would be wrong: it lands straight in the diary.
      final ausgang = await _ausgangVon(
        () => service.lookupBarcode('4008400290117'),
      );

      expect(
        ausgang,
        anyOf(
          isA<ProductWithoutNutritionException>()
              .having((e) => e.isImplausible, 'isImplausible', isFalse),
          isA<MealAnalysisResult>().having(
            (r) => isLoggableKcalPer100G(r.kcalPer100G),
            'kcalPer100G ist loggbar',
            isTrue,
          ),
        ),
      );
    });

    // The model DISCARDS an implausible kcal value and derives a valid one from
    // energy-kj_100g. The filter must not drop such a hit, or it would cancel
    // the model side instead of complementing it.
    test('verworfener kcal-Wert + gueltiger kJ-Wert bleibt erhalten',
        () async {
      // energy-kcal_100g: 2180 (garbage) AND energy-kj_100g: 2180 (valid)
      // -> 2180 / 4.184 = 521 kcal/100 g.
      final ergebnis = await service.lookupBarcode('4104420030008');

      expect(ergebnis.kcalPer100G, closeTo(521, 1));
      expect(isLoggableKcalPer100G(ergebnis.kcalPer100G), isTrue);
      // serving_quantity: 20 -> 521 * 20 / 100 = 104
      expect(ergebnis.caloriesKcal, closeTo(104, 1));
    });

    test('Suchtreffer mit kJ-Rettung ueberlebt den Filter', () async {
      final treffer = await service.searchProducts('salami');

      expect(
        treffer.map((t) => t.code),
        contains('4104420030008'),
        reason:
            'Der kcal-Wert ist Muell, der kJ-Wert ist gueltig — der Treffer '
            'ist loggbar und gehoert in die Liste.',
      );
    });

    // The next two tests show nutrition_data_per actually takes effect: the same
    // energy-kcal_value field is accepted once and rejected once, and the only
    // difference is the reference size.
    test('nutrition_data_per "100g" macht energy-kcal_value benutzbar',
        () async {
      final ergebnis = await service.lookupBarcode('4260049370019');

      expect(ergebnis.kcalPer100G, 372);
      // serving_quantity: 50 -> 372 * 50 / 100 = 186
      expect(ergebnis.caloriesKcal, 186);
    });

    test('nutrition_data_per "serving" verhindert die 3150-kcal-Pizza',
        () async {
      // The B7 scenario: per-serving data, serving_size "1 Pizza" without
      // grams, energy-kcal_value: 900. The app used to read that as 900 kcal
      // per 100 g and turn 350 g into 3150 kcal.
      await expectLater(
        service.lookupBarcode('4009233003204'),
        throwsA(
          isA<ProductWithoutNutritionException>()
              .having((e) => e.isImplausible, 'isImplausible', isFalse)
              .having(
                (e) => e.userMessage(),
                'userMessage',
                contains('ohne Nährwertangaben'),
              ),
        ),
      );
    });

    test('Suche filtert unloggbare Treffer aus der echten Antwort', () async {
      final treffer = await service.searchProducts('salami');

      // The fixture holds four products: a usable pizza, a bar with kJ only, a
      // biscuit with 2180 in the kcal field and a record without a name.
      // Compared by code, because the title appends the brand.
      final codes = treffer.map((t) => t.code).toList();
      expect(codes, contains('4001724819608'), reason: 'die brauchbare Pizza');
      expect(
        codes,
        isNot(contains('7622210449283')),
        reason: '2180 kcal/100 g sind physikalisch unmoeglich (B7).',
      );
      expect(
        codes,
        isNot(contains('20221126')),
        reason: 'Datensatz ohne Produktnamen',
      );
      for (final t in treffer) {
        expect(
          isLoggableKcalPer100G(t.kcalPer100G),
          isTrue,
          reason: '"${t.title}" traegt ${t.kcalPer100G} kcal/100 g.',
        );
      }
    });
  });

  group('Fixtures sind gueltige OFF-Antworten', () {
    // Keeps the fixtures honest: without valid JSON and the envelope, the rest
    // of this file would test something other than a real OFF response.
    test('v3-Umschlag traegt code, result.id, status', () {
      for (final name in const <String>[
        'open_food_facts_v3_found.json',
        'open_food_facts_v3_kj_only.json',
        'open_food_facts_v3_kcal_field_holds_kj.json',
        'open_food_facts_v3_not_found.json',
      ]) {
        final json =
            jsonDecode(utf8.decode(fixtureBytes(name))) as Map<String, dynamic>;
        expect(json.keys, containsAll(<String>['code', 'result', 'status']));
        expect((json['result'] as Map)['id'], isA<String>());
      }
    });

    test('search.pl-Umschlag traegt products/count/page_size', () {
      final json = jsonDecode(
        utf8.decode(fixtureBytes('open_food_facts_search_pl.json')),
      ) as Map<String, dynamic>;
      expect(
        json.keys,
        containsAll(<String>['count', 'page', 'page_size', 'products']),
      );
      expect(json['products'], isA<List>());
    });
  });
}

/// Runs [aktion] and returns either the result OR the error as a value, so both
/// outcomes can be described with `anyOf`.
Future<Object> _ausgangVon(Future<Object> Function() aktion) async {
  try {
    return await aktion();
  } catch (error) {
    return error;
  }
}
