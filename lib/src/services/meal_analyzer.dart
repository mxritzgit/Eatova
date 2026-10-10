import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/meal_analysis_request.dart';
import '../models/meal_analysis_result.dart';
import 'eatova_http.dart';

abstract class MealAnalyzer {
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request);
}

/// Failures of the `analyze-meal` call the UI can name (Review 2026-08-27,
/// F4-01/F9-03). [code] is a stable, language-neutral identifier — the
/// server's `error` code or a client-side one — and is mapped to an ARB key
/// only at display time (`mealAnalysisErrorMessage`). Never persist the
/// localized text.
sealed class MealAnalysisException implements Exception {
  const MealAnalysisException();

  String get code;

  @override
  String toString() => 'MealAnalysisException($code)';
}

/// HTTP 429. [resetAt] comes from the server's `rateLimit.resetAt` when the
/// body was JSON; null for an HTML body from the gateway.
class MealAnalysisRateLimited extends MealAnalysisException {
  const MealAnalysisRateLimited({this.resetAt});

  final DateTime? resetAt;

  @override
  String get code => 'rate_limited';
}

/// No session token, or the server answered 401/403.
class MealAnalysisReauthRequired extends MealAnalysisException {
  const MealAnalysisReauthRequired();

  @override
  String get code => 'reauth_required';
}

/// Client-side cap (5 MB) or server 413 / `image_too_large`.
class MealImageTooLarge extends MealAnalysisException {
  const MealImageTooLarge();

  @override
  String get code => 'image_too_large';
}

/// The request was aborted via [MealAnalysisCancellation]; never shown.
class MealAnalysisCancelled extends MealAnalysisException {
  const MealAnalysisCancelled();

  @override
  String get code => 'cancelled';
}

/// Any other non-2xx answer or an unusable 2xx body. [code] is the server's
/// `error` (`provider_timeout`, `provider_error`, `internal_error`, ...) or
/// `http_<status>` when the body carried none; [debugMessage] is the server's
/// `message` — German, for logs only.
class MealAnalysisServerError extends MealAnalysisException {
  const MealAnalysisServerError({
    required this.statusCode,
    required this.code,
    this.debugMessage,
  });

  final int statusCode;

  @override
  final String code;

  final String? debugMessage;

  @override
  String toString() {
    final suffix = debugMessage == null ? '' : ': $debugMessage';
    return 'MealAnalysisServerError($statusCode $code$suffix)';
  }
}

/// Builds the JSON body for the `analyze-meal` function. Split off from HTTP so
/// `language`/`freeTextHint` are testable without a network fake.
Map<String, dynamic> buildAnalyzeMealBody(MealAnalysisRequest request) {
  final imageBytes = request.imageBytes;
  if (!MealAnalysisRequest.isValidHint(request.freeTextHint)) {
    throw const MealAnalysisServerError(statusCode: 400, code: 'invalid_hint');
  }
  final hint = MealAnalysisRequest.normalizedHint(request.freeTextHint);
  return <String, dynamic>{
    if (imageBytes != null) 'imageBase64': base64Encode(imageBytes),
    // The server's default; the app has no portion picker since May 2026.
    'portionHint': 'normal',
    if (hint != null) 'freeTextHint': hint,
    'language': request.language,
  };
}

/// Top-level for `compute()`: builds and encodes the body off the UI isolate.
/// base64 of a photo plus its jsonEncode copy are worst-case >13 MB of string
/// churn, paid right as the scan spinner starts (perf finding 6, 2026-08-31).
/// Callers hand in a request WITHOUT [MealAnalysisRequest.cancellation] — its
/// closures cannot cross the isolate boundary.
String encodeAnalyzeMealBody(MealAnalysisRequest request) =>
    jsonEncode(buildAnalyzeMealBody(request));

/// Turns a raw `analyze-meal` answer into a result or a typed error. Status
/// codes are checked BEFORE the body is trusted: a 429/502 from the gateway
/// carries HTML, which used to surface as a `FormatException`.
MealAnalysisResult parseAnalyzeMealResponse(int statusCode, String body) =>
    MealAnalysisResult.fromEdgeFunction(
      readAnalyzeMealResult(statusCode, body),
    );

