// Wire-Test fuer den OpenFoodFacts-Service (docs/REVIEW-2026-08-08.md, G2).
//
// WARUM DIESE DATEI ANDERS IST ALS DIE ANDEREN SERVICE-TESTS
//
// Der Review zeigt, dass eine Ein-Token-Aenderung an
// `open_food_facts_product_service.dart` (`result['id'] != 'product_found'`
// statt `==`) den Barcode-Scan app-weit abschaltet, ohne dass eine der 442
// Tests rot wird: die HTTP-/JSON-Grenze war durch Fakes ersetzt, die aus
// demselben Denkmodell wie der Code stammen. Niemand hat je die
// tatsaechlichen Bytes gegen den Parser gehalten.
//
// Deshalb hier:
//   * Die Antworten liegen als **Datei** neben diesem Test
//     (open_food_facts_v3_*.json, open_food_facts_search_pl.json) und werden
//     BYTEWEISE ueber einen echten Loopback-HttpServer ausgeliefert. Kein
//     Dart-Map-Literal, keine Abkuerzung am jsonDecode vorbei.
//   * Der Test faehrt die echte Kette: dart:io-HttpClient -> utf8-Decoder ->
//     jsonDecode -> `result.id`-Auswertung -> _normalizeProduct ->
//     MealAnalysisResult.fromOpenFoodFacts -> Plausibilitaetsfilter.
//   * Zusaetzlich wird die abgeschickte **Anfrage** geprueft (fields=...),
//     denn ein fehlendes Feld ist genau die Luecke aus B7.
//
// HERKUNFT DER FIXTURES: aus der OpenFoodFacts-API-Dokumentation
// (openfoodfacts.github.io/openfoodfacts-server/api/, Kapitel "Read a
// product / v3") nachgebaut — Umschlag (`code`/`errors`/`product`/`result`/
// `status`/`warnings`), die `result.id`-Werte `product_found` und
// `product_not_found`, die 404-mit-JSON-Semantik von v3 und das
// `nutriments`-Namensschema (`energy-kcal_100g`, `energy_100g`,
// `energy-kj_100g`, `energy-kcal_value`, `nutrition_data_per`). Die
// Nutzlasten sind reale Produkte in genau diesem Format. Es gab hier kein
// Netz; abgeschrieben wurde die Doku, nicht der Code.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

/// Antwortet auf die beiden OFF-Endpunkte mit den Bytes der Fixture-Dateien
/// und protokolliert dabei jede eingegangene [Uri].
class _OffFixtureServer {
  _OffFixtureServer._(this._server);

  final HttpServer _server;
  final List<Uri> requests = <Uri>[];

