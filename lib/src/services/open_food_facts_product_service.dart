import 'dart:convert';
import 'dart:io';

import '../models/meal_analysis_result.dart';
import '../models/model_limits.dart';
import 'eatova_http.dart';

abstract class ProductLookupService {
  Future<MealAnalysisResult> lookupBarcode(String barcode);
  Future<List<ProductSearchResult>> searchProducts(String query);
}

/// Der EINE Energie-Filter fuer alle Produktquellen: Suche, Barcode, Mirror.
///
/// Bisher stand `> 0` genau an einer Stelle (dem OFF-Suchpfad). Der
/// Barcode-Pfad und der Meilisearch-Pfad hatten gar nichts, und eine
/// Obergrenze gab es nirgends — beides zusammen ergab die zwei Faelle aus
/// docs/REVIEW-2026-08-08.md B7:
///
///  * Riegel mit nur `energy_100g: 1611` (kJ) -> `kcalPer100G = 0` -> als
///    **0-kcal-Eintrag** im Tagebuch, real ~385 kcal.
///  * Keks mit `energy-kcal_100g: 2180` (die kJ-Zahl fuer 521 kcal) ->
///    ueberlebt, rankt normal, loggt bei 30 g Portion **654 statt 156 kcal**.
///
/// `> 0` und die 900er-Grenze muessen beide hier stehen:
/// [isPlausibleKcalPer100G] laesst 0 durch (`kcalPer100GMin` ist 0), und
/// `> 0` allein laesst 2180 durch.
bool isLoggableKcalPer100G(num kcalPer100G) =>
    kcalPer100G > 0 && isPlausibleKcalPer100G(kcalPer100G);

class ProductSearchResult {
  const ProductSearchResult({
    required this.code,
    required this.title,
    required this.subtitle,
    required this.kcalPer100G,
    required this.result,
    this.imageUrl,
  });

  final String code;
  final String title;
  final String subtitle;
  final double kcalPer100G;
  final MealAnalysisResult result;
  final String? imageUrl;

  factory ProductSearchResult.fromOpenFoodFacts(Map<String, dynamic> product) {
    final code = product['code']?.toString().trim() ?? '';
    final result = MealAnalysisResult.fromOpenFoodFacts(product, code);
    final brand = result.brand?.trim();
    final quantity = _firstNonEmptyString(product, const ['quantity']);
    final imageUrl = _firstNonEmptyString(product, const [
      'image_front_small_url',
      'image_front_url',
      'image_small_url',
      'image_url',
    ]);
    final subtitleParts = <String>[
      if (brand != null && brand.isNotEmpty) brand,
      if (quantity != null && quantity.isNotEmpty) quantity,
      result.kcalPer100Label,
    ];

    return ProductSearchResult(
      code: code,
      title: result.mealName,
      subtitle: subtitleParts.join(' · '),
      kcalPer100G: result.kcalPer100G,
      result: result,
      imageUrl: imageUrl,
    );
  }
}