/// The `result` object of a 2xx `analyze-meal` answer, or the typed error of
/// [parseAnalyzeMealResponse]. Shared by the photo scan and the meal
/// description, which parse the object differently.
Map<String, dynamic> readAnalyzeMealResult(int statusCode, String body) {
  final decoded = _decodeLeniently(body);
  final code = decoded['error']?.toString();
  final message = decoded['message']?.toString();

  if (statusCode == 401 || statusCode == 403) {
    throw const MealAnalysisReauthRequired();
  }
  // Shared provider capacity can be exhausted while this user's photo quota
  // is still available. Preserve that code for the service-availability text.
  if (statusCode == 429 && code != 'ai_budget_exhausted') {
    throw MealAnalysisRateLimited(resetAt: _readResetAt(decoded));
  }
  if (statusCode == 413 ||
      code == 'image_too_large' ||
      code == 'payload_too_large') {
    throw const MealImageTooLarge();
  }
  if (statusCode < 200 || statusCode >= 300) {
    throw MealAnalysisServerError(
      statusCode: statusCode,
      code: code ?? 'http_$statusCode',
      debugMessage: message,
    );
  }

  final result = decoded['result'];
  if (result is! Map<String, dynamic>) {
    throw MealAnalysisServerError(
      statusCode: statusCode,
      code: 'invalid_result',
      debugMessage: 'result missing or not an object',
    );
  }
  return result;
}

Map<String, dynamic> _decodeLeniently(String body) {
  if (body.trim().isEmpty) return const <String, dynamic>{};
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } on FormatException {
    // HTML or plain text from the gateway: the status code carries the news.
  }
  return const <String, dynamic>{};
}

/// `rateLimit.resetAt` (429 body), else `rateLimit.user.resetAt`, else a
/// top-level `resetAt`.
DateTime? _readResetAt(Map<String, dynamic> decoded) {
  final rateLimit = decoded['rateLimit'];
  Object? raw;
  if (rateLimit is Map) {
    raw = rateLimit['resetAt'];
    final user = rateLimit['user'];
    if (raw == null && user is Map) raw = user['resetAt'];
  }
  raw ??= decoded['resetAt'];
  if (raw == null) return null;
  return DateTime.tryParse(raw.toString());
}

class EdgeFunctionMealAnalyzer implements MealAnalyzer {
  /// Seams for the loopback wire test (F4-05); production uses the defaults.
  /// [tokenProvider] null = current Supabase session; [clientFactory] null =
  /// [createHttpClient] with [policy].
  const EdgeFunctionMealAnalyzer({
    String baseUrl = EatovaSupabaseConfig.url,
    String anonKey = EatovaSupabaseConfig.anonKey,
    String? Function()? tokenProvider,
    HttpClient Function()? clientFactory,
    HttpTimeoutPolicy policy = HttpTimeoutPolicy.mealAnalysis,
  })  : _baseUrl = baseUrl,
        _anonKey = anonKey,
        _tokenProvider = tokenProvider,
        _clientFactory = clientFactory,
        _policy = policy;

  final String _baseUrl;
  final String _anonKey;
  final String? Function()? _tokenProvider;
  final HttpClient Function()? _clientFactory;
  final HttpTimeoutPolicy _policy;

  static const int _maxImageBytes = 5 * 1000 * 1000;

  // Explicit timeouts on EVERY phase: HttpTimeoutPolicy.mealAnalysis
  // (15 s connect / 60 s response / 15 s body) plus a 75 s ceiling over their
  // sum, calibrated against the function's own 55 s budget (P10-02b);
  // rationale lives with the policy in eatova_http.dart.

