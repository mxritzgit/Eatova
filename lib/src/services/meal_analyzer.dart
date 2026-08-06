import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/meal_analysis_request.dart';
import '../models/meal_analysis_result.dart';

abstract class MealAnalyzer {
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request);
}

class EdgeFunctionMealAnalyzer implements MealAnalyzer {
  const EdgeFunctionMealAnalyzer();

  static const String _supabaseUrl = EatovaSupabaseConfig.url;
  static const String _supabaseAnonKey = EatovaSupabaseConfig.anonKey;
  static const String _functionPath = '/functions/v1/analyze-meal';
  static const int _maxImageBytes = 5 * 1000 * 1000;

  // Explizite Timeouts auf JEDER Phase (Muster aus MeilisearchProductService):
  // connectionTimeout deckt nur den TCP-Aufbau — haengt der LLM-Provider hinter
  // der Edge Function, wuerde close() sonst endlos warten und der Spinner
  // draehte fuer immer. Grosszuegig bemessen, weil im close() der komplette
  // Upload + die LLM-Antwortzeit steckt (Edge Function bricht ihrerseits nach
  // 45 s ab — der Client haelt bewusst laenger durch als der Server).
  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _responseTimeout = Duration(seconds: 60);
  static const Duration _bodyTimeout = Duration(seconds: 15);

  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    final imageBytes = request.imageBytes;
    if (imageBytes == null || imageBytes.isEmpty) {
      throw const FormatException('No image bytes available for analysis.');
    }
    if (imageBytes.length > _maxImageBytes) {
      throw const FormatException(
        'Das Bild ist zu groß. Bitte ein kleineres Foto auswählen.',
      );
    }

    final session = Supabase.instance.client.auth.currentSession;
    final accessToken = session?.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw const AuthException(
        'Bitte erneut anmelden, bevor du ein Foto analysierst.',
      );
    }

    final freeTextHint = _cleanHint(request.freeTextHint);
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    try {
      final uri = Uri.parse('$_supabaseUrl$_functionPath');
      final httpRequest = await client.postUrl(uri).timeout(_connectTimeout);
      httpRequest.headers.contentType = ContentType.json;
      httpRequest.headers.set('apikey', _supabaseAnonKey);
      httpRequest.headers.set('Authorization', 'Bearer $accessToken');
      httpRequest.write(
        jsonEncode({
          'imageBase64': base64Encode(imageBytes),
          'portionHint': request.portionHint?.name ?? MealPortionHint.normal.name,
          if (freeTextHint != null) 'freeTextHint': freeTextHint,
        }),
      );

      final response = await httpRequest.close().timeout(_responseTimeout);
      final responseBody =
          await response.transform(utf8.decoder).join().timeout(_bodyTimeout);
      final decoded = _decodeResponse(responseBody);

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const AuthException(
          'Bitte erneut anmelden, bevor du ein Foto analysierst.',
        );
      }
      if (response.statusCode == 429) {
        throw const HttpException(
          'Zu viele Foto-Analysen. Bitte später erneut versuchen.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded['message']?.toString() ??
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
