import 'dart:convert';
import 'dart:io';

import '../l10n/l10n.dart';
import '../models/meal_analysis_result.dart';
import '../models/model_limits.dart';
import 'eatova_http.dart';

abstract class ProductLookupService {
  Future<MealAnalysisResult> lookupBarcode(String barcode);
  Future<List<ProductSearchResult>> searchProducts(String query);
}

/// The one energy filter for every product source: search, barcode, mirror.
///
/// Both halves are needed: [isPlausibleKcalPer100G] lets 0 through (a bar
/// listing only kJ parses to 0 kcal), and `> 0` alone lets 2180 through (a kJ
/// number sitting in the kcal field). Review 2026-08-08, B7.
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

/// Direct OpenFoodFacts access; the only search/lookup path.
///
///  * Barcode: core API v3. An unknown barcode answers HTTP 404 *with* a JSON
///    body, so `result.id == "product_found"` decides, not the status.
///  * Text search: the classic `cgi/search.pl` (de -> world fallback) on
///    purpose. Search-a-licious matches multi-word queries as OR, ranking
///    empty and foreign-language records above the expected products;
///    search.pl does word-AND plus popularity ranking. Deprecated for new
///    integrations, so a shutdown means rebuilding SaL with client re-ranking.
///
/// Both paths normalize the product map before the parser, and both check
/// [_energieProblem]: search filters silently, barcode throws
/// [ProductWithoutNutritionException] because "not found" would be wrong for
/// a product the user is holding (B7).
class OpenFoodFactsProductService implements ProductLookupService {
  /// Test seam only: both always point at OpenFoodFacts in production. They
  /// let the wire test run the real parse/filter chain against response bytes
  /// from a loopback server (Review 2026-08-08, G2).
  const OpenFoodFactsProductService({
    this.productBaseUrl = defaultProductBaseUrl,
    this.searchBaseUrls = defaultSearchBaseUrls,
    this.searchChainBudget = defaultSearchChainBudget,
  });

  static const String defaultProductBaseUrl =
      'https://world.openfoodfacts.org/api/v3/product';
  static const List<String> defaultSearchBaseUrls = <String>[
    'https://de.openfoodfacts.org/cgi/search.pl',
    'https://world.openfoodfacts.org/cgi/search.pl',
  ];

  /// Ceiling over the de -> world chain (review P10-02). Both endpoints run
  /// one after the other, so their cost adds up: at 20 s per request (
  /// [HttpTimeoutPolicy.openFoodFacts]) the pair could hold the caller for
  /// 40 s. 24 s leaves a stalling `de` room to fail and `world` room to still
  /// answer, without the sum ever reaching the phase arithmetic.
  static const Duration defaultSearchChainBudget = Duration(seconds: 24);

  final String productBaseUrl;
  final List<String> searchBaseUrls;

  /// Test seam plus tuning knob for [defaultSearchChainBudget].
  final Duration searchChainBudget;

  /// `nutrition_data_per` is required (B7): the parser falls back to
  /// `energy-kcal_value`, which is per 100 g or per serving depending on that
  /// field — without it a per-serving pizza reads as 900 kcal/100 g.
  /// The kJ fields live inside `nutriments` and come with that group.
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

      // v3 returns "not found" as 404 with a JSON body: parse first, decide
      // after. Only real transport errors (no JSON) throw HttpException.
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