  /// Barcode -> Fixture-Datei. Was hier nicht drinsteht, beantwortet der
  /// Server wie OFF: HTTP 404 MIT JSON-Body.
  static const Map<String, String> _barcodeFixtures = <String, String>{
    '3017624010701': 'open_food_facts_v3_found.json',
    '4008400290117': 'open_food_facts_v3_kj_only.json',
    '7622210449283': 'open_food_facts_v3_kcal_field_holds_kj.json',
    '4104420030008': 'open_food_facts_v3_kcal_broken_kj_valid.json',
    '4009233003204': 'open_food_facts_v3_per_serving.json',
    '4260049370019': 'open_food_facts_v3_value_per_100g.json',
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
        // v3-Semantik: nicht gefunden ist 404 MIT gueltigem JSON-Body.
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

/// Rohe Bytes der Fixture-Datei — bewusst nicht dekodiert und nicht neu
/// serialisiert. Was ueber die Leitung geht, ist exakt der Dateiinhalt.
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
    // DAS ist die Wache gegen G2. Wird `result['id'] == 'product_found'` zu
    // `!=` gedreht, faellt `found` auf false und dieser Test wird rot.
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
      'Barcode mit kJ-Zahl im kcal-Feld wird als unplausibel abgelehnt',
      () async {
        // energy-kcal_100g: 2180 ist die kJ-Zahl fuer 521 kcal. Ungebremst
        // wuerden bei serving_quantity 30 "654 statt 156 kcal" geloggt.
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
      // Der Riegel traegt nur energy_100g: 1611 (kJ). Zwei Ausgaenge sind
      // richtig, je nachdem ob W2-02s kJ-Fallback im Modell schon steht:
      //   * ohne kJ-Fallback -> ProductWithoutNutritionException
      //   * mit  kJ-Fallback -> 1611 / 4,184 = 385 kcal, ein normales Ergebnis
      // Falsch ist nur, was heute passiert: ein Ergebnis mit 0 kcal, das
      // MealAnalysisSheet._addToDaily ungebremst ins Tagebuch schreibt.
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

    // Abstimmung mit W2-02 am Gate: das Modell VERWIRFT einen unplausiblen
    // kcal-Wert und holt sich ueber energy-kj_100g einen gueltigen. Mein
    // Filter darf so einen Treffer nicht faelschlich aussortieren — sonst
    // ergaenzt er die Modellseite nicht, sondern hebt sie auf.
    test('verworfener kcal-Wert + gueltiger kJ-Wert bleibt erhalten',
        () async {
      // energy-kcal_100g: 2180 (Datenmuell) UND energy-kj_100g: 2180
      // (gueltig) -> 2180 / 4,184 = 521 kcal/100 g.
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

    // Die beiden folgenden Tests belegen, dass das neu angefragte
    // nutrition_data_per am Ende der Kette tatsaechlich wirkt: dasselbe Feld
    // energy-kcal_value wird einmal akzeptiert und einmal abgelehnt, und der
    // einzige Unterschied ist die Bezugsgroesse.
    test('nutrition_data_per "100g" macht energy-kcal_value benutzbar',
        () async {
      final ergebnis = await service.lookupBarcode('4260049370019');

      expect(ergebnis.kcalPer100G, 372);
      // serving_quantity: 50 -> 372 * 50 / 100 = 186
      expect(ergebnis.caloriesKcal, 186);
    });

    test('nutrition_data_per "serving" verhindert die 3150-kcal-Pizza',
        () async {
      // Genau das Szenario aus B7: pro Portion erfasst, serving_size
      // "1 Pizza" ohne Gramm, energy-kcal_value: 900. Frueher las die App
      // daraus "900 kcal / 100 g" und machte bei 350 g 3150 kcal daraus.
      await expectLater(
        service.lookupBarcode('4009233003204'),
        throwsA(
          isA<ProductWithoutNutritionException>()
              .having((e) => e.isImplausible, 'isImplausible', isFalse)
              .having(
                (e) => e.userMessage,
                'userMessage',
                contains('ohne Nährwertangaben'),
              ),
        ),
      );
    });

    test('Suche filtert unloggbare Treffer aus der echten Antwort', () async {
      final treffer = await service.searchProducts('salami');

      // Die Fixture enthaelt vier Produkte: eine brauchbare Pizza, einen
      // Riegel nur mit kJ, einen Keks mit 2180 im kcal-Feld und einen
      // Datensatz ohne Namen. Verglichen wird ueber den Code, weil der Titel
      // die Marke anhaengt ("… · Dr. Oetker").
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
    // Haelt die Fixtures ehrlich: waeren sie kein gueltiges JSON oder haetten
    // sie den Umschlag nicht, wuerde der Rest dieser Datei etwas anderes
    // testen als "echte OFF-Antwort".
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

/// Fuehrt [aktion] aus und liefert entweder das Ergebnis ODER den Fehler als
/// Wert zurueck — damit beide Ausgaenge mit `anyOf` beschreibbar sind.
Future<Object> _ausgangVon(Future<Object> Function() aktion) async {
  try {
    return await aktion();
  } catch (error) {
    return error;
  }
}
