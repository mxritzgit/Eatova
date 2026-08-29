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
    this.total,
  });

  /// TCP handshake plus creating the request object (`connectionTimeout` and
  /// the timeout on `openUrl`).
  final Duration connect;

  /// `close()` (upload plus waiting for the response headers).
  final Duration response;

  /// Reading the full response body.
  final Duration body;

  /// Ceiling over ALL phases of ONE request (review P10-02).
  ///
  /// The three phase timeouts run one after another, so their SUM is what a
  /// request can really cost: a server that stalls just short of every phase
  /// limit used to hold the mirror for 16 s and OpenFoodFacts for 32 s. Each
  /// phase timeout stays what it is — the diagnosis of WHERE it hangs — and
  /// this is the backstop for the sum. `null` = no ceiling beyond the phases.
  final Duration? total;

  /// Meilisearch mirror: deliberately tight. Either the mirror is fast or
  /// FallbackProductService should move on to OpenFoodFacts quickly.
  static const HttpTimeoutPolicy mirror = HttpTimeoutPolicy(
    connect: Duration(seconds: 4),
    response: Duration(seconds: 6),
    body: Duration(seconds: 6),
    total: Duration(seconds: 10),
  );

  /// OpenFoodFacts (barcode lookup v3 + cgi/search.pl): public API with
  /// variable load, so more generous than the own mirror.
  static const HttpTimeoutPolicy openFoodFacts = HttpTimeoutPolicy(
    connect: Duration(seconds: 8),
    response: Duration(seconds: 12),
    body: Duration(seconds: 12),
    total: Duration(seconds: 20),
  );

  /// analyze-meal Edge Function: `close()` covers the image upload plus LLM
  /// latency. The provider call aborts after 45 s, so the client outlasts it.
  ///
  /// [total] used to be 90 s — exactly 15 + 60 + 15, i.e. the phase sum
  /// itself, a ceiling that could never fire (P10-02b). The server side is
  /// what calibrates it: the function gives up on its OWN request at
  /// `ANALYZE_MEAL_REQUEST_BUDGET_MS` (55 s), so past that point the client
  /// was waiting at least 35 s on something already dead. 75 s is the sum of
  /// the three things that can legitimately cost time — the connect phase
  /// (15 s), the server's whole budget (55 s) and 5 s for the small JSON
  /// answer — and no more. Move it together with `REQUEST_BUDGET_MS`: it must
  /// stay ABOVE that budget plus the response transfer, or a slow but live
  /// analysis gets cut off by its own client.
  static const HttpTimeoutPolicy mealAnalysis = HttpTimeoutPolicy(
    connect: Duration(seconds: 15),
    response: Duration(seconds: 60),
    body: Duration(seconds: 15),
    total: Duration(seconds: 75),
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

/// Runs a request with a timeout on every phase PLUS
/// [HttpTimeoutPolicy.total] over their sum, and reads the body as UTF-8.
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
    final work = _sendTextRequest(
      client,
      method: method,
      uri: uri,
      policy: policy,
      configure: configure,
      body: body,
    );
    final total = policy.total;
    return await (total == null ? work : work.timeout(total));
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

/// The three phases. Split off so [sendTextRequest] can put ONE ceiling around
/// all of them and still log every failure in one place.
Future<HttpTextResponse> _sendTextRequest(
  HttpClient client, {
  required String method,
  required Uri uri,
  required HttpTimeoutPolicy policy,
  required void Function(HttpClientRequest request)? configure,
  required String? body,
}) async {
  final request = await client.openUrl(method, uri).timeout(policy.connect);
  // Do not follow redirects (security audit 2026-08-09): dart:io copies the
  // request headers — including `Authorization` with the user JWT — onto the
  // redirect target, so a cross-origin 3xx would leak the token. No caller
  // needs redirects; a 3xx becomes a status code the caller treats as error.
  request.followRedirects = false;
  configure?.call(request);
  if (body != null) request.write(body);
  final response = await request.close().timeout(policy.response);
  final text = await response.transform(utf8.decoder).join().timeout(
    policy.body,
  );
  return HttpTextResponse(statusCode: response.statusCode, body: text);
}

/// One budget spanning a CHAIN of requests (review P10-02).
///
/// [HttpTimeoutPolicy] bounds a single request. What used to be unbounded is
/// the chain around it: mirror plus key rotation plus retry, OpenFoodFacts
/// `de` then `world`, primary then fallback. Every leg was inside its own
/// limit while their sum ran to 99 s per attempt.
///
/// Usage — start it once, race every leg against it, dispose it in a
/// `finally`:
///
/// ```dart
/// final deadline = ChainDeadline(budget, operation: 'off.search');
/// try {
///   for (final url in urls) {
///     if (deadline.isExpired) break;
///     final hits = await deadline.guard(_searchOne(url));
///   }
/// } finally {
///   deadline.dispose();
/// }
/// ```
///
/// Built on a [Timer], not on a wall clock: `flutter_test` and `fake_async`
/// drive timers, so the ceiling is provable in milliseconds instead of in the
/// seconds it really lasts. Expiry does not abort the leg in flight — the
/// caller's `finally` closing its [HttpClient] does that; the deadline makes
/// sure the caller GETS to that `finally`.
class ChainDeadline {
  ChainDeadline(this.budget, {required this.operation}) {
    _timer = Timer(budget, () {
      if (_expiry.isCompleted) return;
      _expiry.completeError(
        TimeoutException(operation, budget),
        StackTrace.current,
      );
    });
    // Nobody may be racing at the moment the timer fires (between two legs,
    // or after a `break`). Without this the error would surface as an
    // unhandled zone error and take down an unrelated test.
    _expiry.future.ignore();
  }

  /// Ceiling over the whole chain.
  final Duration budget;

  /// Names the [TimeoutException] thrown on expiry — the same kind of label
  /// [sendTextRequest] logs (`off.searchProducts`, `mirror.search`).
  final String operation;

  /// `Never`, so the expiry future fits every leg's element type without a
  /// cast: it only ever completes with an error.
  final Completer<Never> _expiry = Completer<Never>();
  Timer? _timer;

  /// True once the budget is gone — the cheap check before starting a leg
  /// that would only be cut off anyway.
  bool get isExpired => _expiry.isCompleted;

  /// [work] against the remaining budget: whichever finishes first wins, and
  /// an expired deadline throws [TimeoutException] straight away. A losing
  /// leg's later result (or error) is dropped, not left unhandled.
  Future<T> guard<T>(Future<T> work) => isExpired
      ? _expiry.future
      : Future.any(<Future<T>>[work, _expiry.future]);

  /// Stops the timer. Idempotent, and mandatory in a `finally` — a live timer
  /// outliving its chain fails every widget test that follows.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
