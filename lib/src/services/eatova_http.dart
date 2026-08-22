import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

/// Shared dart:io HTTP layer for all services on a raw [HttpClient]
/// (Meilisearch mirror, OpenFoodFacts, analyze-meal Edge Function).
///
/// Deliberately no package:http. It centralizes three things: a timeout on
/// every phase (`connectionTimeout` only covers the TCP handshake, so a server
/// hanging afterwards would make `close()` wait forever), named timeout
/// policies instead of magic second values, and one `dev.log` for transport
/// errors under the name `eatova_http` — errors are rethrown unchanged.
class HttpTimeoutPolicy {
  const HttpTimeoutPolicy({
    required this.connect,
    required this.response,
    required this.body,
  });

  /// TCP handshake plus creating the request object (`connectionTimeout` and
  /// the timeout on `openUrl`).
  final Duration connect;

  /// `close()` (upload plus waiting for the response headers).
  final Duration response;

  /// Reading the full response body.
  final Duration body;

  /// Meilisearch mirror: deliberately tight. Either the mirror is fast or
  /// FallbackProductService should move on to OpenFoodFacts quickly.
  static const HttpTimeoutPolicy mirror = HttpTimeoutPolicy(
    connect: Duration(seconds: 4),
    response: Duration(seconds: 6),
    body: Duration(seconds: 6),
  );

  /// OpenFoodFacts (barcode lookup v3 + cgi/search.pl): public API with
  /// variable load, so more generous than the own mirror.
  static const HttpTimeoutPolicy openFoodFacts = HttpTimeoutPolicy(
    connect: Duration(seconds: 8),
    response: Duration(seconds: 12),
    body: Duration(seconds: 12),
  );

  /// analyze-meal Edge Function: `close()` covers the image upload plus LLM
  /// latency. The function aborts after 45 s, so the client outlasts it.
  static const HttpTimeoutPolicy mealAnalysis = HttpTimeoutPolicy(
    connect: Duration(seconds: 15),
    response: Duration(seconds: 60),
    body: Duration(seconds: 15),
  );
}

/// Raw [HttpClient] with the [policy]'s `connectionTimeout`. The caller owns
/// `close(force: true)` in a `finally`, which allows reuse across requests
/// (e.g. the de->world fallback in OFF).
HttpClient createHttpClient(HttpTimeoutPolicy policy) =>
    HttpClient()..connectionTimeout = policy.connect;

/// Fully read text response: status code plus UTF-8 decoded body.
class HttpTextResponse {
  const HttpTextResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// Runs a request with a timeout on every phase and reads the body as UTF-8.
/// [configure] sets headers before the body write; [body] is written before
/// `close()`.
///
/// Transport errors are logged once and rethrown unchanged; status-code
/// handling stays with the caller (OFF answers 404 with a JSON body).
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
    // Do not follow redirects (security audit 2026-08-09): dart:io copies the
    // request headers — including `Authorization` with the user JWT — onto the
    // redirect target, so a cross-origin 3xx would leak the token. No caller
    // needs redirects; a 3xx becomes a status code the caller treats as error.
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
