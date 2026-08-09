import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

/// Gemeinsame dart:io-HTTP-Schicht fuer alle Services mit rohem [HttpClient]
/// (Meilisearch-Mirror, OpenFoodFacts, analyze-meal Edge Function).
///
/// Bewusst KEIN package:http — die Services nutzen dart:io direkt, und das
/// bleibt so. Diese Datei zentralisiert nur die drei Dinge, die vorher an
/// vier Stellen unterschiedlich (oder gar nicht) geloest waren:
///
///  1. **Timeout auf JEDER Phase**: `connectionTimeout` deckt nur den
///     TCP-Aufbau. Haengt der Server nach dem Verbindungsaufbau (z.B. ein
///     LLM-Provider hinter der Edge Function), wuerde `close()` sonst endlos
///     warten und der Spinner drehte fuer immer. Deshalb tragen Request-
///     Erzeugung, `close()` und Body-Lesen jeweils ein eigenes Timeout.
///  2. **Benannte Timeout-Policies** ([HttpTimeoutPolicy]) statt magischer
///     Sekundenwerte in jedem Service.
///  3. **Einheitliches dev.log bei Transportfehlern** (Timeout, Socket, TLS)
///     unter dem Log-Namen `eatova_http` — der Fehler wird unveraendert
///     rethrown, die Fehler-Semantik der Aufrufer bleibt identisch.
class HttpTimeoutPolicy {
  const HttpTimeoutPolicy({
    required this.connect,
    required this.response,
    required this.body,
  });

  /// TCP-Aufbau + Erzeugen des Request-Objekts (`connectionTimeout` und
  /// Timeout auf `openUrl`).
  final Duration connect;

  /// `close()` (Upload + Warten auf die Response-Header).
  final Duration response;

  /// Komplettes Einlesen des Response-Bodys.
  final Duration body;

  /// Meilisearch-Mirror: aggressiv-knapp. Der Mirror ist entweder schnell
  /// oder der FallbackProductService soll zuegig zu OpenFoodFacts
  /// weiterziehen — die Suche haengt sonst hinter einem lahmen vServer fest.
  static const HttpTimeoutPolicy mirror = HttpTimeoutPolicy(
    connect: Duration(seconds: 4),
    response: Duration(seconds: 6),
    body: Duration(seconds: 6),
  );

  /// OpenFoodFacts (Barcode-Lookup v3 + cgi/search.pl): oeffentliche API mit
  /// schwankender Last, daher grosszuegiger als der eigene Mirror — aber
  /// endlich MIT Timeout auch auf dem Barcode-Pfad (der hatte vorher keins).
  static const HttpTimeoutPolicy openFoodFacts = HttpTimeoutPolicy(
    connect: Duration(seconds: 8),
    response: Duration(seconds: 12),
    body: Duration(seconds: 12),
  );

  /// analyze-meal Edge Function: im `close()` steckt der komplette
  /// Bild-Upload + die LLM-Antwortzeit. Die Edge Function bricht ihrerseits
  /// nach 45 s ab — der Client haelt bewusst laenger durch als der Server.
  static const HttpTimeoutPolicy mealAnalysis = HttpTimeoutPolicy(
    connect: Duration(seconds: 15),
    response: Duration(seconds: 60),
    body: Duration(seconds: 15),
  );
}

/// Roh-[HttpClient] mit dem `connectionTimeout` der [policy]. Der Aufrufer
/// bleibt fuer `close(force: true)` im `finally` verantwortlich (das erlaubt
/// Wiederverwendung ueber mehrere Requests, z.B. de->world-Fallback bei OFF).
HttpClient createHttpClient(HttpTimeoutPolicy policy) =>
    HttpClient()..connectionTimeout = policy.connect;

/// Fertig gelesene Text-Antwort: Statuscode + UTF-8-dekodierter Body.
class HttpTextResponse {
  const HttpTextResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// Fuehrt einen Request mit Timeout auf jeder Phase aus und liest den Body
/// als UTF-8-Text. [configure] setzt Header (laeuft vor dem Body-Write),
/// [body] wird — falls gesetzt — vor `close()` geschrieben.
///
/// Transportfehler (TimeoutException, SocketException, TLS, …) werden einmal
/// zentral geloggt und unveraendert rethrown; Status-Code-Auswertung bleibt
/// Sache des Aufrufers (OFF antwortet z.B. bewusst 404 MIT JSON-Body).
Future<HttpTextResponse> sendTextRequest(
  HttpClient client, {
  required String method,
  required Uri uri,
  required HttpTimeoutPolicy policy,
  required String operation,
  void Function(HttpClientRequest request)? configure,
  String? body,
}) async {
  try {
    final request = await client.openUrl(method, uri).timeout(policy.connect);
    // Redirects NICHT folgen (Sicherheits-Audit 2026-08-09): dart:io kopiert
    // die Request-Header — inkl. `Authorization` mit User-JWT (search-key,
    // analyze-meal) — beim Redirect aufs Ziel. Ein von Supabase ausgeliefertes
    // Cross-Origin-3xx wuerde den Token so an einen fremden Host tragen. Kein
    // Aufrufer braucht Redirects (alle Endpunkte antworten direkt); ein 3xx
    // wird damit zum Statuscode, den der Aufrufer als Fehler behandelt.
    request.followRedirects = false;
    configure?.call(request);
    if (body != null) request.write(body);
    final response = await request.close().timeout(policy.response);
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(policy.body);
    return HttpTextResponse(statusCode: response.statusCode, body: text);
  } catch (e, st) {
    dev.log(
      '$operation failed ($method ${uri.host})',
      error: e,
      stackTrace: st,
      name: 'eatova_http',
    );
    rethrow;
  }
}
