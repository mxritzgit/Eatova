import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../l10n/l10n.dart';
import '../models/meal_analysis_request.dart';
import '../models/meal_analysis_result.dart';
import 'eatova_http.dart';

abstract class MealAnalyzer {
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request);
}

/// Bundle for [request] — `'en'` -> English, anything else German. Mirrors the
/// server default (`analyze-meal/index.ts`, `normalizeLanguage`).
AppLocalizations _l10nForRequest(MealAnalysisRequest request) =>
    request.language == 'en' ? enL10n : deL10n;

/// Builds the JSON body for the `analyze-meal` function. Split off from HTTP so
/// `language`/`portionHint`/`freeTextHint` are testable without a network fake.
Map<String, dynamic> buildAnalyzeMealBody(MealAnalysisRequest request) {
  final imageBytes = request.imageBytes;
  final hint = EdgeFunctionMealAnalyzer._cleanHint(request.freeTextHint);
  return <String, dynamic>{
    if (imageBytes != null) 'imageBase64': base64Encode(imageBytes),
    'portionHint': request.portionHint?.name ?? MealPortionHint.normal.name,
    if (hint != null) 'freeTextHint': hint,
    'language': request.language,
  };
}

class EdgeFunctionMealAnalyzer implements MealAnalyzer {
  const EdgeFunctionMealAnalyzer();

  static const String _supabaseUrl = EatovaSupabaseConfig.url;
  static const String _supabaseAnonKey = EatovaSupabaseConfig.anonKey;
  static const String _functionPath = '/functions/v1/analyze-meal';
  static const int _maxImageBytes = 5 * 1000 * 1000;

  // Explicit timeouts on EVERY phase: HttpTimeoutPolicy.mealAnalysis
  // (15 s connect / 60 s response / 15 s body); rationale lives with the
  // policy in eatova_http.dart.

  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    final l10n = _l10nForRequest(request);
    final imageBytes = request.imageBytes;
    if (imageBytes == null || imageBytes.isEmpty) {
      throw const FormatException('No image bytes available for analysis.');
    }
    if (imageBytes.length > _maxImageBytes) {
      throw FormatException(l10n.foodImageTooLargeError);
    }

    final session = Supabase.instance.client.auth.currentSession;
    final accessToken = session?.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw AuthException(l10n.foodReauthRequiredError);
    }

    final client = createHttpClient(HttpTimeoutPolicy.mealAnalysis);
    try {
      final uri = Uri.parse('$_supabaseUrl$_functionPath');
      final response = await sendTextRequest(
        client,
        method: 'POST',
        uri: uri,
        policy: HttpTimeoutPolicy.mealAnalysis,
        operation: 'analyze-meal',
        configure: (httpRequest) {
          httpRequest.headers.contentType = ContentType.json;
          httpRequest.headers.set('apikey', _supabaseAnonKey);
          httpRequest.headers.set('Authorization', 'Bearer $accessToken');
        },
        body: jsonEncode(buildAnalyzeMealBody(request)),
      );
      final decoded = _decodeResponse(response.body);

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw AuthException(l10n.foodReauthRequiredError);
      }
      if (response.statusCode == 429) {
        throw HttpException(l10n.foodAnalysisRateLimitError);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message =
            decoded['message']?.toString() ??
            'Meal analysis failed with HTTP ${response.statusCode}.';
        throw HttpException(message);
      }

      final result = decoded['result'];
      if (result is! Map<String, dynamic>) {
        throw const FormatException('Unexpected analysis response.');
      }

      return MealAnalysisResult.fromEdgeFunction(result);
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, dynamic> _decodeResponse(String body) {
    if (body.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return const <String, dynamic>{};
  }

  static String? _cleanHint(String? raw) {
    final trimmed = raw?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.length <= 400 ? trimmed : trimmed.substring(0, 400);
  }
}