/// Direkter OpenFoodFacts-Zugriff — seit dem GCP-Aus (2026-08-03) der einzige
/// Such-/Lookup-Pfad (der Cloud-Run-Mirror ist komplett entfernt).
///
///  * Barcode: Kern-API **v3** (`/api/v3/product/{code}.json`). v2 ist laut
///    Doku deprecated. v3 antwortet bei unbekanntem Barcode mit HTTP 404 UND
///    einem JSON-Body — massgeblich ist `result.id == "product_found"`.
///  * Textsuche: BEWUSST das klassische `cgi/search.pl` (de -> world
///    Fallback). Der Versuch, auf Search-a-licious umzustellen (2026-08-03),
///    wurde zurueckgedreht: SaL matcht Mehrwort-Queries als ODER
///    (im ES-Debug verifiziert; ein AND in `q` wird vom Parser geschluckt),
///    wodurch bei Eingaben wie "Pizza Salami dr" Karteileichen ohne
///    Naehrwerte und fremdsprachige Treffer vor den erwarteten Produkten
///    ranken. search.pl macht Wort-UND + Popularitaets-Ranking und liefert
///    im direkten Vergleich exakt die erwarteten Treffer. Deprecated fuer
///    Neu-Integrationen, aber offiziell in Betrieb — bei Abschaltung muss
///    SaL mit client-seitigem Re-Ranking nachgebaut werden.
///
/// Beide Pfade normalisieren die Produkt-Map vor dem Parser:
/// `product_name_de` gewinnt ueber `product_name`, und ein `brands`-Array
/// wird auf einen String vereinheitlicht — der unit-getestete Parser bleibt
/// unangetastet.
///
/// **Energie-Ausgaenge (B7).** Beide Pfade pruefen dieselbe Bedingung
/// ([_energieProblem]), reagieren aber verschieden:
///  * **Suche** filtert still weg. Ein Treffer weniger in einer Liste faellt
///    niemandem auf.
///  * **Barcode** wirft [ProductWithoutNutritionException] statt
///    [ProductNotFoundException]. Der Nutzer hat ein konkretes Produkt
///    gescannt; "nicht gefunden" waere fuer etwas, das existiert, die falsche
///    Auskunft. Der Ausnahmetyp traegt Produktname und gemessenen Wert, damit
///    die Oberflaeche "gefunden, aber ohne Naehrwerte — bitte manuell
///    eintragen" sagen kann.
class OpenFoodFactsProductService implements ProductLookupService {
  /// [productBaseUrl] und [searchBaseUrls] sind ausschliesslich eine
  /// **Testnaht**: sie zeigen produktiv immer auf OpenFoodFacts. Sie
  /// existieren, damit der Wire-Test in
  /// `test/services/open_food_facts_wire_test.dart` die echte Parse- und
  /// Filterkette gegen echte Antwort-Bytes eines lokalen Loopback-Servers
  /// fahren kann, statt gegen ein handgebautes Fake-Objekt
  /// (docs/REVIEW-2026-08-08.md, G2).
  const OpenFoodFactsProductService({
    this.productBaseUrl = defaultProductBaseUrl,
    this.searchBaseUrls = defaultSearchBaseUrls,
  });

  static const String defaultProductBaseUrl =
      'https://world.openfoodfacts.org/api/v3/product';
  static const List<String> defaultSearchBaseUrls = <String>[
    'https://de.openfoodfacts.org/cgi/search.pl',
    'https://world.openfoodfacts.org/cgi/search.pl',
  ];

  final String productBaseUrl;
  final List<String> searchBaseUrls;

