import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/meal_analysis_result.dart';

abstract class ProductLookupService {
  Future<MealAnalysisResult> lookupBarcode(String barcode);
  Future<List<ProductSearchResult>> searchProducts(String query);
}

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
class OpenFoodFactsProductService implements ProductLookupService {
  const OpenFoodFactsProductService();

  static const String _productBaseUrl =
      'https://world.openfoodfacts.org/api/v3/product';
  static const List<String> _searchBaseUrls = <String>[
    'https://de.openfoodfacts.org/cgi/search.pl',
    'https://world.openfoodfacts.org/cgi/search.pl',
  ];
  static const String _fields =
      'code,product_name,product_name_de,generic_name,brands,quantity,'
      'serving_size,serving_quantity,nutriments,image_front_small_url,'
      'image_front_url,image_small_url,image_url';

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    final cleanBarcode = barcode.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanBarcode.isEmpty) {
      throw const FormatException('Empty barcode.');
    }

    final client = HttpClient();
    try {
      final uri =
          Uri.parse('$_productBaseUrl/$cleanBarcode.json?fields=$_fields');
      final request = await client.getUrl(uri);
      _setUserAgent(request);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      // v3 liefert "nicht gefunden" als 404 MIT JSON-Body — erst parsen,
      // dann entscheiden. Nur echte Transportfehler (5xx, kein JSON) werfen
      // eine HttpException.
      final Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        throw HttpException(
            'OpenFoodFacts lookup failed: ${response.statusCode}');
      }

      final result = decoded['result'];
      final found = result is Map<String, dynamic> &&
          result['id'] == 'product_found' &&
          decoded['product'] is Map<String, dynamic>;
      if (!found) {
        throw const FormatException('Product not found in OpenFoodFacts.');
      }

      return MealAnalysisResult.fromOpenFoodFacts(
        _normalizeProduct(decoded['product'] as Map<String, dynamic>),
        cleanBarcode,
      );
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

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      Object? lastError;

      for (final baseUrl in _searchBaseUrls) {
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

  static Future<List<ProductSearchResult>> _searchProductsFromEndpoint({
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
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 8));
    _setUserAgent(request);
    final response = await request.close().timeout(const Duration(seconds: 12));
    final body = await response.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 12),
        );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('OpenFoodFacts search failed: ${response.statusCode}');
    }

    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final products = decoded['products'];
    if (products is! List) {
      return const <ProductSearchResult>[];
    }

    return products
        .whereType<Map>()
        .map(
          (product) => ProductSearchResult.fromOpenFoodFacts(
            _normalizeProduct(
              product.map((key, value) => MapEntry(key.toString(), value)),
            ),
          ),
        )
        .where((product) => product.title.trim().isNotEmpty)
        // Kalorien-Tracker: Eintraege ohne Energie-Angabe sind nicht loggbar
        // und wuerden als "0 kcal"-Karteileichen die Liste verstopfen.
        .where((product) => product.kcalPer100G > 0)
        .toList(growable: false);
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
      'ShiftFit/1.0 (OpenFoodFacts nutrition lookup; mxritzgit/shiftfit)',
    );
  }
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
