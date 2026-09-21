import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/recipe_import_result.dart';
import 'meal_scan_identity.dart';

enum RecipeImportFailure {
  invalidInput,
  reauthRequired,
  rateLimited,
  unavailable,
  timeout,
  network,
  invalidResponse,
}

class RecipeImportException implements Exception {
  const RecipeImportException(this.failure);
  final RecipeImportFailure failure;

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
  }) : _baseUrl = baseUrl,
       _anonKey = anonKey,
       _tokenProvider = tokenProvider,
       _currentUserId = currentUserId,
       _clientFactory = clientFactory,
       _timeout = timeout;

  static const maxTextLength = 20000;
  static const maxResponseBytes = 256 * 1024;
  final String _baseUrl, _anonKey;
  final String? Function()? _tokenProvider, _currentUserId;
  final http.Client Function()? _clientFactory;
  final Duration _timeout;

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
      token = _tokenProvider != null
          ? _tokenProvider()
          : Supabase.instance.client.auth.currentSession?.accessToken;
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
              'locale': locale == 'de' ? 'de' : 'en',
            });
      final response = await _read(client, request).timeout(_timeout);
      if (!identity.isCurrent) {
        throw const RecipeImportException(RecipeImportFailure.reauthRequired);
      }
      return parseRecipeImportResponse(response.$1, response.$2);
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

  Future<(int, String)> _read(http.Client client, http.Request request) async {
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
    return (response.statusCode, utf8.decode(bytes));
  }
}

RecipeImportResult parseRecipeImportResponse(int status, String body) {
  if (status == 401 || status == 403) {
    throw const RecipeImportException(RecipeImportFailure.reauthRequired);
  }
  if (status == 429) {
    throw const RecipeImportException(RecipeImportFailure.rateLimited);
  }
  if (status == 400 || status == 413 || status == 415) {
    throw const RecipeImportException(RecipeImportFailure.invalidInput);
  }
  if (status == 504) {
    throw const RecipeImportException(RecipeImportFailure.timeout);
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