  /// `nutrition_data_per` ist seit REVIEW-2026-08-08 (B7) dabei und der Grund
  /// steht dort: die Parse-Kette im Modell greift auf `energy-kcal_value`
  /// zurueck, und dieses Feld ist in OFF **basisabhaengig** — je nach
  /// `nutrition_data_per` gilt es pro 100 g ODER pro Portion. Ohne das Feld
  /// kann die App die Bezugsgroesse prinzipiell nicht kennen; eine pro Portion
  /// erfasste Tiefkuehlpizza (`energy-kcal_value: 900`) wurde deshalb als
  /// "900 kcal / 100 g" gelesen und bei 350 g auf 3150 kcal hochgerechnet.
  ///
  /// Die kJ-Felder (`energy_100g`, `energy-kj_100g`) muessen hier NICHT
  /// stehen: sie liegen innerhalb von `nutriments`, und `fields=nutriments`
  /// liefert die Gruppe vollstaendig.
  static const String _fields =
      'code,product_name,product_name_de,generic_name,brands,quantity,'
      'serving_size,serving_quantity,nutrition_data_per,nutriments,'
      'image_front_small_url,image_front_url,image_small_url,image_url';

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    final cleanBarcode = barcode.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanBarcode.isEmpty) {
      throw const FormatException('Empty barcode.');
    }

    final client = createHttpClient(HttpTimeoutPolicy.openFoodFacts);
    try {
      final uri = Uri.parse(
        '$productBaseUrl/$cleanBarcode.json?fields=$_fields',
      );
      final response = await sendTextRequest(
        client,
        method: 'GET',
        uri: uri,
        policy: HttpTimeoutPolicy.openFoodFacts,
        operation: 'off.lookupBarcode',
        configure: _setUserAgent,
      );

      // v3 liefert "nicht gefunden" als 404 MIT JSON-Body — erst parsen,
      // dann entscheiden. Nur echte Transportfehler (5xx, kein JSON) werfen
      // eine HttpException.
      final Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        throw HttpException(
          'OpenFoodFacts lookup failed: ${response.statusCode}',
        );
      }

      final result = decoded['result'];
      final found =
          result is Map<String, dynamic> &&
          result['id'] == 'product_found' &&
          decoded['product'] is Map<String, dynamic>;
      if (!found) {
        throw ProductNotFoundException(cleanBarcode);
      }

      final product = _normalizeProduct(
        decoded['product'] as Map<String, dynamic>,
      );
      final analyse = MealAnalysisResult.fromOpenFoodFacts(
        product,
        cleanBarcode,
      );

      // Beim Barcode wird NICHT stillschweigend weggefiltert wie in der
      // Suche: der Nutzer hat ein konkretes Produkt in der Hand, "nicht
      // gefunden" waere die falsche Antwort. Stattdessen ein eigener,
      // benannter Ausgang mit Produktname und gemessenem Wert.
      final problem = _energieProblem(product, analyse, cleanBarcode);
      if (problem != null) {
        throw problem;
      }

      return analyse;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.length < 2) {
      return const <ProductSearchResult>[];
    }

    final client = createHttpClient(HttpTimeoutPolicy.openFoodFacts);
    try {
      Object? lastError;

      for (final baseUrl in searchBaseUrls) {
        try {
          final results = await _searchProductsFromEndpoint(
            client: client,
            baseUrl: baseUrl,
            query: cleanQuery,
          );
          if (results.isNotEmpty) {
            return results;
          }
        } catch (error) {
          lastError = error;
        }
      }

      if (lastError != null) {
        throw lastError;
      }

      return const <ProductSearchResult>[];
    } finally {
      client.close(force: true);
    }
  }

  Future<List<ProductSearchResult>> _searchProductsFromEndpoint({
    required HttpClient client,
    required String baseUrl,
    required String query,
  }) async {
    final uri = Uri.parse(baseUrl).replace(
      queryParameters: <String, String>{
        'search_terms': query,
        'search_simple': '1',
        'action': 'process',
        'json': '1',
        'page_size': '16',
        'fields': _fields,
      },
    );
    final response = await sendTextRequest(
      client,
      method: 'GET',
      uri: uri,
      policy: HttpTimeoutPolicy.openFoodFacts,
      operation: 'off.searchProducts',
      configure: _setUserAgent,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'OpenFoodFacts search failed: ${response.statusCode}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final products = decoded['products'];
    if (products is! List) {
      return const <ProductSearchResult>[];
    }

    // Bewusst eine Schleife statt einer map/where-Kette: der
    // Plausibilitaetsfilter braucht neben dem geparsten Treffer auch die
    // ROHE Produkt-Map (siehe _energieProblem), und die faellt in einer
    // .map(...).where(...)-Kette hinter dem Parser herunter.
    final treffer = <ProductSearchResult>[];
    for (final roh in products.whereType<Map>()) {
      final product = _normalizeProduct(
        roh.map((key, value) => MapEntry(key.toString(), value)),
      );
      final hit = ProductSearchResult.fromOpenFoodFacts(product);
      if (hit.title.trim().isEmpty) {
        continue;
      }
      // Kalorien-Tracker: Eintraege ohne (oder mit unmoeglicher) Energie sind
      // nicht loggbar und wuerden als "0 kcal"- bzw. "2180 kcal"-Karteileichen
      // die Liste verstopfen. Beim SUCHEN ist Wegfiltern richtig — ein Treffer
      // weniger faellt niemandem auf, ein falsch geloggter Keks schon.
      if (_energieProblem(product, hit.result, hit.code) != null) {
        continue;
      }
      treffer.add(hit);
    }
    return List<ProductSearchResult>.unmodifiable(treffer);
  }

  /// Rohe kcal/100-g-Angabe direkt aus dem OFF-Datensatz.
  ///
  /// Bewusst **unabhaengig** von [MealAnalysisResult.fromOpenFoodFacts]:
  /// wuerde das Modell einen unmoeglichen Wert klemmen statt ihn abzulehnen
  /// (2180 -> 900), waere die Obergrenze hier sonst wirkungslos und der Nutzer
  /// loggte 900 kcal/100 g fuer einen Keks. Doppelt geprueft ist hier besser
  /// als gar nicht (docs/REVIEW-2026-08-08.md, B7).
  ///
  /// `energy-kcal_value` steht mit Absicht NICHT in dieser Liste: es ist
  /// basisabhaengig (siehe [_fields]) und taugt ohne `nutrition_data_per`
  /// nicht als Per-100-g-Wert.
  static double? _rawKcalPer100G(Map<String, dynamic> product) {
    final nutriments = product['nutriments'];
    if (nutriments is! Map) {
      return null;
    }
    for (final key in const ['energy-kcal_100g', 'energy_kcal_100g']) {
      final value = nutriments[key];
      if (value is num && value.isFinite) {
        return value.toDouble();
      }
      if (value is String) {
        final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
        if (parsed != null && parsed.isFinite) {
          return parsed;
        }
      }
    }
    return null;
  }

  /// `null`, wenn die Energieangabe loggbar ist — sonst der passende
  /// [ProductWithoutNutritionException]. Eine Stelle fuer Suche UND Barcode.
  ///
  /// **Reihenfolge ist hier bedeutungstragend** (abgestimmt mit der
  /// Modellseite von B7): der Parser verwirft einen unplausiblen kcal-Wert und
  /// holt sich, falls vorhanden, ueber `energy-kj_100g` / `energy_100g` einen
  /// gueltigen Ersatz. Ein Produkt mit `energy-kcal_100g: 2180` UND
  /// `energy-kj_100g: 2180` hat also am Ende korrekte 521 kcal/100 g. Wuerde
  /// hier stumpf auf den Rohwert geprueft, floege genau dieser gerettete
  /// Treffer raus — der Filter wuerde die Modellseite aufheben statt sie zu
  /// ergaenzen.
  ///
  /// Deshalb entscheidet zuerst das **Ergebnis**. Der Rohwert kommt nur noch
  /// in dem einen Fall zum Zug, fuer den diese Doppelpruefung gebaut ist:
  /// wenn ein unmoeglicher Wert nicht verworfen, sondern **geklemmt** wurde.
  /// Klemmen landet per Definition exakt auf
  /// [PlausibilityLimits.kcalPer100GMax] — der 521er aus dem kJ-Pfad tut das
  /// nicht, der 900er aus einem `clamp` schon.
  static ProductWithoutNutritionException? _energieProblem(
    Map<String, dynamic> product,
    MealAnalysisResult analyse,
    String barcode,
  ) {
    final geparst = analyse.kcalPer100G;
    final roh = _rawKcalPer100G(product);
    final rohUnmoeglich = roh != null && !isPlausibleKcalPer100G(roh);

    if (!isLoggableKcalPer100G(geparst)) {
      return ProductWithoutNutritionException(
        barcode: barcode,
        productName: analyse.mealName,
        // Stand ein unmoeglicher Wert im Datensatz, ist DER die Diagnose
        // ("unplausibel") — nicht die 0, die der Parser daraus gemacht hat.
        kcalPer100G: rohUnmoeglich ? roh : geparst,
      );
    }

    if (rohUnmoeglich && geparst == clampKcalPer100G(roh)) {
      return ProductWithoutNutritionException(
        barcode: barcode,
        productName: analyse.mealName,
        kcalPer100G: roh,
      );
    }

    return null;
  }

  /// Gleicht die Format-Unterschiede zwischen Product-Read (v3) und
  /// Search-a-licious aus, damit der bestehende Parser beide versteht:
  ///  * `product_name_de` (falls befuellt) gewinnt ueber `product_name` —
  ///    deutsche Namen fuer eine deutsche App, statt der Hauptsprache des
  ///    Produkts.
  ///  * `brands` kommt aus Search-a-licious als Array, aus dem Product-Read
  ///    als String -> immer zu einem String gejoint.
  static Map<String, dynamic> _normalizeProduct(Map<String, dynamic> raw) {
    final product = Map<String, dynamic>.of(raw);

    final nameDe = product['product_name_de']?.toString().trim();
    if (nameDe != null && nameDe.isNotEmpty) {
      product['product_name'] = nameDe;
    }

    final brands = product['brands'];
    if (brands is List) {
      final joined = brands
          .map((b) => b.toString().trim())
          .where((b) => b.isNotEmpty)
          .join(', ');
      product['brands'] = joined.isEmpty ? null : joined;
    }

    return product;
  }

  static void _setUserAgent(HttpClientRequest request) {
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Eatova/1.0 (OpenFoodFacts nutrition lookup; mxritzgit/eatova)',
    );
  }
}

