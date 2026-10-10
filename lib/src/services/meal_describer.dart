// Client of `analyze-meal` in describe mode. Contract: docs/MEAL-DESCRIBE.md.

import 'dart:convert';
import 'dart:io';

import '../config/supabase_config.dart';
import '../models/described_meal.dart';
import '../models/meal_analysis_request.dart';
import 'eatova_http.dart';
import 'meal_analyzer.dart';

/// Turns a typed or spoken meal description into [DescribedMeal].
///
/// Failures are the [MealAnalysisException] family of `meal_analyzer.dart`
/// (rate limit, re-auth, cancelled, server error with its code), so the UI
/// can name them like a failed photo scan. `no_food_in_text` arrives as a
/// `MealAnalysisServerError` with that code.
abstract class MealDescriber {
  /// Wire bounds of `mealText` after [normalizeMealText], in UTF-16 code
  /// units like the photo hint; a text outside them never leaves the device.
  static const int minTextLength = 2;
  static const int maxTextLength = 500;

  Future<DescribedMeal> describe(
    String text, {
    required String language,
    MealAnalysisCancellation? cancellation,
  });
}

/// Controls and bidi overrides/isolates, which the server strips as well.
final RegExp _unsafeTextCharacters = RegExp(
  r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\u{202A}-\u{202E}\u{2066}-\u{2069}]',
  unicode: true,
);

/// [raw] as the server will read it: unsafe characters removed, whitespace
/// (line breaks included) collapsed, trimmed.
String normalizeMealText(String raw) => raw
    .replaceAll(_unsafeTextCharacters, '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Whether [raw] is sendable once normalized.
bool isValidMealText(String raw) {
  final length = normalizeMealText(raw).length;
  return length >= MealDescriber.minTextLength &&
      length <= MealDescriber.maxTextLength;
}

/// The describe-mode body. Throws `invalid_meal_text` like the server would,
/// before a quota slot is spent on it.
Map<String, dynamic> buildDescribeMealBody(
  String text, {
  required String language,
}) {
  if (!isValidMealText(text)) {
    throw const MealAnalysisServerError(
      statusCode: 400,
      code: 'invalid_meal_text',
    );
  }
  return <String, dynamic>{
    'mealText': normalizeMealText(text),
    'language': language,
  };
}

/// [readAnalyzeMealResult] plus [DescribedMeal.fromJson]. A 2xx without a
/// usable item is an `invalid_result`, like a photo answer without a result.
DescribedMeal parseDescribeMealResponse(int statusCode, String body) {
  final result = readAnalyzeMealResult(statusCode, body);
  try {
    return DescribedMeal.fromJson(result);
  } on FormatException catch (error) {
    throw MealAnalysisServerError(
      statusCode: statusCode,
      code: 'invalid_result',
      debugMessage: error.message,
    );
  }
}

/// Production [MealDescriber]: the same HTTP client, auth, timeouts and error
/// mapping as `EdgeFunctionMealAnalyzer`, through [AnalyzeMealTransport].
class EdgeFunctionMealDescriber implements MealDescriber {
  /// Seams for the loopback wire test; production uses the defaults.
  /// [tokenProvider] null = current Supabase session; [clientFactory] null =
  /// [createHttpClient] with [policy]. The photo policy fits: the upload is
  /// tiny, but the answer waits on the same provider call and function budget.
  const EdgeFunctionMealDescriber({
    String baseUrl = EatovaSupabaseConfig.url,
    String anonKey = EatovaSupabaseConfig.anonKey,
    String? Function()? tokenProvider,
    HttpClient Function()? clientFactory,
    HttpTimeoutPolicy policy = HttpTimeoutPolicy.mealAnalysis,
  }) : _baseUrl = baseUrl,
       _anonKey = anonKey,
       _tokenProvider = tokenProvider,
       _clientFactory = clientFactory,
       _policy = policy;

  final String _baseUrl;
  final String _anonKey;
  final String? Function()? _tokenProvider;
  final HttpClient Function()? _clientFactory;
  final HttpTimeoutPolicy _policy;

  @override
  Future<DescribedMeal> describe(
    String text, {
    required String language,
    MealAnalysisCancellation? cancellation,
  }) {
    final transport = AnalyzeMealTransport(
      baseUrl: _baseUrl,
      anonKey: _anonKey,
      tokenProvider: _tokenProvider,
      clientFactory: _clientFactory,
      policy: _policy,
    );
    return transport.post(
      cancellation: cancellation,
      operation: 'analyze-meal.describe',
      validate: () => buildDescribeMealBody(text, language: language),
      encodeBody: () async =>
          jsonEncode(buildDescribeMealBody(text, language: language)),
      parse: (response) =>
          parseDescribeMealResponse(response.statusCode, response.body),
    );
  }
}
