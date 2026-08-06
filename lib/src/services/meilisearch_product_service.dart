import 'dart:convert';
import 'dart:io';

import '../config/search_config.dart';
import '../models/meal_analysis_result.dart';
import 'eatova_http.dart';
import 'open_food_facts_product_service.dart';

/// Textsuche gegen den eigenen Meilisearch-Index (OFF-Dump, DE/AT/CH,
/// nur Produkte mit kcal — siehe /opt/off-import.py auf dem Server).
///
/// Die Index-Dokumente tragen das OFF-Produktschema (nutriments
/// verschachtelt), deshalb laufen die Treffer unveraendert durch
/// [ProductSearchResult.fromOpenFoodFacts]. Ranking macht Meilisearch:
/// alle Wörter zuerst (matchingStrategy "last"), Tippfehler-Toleranz
/// (Salami ~ Salame), danach Popularitaet (scans:desc).
///
/// Bewusst NUR Suche: Barcode-Lookups beantwortet der Index nicht
/// ([lookupBarcode] wirft sofort) — der [FallbackProductService] reicht
/// sie damit direkt an die OFF-Live-API (v3) weiter, die auch brandneue
/// Produkte kennt.
class MeilisearchProductService implements ProductLookupService {
  const MeilisearchProductService({
    this.baseUrl = SearchConfig.mirrorBaseUrl,
    this.searchKey = SearchConfig.mirrorSearchKey,
  });

  final String baseUrl;
  final String searchKey;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) {
    throw UnsupportedError(
      'Barcode-Lookup laeuft ueber die OFF-Live-API (Fallback).',
    );
  }

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.length < 2) {
      return const <ProductSearchResult>[];
    }

    // Knackige Timeouts (HttpTimeoutPolicy.mirror): der Mirror ist entweder
    // schnell oder der FallbackProductService soll zuegig zu OpenFoodFacts
    // weiterziehen.
    final client = createHttpClient(HttpTimeoutPolicy.mirror);
    try {
      final uri = Uri.parse('$baseUrl/indexes/products/search');
      final response = await sendTextRequest(
        client,
        method: 'POST',
        uri: uri,
        policy: HttpTimeoutPolicy.mirror,
        operation: 'mirror.search',
        configure: (request) {
          request.headers
            ..set(HttpHeaders.authorizationHeader, 'Bearer $searchKey')
            ..contentType = ContentType.json;
        },
        body: jsonEncode(<String, Object>{'q': cleanQuery, 'limit': 12}),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Mirror search failed: ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final hits = decoded['hits'];
      if (hits is! List) {
        return const <ProductSearchResult>[];
      }

      return hits
          .whereType<Map>()
          .map(
            (product) => ProductSearchResult.fromOpenFoodFacts(
              product.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .where((product) => product.title.trim().isNotEmpty)
          .toList(growable: false);
    } finally {
      client.close(force: true);
    }
  }
}