  AnalyzeMealTransport get _transport => AnalyzeMealTransport(
    baseUrl: _baseUrl,
    anonKey: _anonKey,
    tokenProvider: _tokenProvider,
    clientFactory: _clientFactory,
    policy: _policy,
  );

  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    final imageBytes = request.imageBytes;
    if (imageBytes == null || imageBytes.isEmpty) {
      // The fail-closed scrub could not read the picked photo. Named like the
      // server's own code, so the sheet blames the photo, not the connection.
      throw const MealAnalysisServerError(
        statusCode: 400,
        code: 'missing_image',
      );
    }
    if (imageBytes.length > _maxImageBytes) {
      throw const MealImageTooLarge();
    }

    return _transport.post(
      cancellation: request.cancellation,
      validate: () {
        if (!MealAnalysisRequest.isValidHint(request.freeTextHint)) {
          throw const MealAnalysisServerError(
            statusCode: 400,
            code: 'invalid_hint',
          );
        }
      },
      // Body built in an isolate; a stripped copy travels because the
      // cancellation hook's closures cannot cross the isolate boundary.
      encodeBody: () => compute(
        encodeAnalyzeMealBody,
        MealAnalysisRequest(
          imageId: request.imageId,
          imageBytes: request.imageBytes,
          freeTextHint: request.freeTextHint,
          language: request.language,
        ),
      ),
      parse: (response) =>
          parseAnalyzeMealResponse(response.statusCode, response.body),
    );
  }
}

/// The `analyze-meal` round trip the photo scan and the meal description
/// share: session token, one client per call with the [policy]'s phase
/// timeouts, the cancellation hook, the auth headers and the cancel-aware
/// error path. Each caller brings its own validation, body and parser.
class AnalyzeMealTransport {
  const AnalyzeMealTransport({
    required this.baseUrl,
    required this.anonKey,
    required this.policy,
    this.tokenProvider,
    this.clientFactory,
  });

  final String baseUrl;
  final String anonKey;
  final HttpTimeoutPolicy policy;

  /// Null = the current Supabase session.
  final String? Function()? tokenProvider;

  /// Null = [createHttpClient] with [policy].
  final HttpClient Function()? clientFactory;

  static const String functionPath = '/functions/v1/analyze-meal';

  String? _accessToken() {
    final provider = tokenProvider;
    if (provider != null) return provider();
    return Supabase.instance.client.auth.currentSession?.accessToken;
  }

  /// Checks cancellation and session, runs [validate], then POSTs the body of
  /// [encodeBody] and hands the answer to [parse]. [encodeBody] already runs
  /// with the client registered for cancellation. A cancelled call always
  /// ends in [MealAnalysisCancelled], whatever failed underneath.
  Future<T> post<T>({
    required Future<String> Function() encodeBody,
    required T Function(HttpTextResponse response) parse,
    MealAnalysisCancellation? cancellation,
    void Function()? validate,
    String operation = 'analyze-meal',
  }) async {
    if (cancellation?.isCancelled ?? false) {
      throw const MealAnalysisCancelled();
    }

    final accessToken = _accessToken();
    if (accessToken == null || accessToken.isEmpty) {
      throw const MealAnalysisReauthRequired();
    }

    validate?.call();
    final client = clientFactory?.call() ?? createHttpClient(policy);
    // A forced close aborts the socket; the pending request then fails with
    // a transport error, which the catch below renames to "cancelled".
    final unregister = cancellation?.register(() => client.close(force: true));
    try {
      final body = await encodeBody();
      if (cancellation?.isCancelled ?? false) {
        throw const MealAnalysisCancelled();
      }
      final uri = Uri.parse('$baseUrl$functionPath');
      final response = await sendTextRequest(
        client,
        method: 'POST',
        uri: uri,
        policy: policy,
        operation: operation,
        configure: (httpRequest) {
          httpRequest.headers.contentType = ContentType.json;
          httpRequest.headers.set('apikey', anonKey);
          httpRequest.headers.set('Authorization', 'Bearer $accessToken');
        },
        body: body,
      );
      if (cancellation?.isCancelled ?? false) {
        throw const MealAnalysisCancelled();
      }
      return parse(response);
    } on Object {
      if (cancellation?.isCancelled ?? false) {
        throw const MealAnalysisCancelled();
      }
      rethrow;
    } finally {
      unregister?.call();
      client.close(force: true);
    }
  }
}
