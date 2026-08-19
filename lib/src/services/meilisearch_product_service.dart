import 'dart:convert';
import 'dart:io';

import '../models/meal_analysis_result.dart';
import 'eatova_http.dart';
import 'open_food_facts_product_service.dart';
import 'search_credentials.dart';

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
///
/// **Zugangsdaten kommen zur Laufzeit** aus [SearchCredentialsSource]
/// (Cache -> Fetch -> Compile-Time-Default -> aus). Der Service bleibt
/// dadurch `const`-konstruierbar: Default-Parameter muessen
/// Compile-Zeit-Konstanten sein, und eine `const`-Seam-Instanz darf in
/// ihren Methoden sehr wohl veraenderliche Statics lesen.
class MeilisearchProductService implements ProductLookupService {
  const MeilisearchProductService({
    this.credentials = const GlobalSearchCredentialsSource(),
  });

  final SearchCredentialsSource credentials;

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

    // Wartet hoechstens auf die laufende Platten-Hydration, nie aufs Netz.
    final creds = await credentials.resolve();
    if (!creds.isUsable) {
      // Mirror aus (Server-Kill-Switch oder abgelehnter Key ohne Ersatz):
      // sofort werfen, damit der FallbackProductService OHNE eine einzige
      // Netz-Anfrage zu OpenFoodFacts weiterzieht.
      throw const HttpException('Mirror search disabled: no usable key.');
    }

    // Knackige Timeouts (HttpTimeoutPolicy.mirror): der Mirror ist entweder
    // schnell oder der FallbackProductService soll zuegig zu OpenFoodFacts
    // weiterziehen.
    final client = createHttpClient(HttpTimeoutPolicy.mirror);
    try {
      try {
        return await _searchOnce(client, creds, cleanQuery);
      } on _MirrorAuthException {
        // DER Rotations-Pfad. Meilisearch antwortet auf einen widerrufenen
        // oder falschen Key mit 403 (fehlender Header: 401). Ohne diesen
        // Zweig wuerde nach einer Rotation JEDER installierte Build still
        // und dauerhaft auf OpenFoodFacts zurueckfallen — und die Rotation
        // waere trotzdem nicht durchfuehrbar.
        final replacement = await credentials.invalidate(creds);
        if (!replacement.isUsable ||
            replacement.searchKey == creds.searchKey) {
          // Kein anderer Key verfuegbar -> werfen, der Fallback nimmt OFF.
          throw const HttpException(
            'Mirror search rejected the key and no replacement was available.',
          );
        }
        // GENAU EIN Retry: _searchOnce ruft sich nie selbst auf, ein
        // weiterer 401/403 fliegt aus dem Block heraus in den Fallback.
        return await _searchOnce(client, replacement, cleanQuery);
      }
    } finally {
      // Wird auch bei Retry genau EINMAL geschlossen — der zweite Versuch
      // nutzt bewusst denselben (bereits verbundenen) Client.
      client.close(force: true);
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

    // NUR 401/403 sind ein Rotations-Signal. Ein 5xx heisst „Mirror kaputt",
    // nicht „Key ungueltig" — den Key deswegen wegzuwerfen wuerde bei jedem
    // Server-Wackler eine Edge-Function-Anfrage ausloesen.
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw _MirrorAuthException(response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Mirror search failed: ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final hits = decoded['hits'];
    if (hits is! List) {
      // Sentinel-Rest D: ein 2xx ohne `hits`-Liste (Proxy-Fehlerseite,
      // Schema-Aenderung) ist ein kaputter Mirror, keine leere Suche — die
      // Antwort auf eine echte leere Suche ist `hits: []`. Werfen wie beim
      // 5xx: der FallbackProductService klassifiziert/meldet den Fehler
      // (_meldeWennUnerwartet) und zieht zu OpenFoodFacts weiter.
      //
      // BEWUSST [MirrorSchemaException] und keine [HttpException]: letztere
      // ist eine IOException und zaehlt dort zu den erwarteten Netzfehlern —
      // der Alarm haette nie gemeldet.
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

/// Der Mirror hat auf einen 2xx etwas geliefert, das keine Suchantwort ist
/// (Proxy-Fehlerseite, geaendertes Index-Schema).
///
/// Der Typ existiert allein wegen der Klassifizierung im
/// [FallbackProductService]: dort gilt die ganze `IOException`-Familie als
/// erwarteter Netzfehler und bleibt still. Eine [HttpException] — die
/// naheliegende Wahl — ist eine IOException, der Schema-Drift-Alarm haette
/// also nie gemeldet. Deshalb `implements Exception` und sonst nichts: nur
/// so faellt er in den „unerwartet"-Zweig und erreicht den CrashReporter.
///
/// [message] ist eine Konstante aus diesem Service, nie ein Antwort-Body —
/// im Report landet ohnehin nur der Typname (sanitizeForReport).
class MirrorSchemaException implements Exception {
  const MirrorSchemaException(this.message);

  final String message;

  @override
  String toString() => 'MirrorSchemaException: $message';
}

/// Der Mirror hat den Search-Key abgelehnt (401 fehlender Header /
/// 403 widerrufener oder falscher Key). Rein intern: verlaesst
/// [MeilisearchProductService.searchProducts] nie, dort wird daraus
/// entweder ein Retry oder eine [HttpException] fuer den Fallback.
class _MirrorAuthException implements Exception {
  const _MirrorAuthException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'Mirror rejected the search key (HTTP $statusCode)';
}
