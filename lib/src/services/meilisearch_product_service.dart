import 'dart:convert';
import 'dart:io';

import '../models/meal_analysis_result.dart';
import 'eatova_http.dart';
import 'open_food_facts_product_service.dart';
import 'search_credentials.dart';

/// Text search against the own Meilisearch index (OFF dump, DE/AT/CH, kcal
/// products only; see /opt/off-import.py on the server).
///
/// Index documents carry the OFF product schema, so hits pass unchanged
/// through [ProductSearchResult.fromOpenFoodFacts]. Meilisearch does the
/// ranking: all words first, typo tolerance, then popularity (scans:desc).
///
/// Search ONLY: the index answers no barcode lookups ([lookupBarcode] throws),
/// so [FallbackProductService] forwards those to the OFF live API, which also
/// knows brand-new products.
///
/// Credentials resolve at RUNTIME from [SearchCredentialsSource] (cache ->
/// fetch -> compile-time default -> off), which keeps the service `const`
/// constructible.
class MeilisearchProductService implements ProductLookupService {
  const MeilisearchProductService({
    this.credentials = const GlobalSearchCredentialsSource(),
    this.searchChainBudget = defaultSearchChainBudget,
  });

  /// Ceiling over search + key rotation + retry (review P10-02). The rotation
  /// path chains three waits — request, `invalidate` (3 s of its own), retry
  /// — which at 10 s per request ([HttpTimeoutPolicy.mirror]) added up to
  /// 23 s for a source whose whole point is being faster than OpenFoodFacts.
  /// 12 s covers one full request plus a rotation; anything slower is a
  /// broken mirror and belongs to the fallback.
  static const Duration defaultSearchChainBudget = Duration(seconds: 12);

  final SearchCredentialsSource credentials;

  /// Test seam plus tuning knob for [defaultSearchChainBudget].
  final Duration searchChainBudget;

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

    // Waits at most for the running disk hydration, never for the network.
    final creds = await credentials.resolve();
    if (!creds.isUsable) {
      // Mirror off (kill switch, or rejected key without replacement): throw
      // at once so the FallbackProductService moves on to OpenFoodFacts
      // without a single network request.
      throw const HttpException('Mirror search disabled: no usable key.');
    }

    // Tight timeouts (HttpTimeoutPolicy.mirror): the mirror is either fast or
    // the fallback should move on to OpenFoodFacts.
    final client = createHttpClient(HttpTimeoutPolicy.mirror);
    // One ceiling over request + rotation + retry (P10-02). On expiry the
    // `finally` below closes the client, which cuts the request in flight.
    final deadline = ChainDeadline(
      searchChainBudget,
      operation: 'mirror.search',
    );
    try {
      return await deadline.guard(
        _searchWithRotation(client, creds, cleanQuery, deadline),
      );
    } finally {
      deadline.dispose();
      // Closed exactly once, retry included: the second attempt reuses the
      // already connected client.
      client.close(force: true);
    }
  }

  Future<List<ProductSearchResult>> _searchWithRotation(
    HttpClient client,
    SearchCredentials creds,
    String cleanQuery,
    ChainDeadline deadline,
  ) async {
    try {
      return await _searchOnce(client, creds, cleanQuery);
    } on _MirrorAuthException {
      // THE rotation path. Meilisearch answers a revoked or wrong key with
      // 403 (missing header: 401). Without this branch every installed build
      // would silently fall back to OpenFoodFacts forever after a rotation.
      final replacement = await deadline.guard(credentials.invalidate(creds));
      if (!replacement.isUsable || replacement.searchKey == creds.searchKey) {
        // No other key available -> throw, the fallback takes OFF.
        throw const HttpException(
          'Mirror search rejected the key and no replacement was available.',
        );
      }
      // EXACTLY one retry: _searchOnce never recurses, another 401/403
      // leaves this block into the fallback.
      return _searchOnce(client, replacement, cleanQuery);
    }
  }

  Future<List<ProductSearchResult>> _searchOnce(
    HttpClient client,
    SearchCredentials creds,
    String cleanQuery,
  ) async {
    final uri = Uri.parse('${creds.baseUrl}/indexes/products/search');
    final response = await sendTextRequest(
      client,
      method: 'POST',
      uri: uri,
      policy: HttpTimeoutPolicy.mirror,
      operation: 'mirror.search',
      configure: (request) {
        request.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer ${creds.searchKey}')
          ..contentType = ContentType.json;
      },
      body: jsonEncode(<String, Object>{'q': cleanQuery, 'limit': 12}),
    );

    // ONLY 401/403 signal a rotation. A 5xx means broken mirror, not invalid
    // key; discarding the key there would fire an edge-function request on
    // every server hiccup.
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw _MirrorAuthException(response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Mirror search failed: ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final hits = decoded['hits'];
    if (hits is! List) {
      // A 2xx without a `hits` list (proxy error page, schema change) is a
      // broken mirror, not an empty search — an empty search returns
      // `hits: []`. Throw like on a 5xx so the fallback classifies, reports
      // and moves on.
      //
      // [MirrorSchemaException], not [HttpException]: the latter is an
      // IOException and counts as an expected network error there, so the
      // alarm would never fire.
      throw const MirrorSchemaException(
        'Mirror search returned a malformed body (no hits list).',
      );
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
  }
}

/// The mirror returned a 2xx that is not a search response (proxy error page,
/// changed index schema).
///
/// The type exists only for classification in [FallbackProductService], where
/// the whole `IOException` family counts as an expected network error and
/// stays silent. Hence plain `implements Exception`, so it lands in the
/// unexpected branch and reaches the CrashReporter.
///
/// [message] is always a constant from this service, never a response body.
class MirrorSchemaException implements Exception {
  const MirrorSchemaException(this.message);

  final String message;

  @override
  String toString() => 'MirrorSchemaException: $message';
}

/// The mirror rejected the search key (401 missing header / 403 revoked or
/// wrong key). Internal only: never leaves
/// [MeilisearchProductService.searchProducts], which turns it into a retry or
/// an [HttpException] for the fallback.
class _MirrorAuthException implements Exception {
  const _MirrorAuthException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'Mirror rejected the search key (HTTP $statusCode)';
}