      // Unlike search, the barcode path does not filter silently: a named
      // exception carries product name and measured value.
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
    // One ceiling over BOTH endpoints (P10-02). Closing the client in the
    // `finally` is what actually cuts the socket of the leg still in flight.
    final deadline = ChainDeadline(
      searchChainBudget,
      operation: 'off.searchProducts',
    );
    try {
      Object? lastError;
      // An endpoint that answered 2xx with a well-formed, EMPTY product list
      // has spoken: "not in this index". P10-07 — `lastError` used to live
      // outside the loop, so an empty `de` followed by a 502 from `world`
      // threw, and the user saw an error instead of the empty view with the
      // manual-entry offer (plus three retries on top of it).
      var cleanlyEmpty = false;

      for (final baseUrl in searchBaseUrls) {
        if (deadline.isExpired) break;
        try {
          final answer = await deadline.guard(
            _searchProductsFromEndpoint(
              client: client,
              baseUrl: baseUrl,
              query: cleanQuery,
            ),
          );
          if (answer.hits.isNotEmpty) {
            return answer.hits;
          }
          // Only a REAL product list counts as "nothing found"; a 2xx without
          // one is a broken endpoint (see [_searchProductsFromEndpoint]).
          cleanlyEmpty |= answer.wellFormed;
        } catch (error) {
          lastError = error;
        }
      }

      // Order matters: "nothing found" beats a later leg's error, an error
      // only wins when NO leg answered cleanly.
      if (cleanlyEmpty || lastError == null) {
        return const <ProductSearchResult>[];
      }
      throw lastError;
    } finally {
      deadline.dispose();
      client.close(force: true);
    }
  }

  /// One endpoint's answer: the loggable hits, plus whether the response even
  /// WAS a search response.
  ///
  /// The flag is the difference P10-07 turns on: `wellFormed: true` with no
  /// hits means "not in this index" — an answer — while a 2xx without a
  /// `products` list (proxy error page, schema change) is a broken endpoint
  /// that must not silence a later leg's error. Both still fall through to the
  /// next endpoint.
  Future<({List<ProductSearchResult> hits, bool wellFormed})>
  _searchProductsFromEndpoint({
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
      return (hits: const <ProductSearchResult>[], wellFormed: false);
    }

    // A loop, not a map/where chain: the plausibility filter needs the raw
    // product map next to the parsed hit (see _energieProblem).
    final treffer = <ProductSearchResult>[];
    for (final roh in products.whereType<Map>()) {
      final product = _normalizeProduct(
        roh.map((key, value) => MapEntry(key.toString(), value)),
      );
      final hit = ProductSearchResult.fromOpenFoodFacts(product);
      if (hit.title.trim().isEmpty) {
        continue;
      }
      // Entries without (or with impossible) energy are not loggable. In
      // search, dropping them is right: a missing hit goes unnoticed, a
      // wrongly logged one does not.
      if (_energieProblem(product, hit.result, hit.code) != null) {
        continue;
      }
      treffer.add(hit);
    }
    return (
      hits: List<ProductSearchResult>.unmodifiable(treffer),
      wellFormed: true,
    );
  }

  /// Raw kcal/100 g straight from the OFF record.
  ///
  /// Deliberately independent of [MealAnalysisResult.fromOpenFoodFacts]: if
  /// the model clamps an impossible value (2180 -> 900) instead of rejecting
  /// it, the cap here would be useless (B7). `energy-kcal_value` is excluded
  /// because it is base-dependent (see [_fields]).
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

  /// `null` when the energy value is loggable, otherwise the matching
  /// [ProductWithoutNutritionException]. One place for search and barcode.
  ///
  /// Order matters: the parsed result decides first, because the parser may
  /// have replaced an implausible kcal value from the kJ field (2180 ->
  /// 521 kcal). Checking the raw value first would drop that rescued hit.
  /// The raw value only matters when an impossible value was clamped, which
  /// by definition lands exactly on [PlausibilityLimits.kcalPer100GMax].
  static ProductWithoutNutritionException? _energieProblem(
    Map<String, dynamic> product,
    MealAnalysisResult analyse,
    String barcode,
  ) {
    final geparst = analyse.kcalPer100G;
    final roh = _rawKcalPer100G(product);
    final rohUnmoeglich = roh != null && !isPlausibleKcalPer100G(roh);

    if (!isLoggableKcalPer100G(geparst)) {
      // Genuine 0 kcal products (water, zero drinks): the source states 0
      // explicitly, so it is a measurement, not a parser sentinel.
      if (geparst == 0 &&
          !rohUnmoeglich &&
          MealAnalysisResult.offMeldetExplizitNullKcal(product)) {
        return null;
      }
      return ProductWithoutNutritionException(
        barcode: barcode,
        productName: analyse.mealName,
        // If the record held an impossible value, that is the diagnosis, not
        // the 0 the parser made of it.
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

  /// Levels the format differences between product-read (v3) and
  /// Search-a-licious so one parser handles both: `product_name_de` wins over
  /// `product_name`, and a `brands` array is joined into a string.
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

/// The barcode does not exist in the queried source.
///
/// Its own type, not a [FormatException]: callers must tell "unknown product"
/// (routine, silent) from "response format changed" (worth reporting).
class ProductNotFoundException implements Exception {
  const ProductNotFoundException(this.barcode);

  final String barcode;

  @override
  String toString() => 'ProductNotFoundException(barcode: $barcode)';
}

/// The product exists but carries no loggable energy value: either missing
/// entirely (kJ only -> 0 kcal) or physically impossible (> 900 kcal/100 g).
///
/// Thrown rather than returned because [MealAnalysisResult] has no field for
/// "no nutrition" and `onAdd` fires unconditionally, so a silent 0 kcal entry
/// would reach the diary. Not [ProductNotFoundException], because the user is
/// holding the product; this type carries name and value for [userMessage].
class ProductWithoutNutritionException implements Exception {
  const ProductWithoutNutritionException({
    required this.barcode,
    required this.productName,
    required this.kcalPer100G,
  });

  final String barcode;
  final String productName;

  /// The value read. `0` means "not stated", anything above
  /// [PlausibilityLimits.kcalPer100GMax] means "garbage data".
  final double kcalPer100G;

  /// `true` when a value was present but impossible (kJ in the kcal field).
  bool get isImplausible => kcalPer100G > 0;

  /// Ready-made UI message in the language of [l10n], defaulting to German
  /// ([deL10n]) so context-free callers such as tests still work.
  String userMessage([AppLocalizations? l10n]) {
    final t = l10n ?? deL10n;
    return isImplausible
        ? t.foodProductImplausibleMessage(productName, kcalPer100G.round())
        : t.foodProductNoNutritionMessage(productName);
  }

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