/// Der Barcode ist in der befragten Datenquelle nicht vorhanden.
///
/// Bewusst ein eigener Typ statt der frueheren rohen [FormatException]: der
/// [FallbackProductService] muss "kenne ich nicht" (Alltag, still) von
/// "ich verstehe die Antwort nicht mehr" (Formataenderung bei OFF, gehoert
/// gemeldet) unterscheiden koennen. Mit einer nackten `FormatException` fuer
/// beides ist diese Unterscheidung unmoeglich.
class ProductNotFoundException implements Exception {
  const ProductNotFoundException(this.barcode);

  final String barcode;

  @override
  String toString() => 'ProductNotFoundException(barcode: $barcode)';
}

/// Das Produkt **existiert**, traegt aber keine loggbare Energieangabe:
/// entweder fehlt sie ganz (nur kJ, das der Parser nicht kennt -> 0 kcal)
/// oder sie ist physikalisch unmoeglich (> 900 kcal/100 g, praktisch immer
/// eine kJ-Zahl im kcal-Feld).
///
/// **Warum werfen und nicht einfach zurueckgeben?** Ein 0-kcal-Ergebnis
/// landete bis hierher ungebremst im Tagebuch: `MealAnalysisSheet._addToDaily`
/// ruft `onAdd` bedingungslos, und [MealAnalysisResult] hat kein Feld, in dem
/// "ohne Naehrwerte" ueberhaupt transportierbar waere. Ein stiller
/// 0-kcal-Eintrag ist der teurere Fehler.
///
/// **Warum nicht [ProductNotFoundException]?** Beim Barcode hat der Nutzer ein
/// konkretes Produkt in der Hand; "nicht gefunden" waere gelogen. Dieser Typ
/// traegt deshalb Name und gemessenen Wert mit, damit die Oberflaeche
/// "gefunden, aber ohne Naehrwerte — bitte manuell eintragen" sagen kann,
/// ohne ein zweites Mal nachzuschlagen. Die passende Snack-Meldung dafuer
/// baut Welle 3 in `meal_analysis_sheet.dart` aus [userMessage].
class ProductWithoutNutritionException implements Exception {
  const ProductWithoutNutritionException({
    required this.barcode,
    required this.productName,
    required this.kcalPer100G,
  });

  final String barcode;
  final String productName;

  /// Der gelesene Wert. `0` heisst "keine Angabe", alles ueber
  /// [PlausibilityLimits.kcalPer100GMax] heisst "Angabe ist Datenmuell".
  final double kcalPer100G;

  /// `true`, wenn ein Wert dastand, er aber unmoeglich ist (kJ im kcal-Feld).
  bool get isImplausible => kcalPer100G > 0;

  /// Fertige Meldung fuer die Oberflaeche.
  String get userMessage => isImplausible
      ? '$productName gefunden, aber die Nährwertangabe ist unplausibel '
            '(${kcalPer100G.round()} kcal / 100 g). Bitte manuell eintragen.'
      : '$productName gefunden, aber ohne Nährwertangaben. '
            'Bitte manuell eintragen.';

  @override
  String toString() =>
      'ProductWithoutNutritionException(barcode: $barcode, '
      'kcalPer100G: $kcalPer100G)';
}

String? _firstNonEmptyString(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) {
      continue;
    }
    final text = value.toString().trim();
    if (text.isNotEmpty) {
      return text;
    }
  }
  return null;
}
