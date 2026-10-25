import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/plan_limit_hit.dart';
import '../models/recipe_import_result.dart';
import 'meal_scan_identity.dart';

enum RecipeImportFailure {
  invalidInput,

  /// More recipe content than one extraction can answer; a retry would fail
  /// the same way.
  sourceTooLong,
  reauthRequired,
  rateLimited,
  unavailable,
  timeout,
  network,
  invalidResponse,
}

class RecipeImportException implements Exception {
  const RecipeImportException(this.failure, {this.planLimit, this.resetAt});
  final RecipeImportFailure failure;

  /// A [RecipeImportFailure.rateLimited] by the account's daily tier quota
  /// (`planLimit`, docs/PREMIUM.md 3.3). The hourly and IP gates leave it
  /// null, so they never lead to an upgrade hint.
  final PlanLimitHit? planLimit;

  /// When a rate limit lifts: the body's `resetAt`, else `Retry-After`.
  final DateTime? resetAt;

  @override
  String toString() => 'RecipeImportException(${failure.name})';
}

abstract interface class RecipeImportService {
  Future<RecipeImportResult> extract(String text, {required String locale});
}

class EdgeFunctionRecipeImportService implements RecipeImportService {
  const EdgeFunctionRecipeImportService({
    String baseUrl = EatovaSupabaseConfig.url,
    String anonKey = EatovaSupabaseConfig.anonKey,
    String? Function()? tokenProvider,
    String? Function()? currentUserId,
    http.Client Function()? clientFactory,
    Duration timeout = const Duration(seconds: 65),
    GoTrueClient? auth,
  }) : _baseUrl = baseUrl,
       _anonKey = anonKey,
       _tokenProvider = tokenProvider,
       _currentUserId = currentUserId,
       _clientFactory = clientFactory,
       _timeout = timeout,
       _auth = auth;

  static const maxTextLength = 20000;
  static const maxResponseBytes = 256 * 1024;
  final String _baseUrl, _anonKey;
  final String? Function()? _tokenProvider, _currentUserId;
  final http.Client Function()? _clientFactory;
  final Duration _timeout;

  /// The session source when no [tokenProvider] is given; null is the app's.
  final GoTrueClient? _auth;

  /// A share usually opens the app from the background, where the SDK's
  /// token refresh only starts on resume. Sending the expired token would
  /// read as a lost login, so an expired session is refreshed first; if that
  /// fails, the request itself reports offline or reauthentication.
  Future<String?> _sessionToken() async {
    final auth = _auth ?? Supabase.instance.client.auth;
    if (auth.currentSession?.isExpired ?? false) {
      try {
        await auth.refreshSession();
      } on Object {
        // Keep the current token; the response maps the actual failure.
      }
    }
    return auth.currentSession?.accessToken;
  }

  @override
  Future<RecipeImportResult> extract(
    String text, {
    required String locale,
  }) async {
    final input = text.trim();
    if (input.isEmpty ||
        input.length > maxTextLength ||
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(input)) {
      throw const RecipeImportException(RecipeImportFailure.invalidInput);
    }
    final identity = MealScanIdentity(currentUserId: _currentUserId);
    String? token;
    try {
      token = _tokenProvider != null ? _tokenProvider() : await _sessionToken();
    } on Object {
      throw const RecipeImportException(RecipeImportFailure.reauthRequired);
    }
    if (token == null || token.isEmpty || !identity.isCurrent) {
      throw const RecipeImportException(RecipeImportFailure.reauthRequired);
    }
    final client = _clientFactory?.call() ?? http.Client();
    try {
      final request =
          http.Request(
              'POST',
              Uri.parse('$_baseUrl/functions/v1/recipe-import'),
            )
            ..followRedirects = false
            ..headers.addAll({
              'Content-Type': 'application/json',
              'apikey': _anonKey,
              'Authorization': 'Bearer $token',
            })
            ..body = jsonEncode({
              'text': input,
              'version': 2,
              'locale': locale == 'de' ? 'de' : 'en',
            });
      final response = await _read(client, request).timeout(_timeout);
      if (!identity.isCurrent) {
        throw const RecipeImportException(RecipeImportFailure.reauthRequired);
      }
      return parseRecipeImportResponse(
        response.$1,
        response.$2,
        retryAfter: response.$3,
      );
    } on RecipeImportException {
      rethrow;
    } on TimeoutException {
      throw const RecipeImportException(RecipeImportFailure.timeout);
    } on IOException {
      throw const RecipeImportException(RecipeImportFailure.network);
    } on http.ClientException {
      throw const RecipeImportException(RecipeImportFailure.network);
    } on FormatException {
      throw const RecipeImportException(RecipeImportFailure.invalidResponse);
    } finally {
      client.close();
    }
  }

  /// Status, body and the `Retry-After` header.
  Future<(int, String, String?)> _read(
    http.Client client,
    http.Request request,
  ) async {
    final response = await client.send(request);
    if ((response.contentLength ?? 0) > maxResponseBytes) {
      throw const RecipeImportException(RecipeImportFailure.invalidResponse);
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const RecipeImportException(RecipeImportFailure.invalidResponse);
      }
      bytes.addAll(chunk);
    }
    return (
      response.statusCode,
      utf8.decode(bytes),
      response.headers['retry-after'],
    );
  }
}

/// [retryAfter] is the raw `Retry-After` header: the reset time of a 429
/// whose body names none.
RecipeImportResult parseRecipeImportResponse(
  int status,
  String body, {
  String? retryAfter,
}) {
  if (status == 401 || status == 403) {
    throw const RecipeImportException(RecipeImportFailure.reauthRequired);
  }
  final error = status == 200 ? null : _errorBody(body);
  final code = error?['error'];
  if (status == 429) {
    // Shared provider capacity is not the user's import quota.
    if (code == 'ai_budget_exhausted') {
      throw const RecipeImportException(RecipeImportFailure.unavailable);
    }
    throw RecipeImportException(
      RecipeImportFailure.rateLimited,
      planLimit: PlanLimitHit.fromBody(error),
      resetAt: _resetAt(error?['resetAt'], retryAfter),
    );
  }
  if (status == 400 || status == 413 || status == 415) {
    throw const RecipeImportException(RecipeImportFailure.invalidInput);
  }
  if (status == 504) {
    throw const RecipeImportException(RecipeImportFailure.timeout);
  }
  if (status == 422 && code == 'source_too_long') {
    throw const RecipeImportException(RecipeImportFailure.sourceTooLong);
  }
  if (status == 502 && code == 'provider_invalid_response') {
    throw const RecipeImportException(RecipeImportFailure.invalidResponse);
  }
  if (status != 200) {
    throw const RecipeImportException(RecipeImportFailure.unavailable);
  }
  try {
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) throw const FormatException();
    return RecipeImportResult.fromJson(json);
  } on FormatException {
    throw const RecipeImportException(RecipeImportFailure.invalidResponse);
  }
}

/// A JSON error body; null for a gateway's HTML or text, where the status
/// alone has to speak.
Map<Object?, Object?>? _errorBody(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// The body's `resetAt`, else now plus the `Retry-After` seconds.
DateTime? _resetAt(Object? resetAt, String? retryAfter) {
  final named = resetAt is String ? DateTime.tryParse(resetAt)?.toUtc() : null;
  if (named != null) return named;
  final seconds = int.tryParse(retryAfter?.trim() ?? '');
  if (seconds == null || seconds < 0) return null;
  return clock.now().toUtc().add(Duration(seconds: seconds));
}
