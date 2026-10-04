import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const emptyResult =
    '{"status":"needs_text","source":{"url":null},"candidates":[]}';

Matcher failure(RecipeImportFailure kind) =>
    isA<RecipeImportException>().having((e) => e.failure, 'failure', kind);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'accepts actual synthetic backend handler responses across the wire',
    () {
      String fixture(String name) =>
          File('test/fixtures/recipe_import/$name.json').readAsStringSync();
      final fractional = parseRecipeImportResponse(200, fixture('decimal'));
      expect(fractional.candidates.single.caloriesKcal, 451);
      expect(fractional.candidates.single.proteinG, 21);
      final missing = parseRecipeImportResponse(200, fixture('missing'));
      expect(missing.candidates.single.hasNutrition, isFalse);
      expect(
        parseRecipeImportResponse(200, fixture('unavailable')).status,
        RecipeImportStatus.needsText,
      );
    },
  );

  EdgeFunctionRecipeImportService service(
    http.Client client, {
    String? Function()? token,
    String? Function()? owner,
    Duration timeout = const Duration(seconds: 65),
  }) => EdgeFunctionRecipeImportService(
    baseUrl: 'https://ci.invalid',
    anonKey: 'ci-dummy-key',
    tokenProvider: token ?? () => 'synthetic-token',
    currentUserId: owner ?? () => 'user-a',
    clientFactory: () => client,
    timeout: timeout,
  );

  test(
    'uses authenticated bounded text and forbids token-bearing redirects',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://ci.invalid/functions/v1/recipe-import',
        );
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer synthetic-token');
        expect(jsonDecode(request.body), {
          'text': 'recipe caption',
          'version': 2,
          'locale': 'de',
        });
        return http.Response(emptyResult, 200);
      });
      expect(
        (await service(
          client,
        ).extract('  recipe caption ', locale: 'de')).status,
        RecipeImportStatus.needsText,
      );
    },
  );

  test('invalid input and missing auth never contact backend', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(emptyResult, 200);
    });
    for (final text in ['', 'x' * 20001, 'recipe\u0000caption']) {
      await expectLater(
        service(client).extract(text, locale: 'en'),
        throwsA(failure(RecipeImportFailure.invalidInput)),
      );
    }
    await expectLater(
      service(client, token: () => null).extract('recipe', locale: 'en'),
      throwsA(failure(RecipeImportFailure.reauthRequired)),
    );
    expect(calls, 0);
  });

  test('discards successful late reply after account switch', () async {
    var owner = 'a';
    final response = Completer<http.Response>();
    final sent = Completer<void>();
    final pending = service(
      MockClient((_) {
        sent.complete();
        return response.future;
      }),
      owner: () => owner,
    ).extract('caption', locale: 'en');
    final assertion = expectLater(
      pending,
      throwsA(failure(RecipeImportFailure.reauthRequired)),
    );
    await sent.future;
    owner = 'b';
    response.complete(http.Response(emptyResult, 200));
    await assertion;
  });

  test('sanitizes gateway and provider failures', () {
    for (final pair in [
      (401, RecipeImportFailure.reauthRequired),
      (403, RecipeImportFailure.reauthRequired),
      (429, RecipeImportFailure.rateLimited),
      (413, RecipeImportFailure.invalidInput),
      (503, RecipeImportFailure.unavailable),
      (504, RecipeImportFailure.timeout),
      (302, RecipeImportFailure.unavailable),
    ]) {
      expect(
        () => parseRecipeImportResponse(
          pair.$1,
          '<html>private diagnostics</html>',
        ),
        throwsA(failure(pair.$2)),
      );
    }
    expect(
      () => parseRecipeImportResponse(200, '{broken'),
      throwsA(failure(RecipeImportFailure.invalidResponse)),
    );
  });

  test('enforces response byte cap and whole request deadline', () async {
    await expectLater(
      service(
        MockClient((_) async => http.Response('x' * (256 * 1024 + 1), 200)),
      ).extract('caption', locale: 'en'),
      throwsA(failure(RecipeImportFailure.invalidResponse)),
    );
    final response = Completer<http.Response>();
    final pending = service(
      MockClient((_) => response.future),
      timeout: const Duration(milliseconds: 10),
    ).extract('caption', locale: 'en');
    await expectLater(pending, throwsA(failure(RecipeImportFailure.timeout)));
    response.complete(http.Response(emptyResult, 200));
  });

  test('refreshes an expired session before sending its token', () async {
    // A share resumes the app while the SDK's own refresh is still running:
    // the stored access token has expired, the refresh token is valid.
    String jwt(int exp) {
      String part(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      return '${part({'alg': 'HS256'})}.'
          '${part({'sub': 'user-a', 'session_id': 's1', 'exp': exp})}.sig';
    }

    Map<String, dynamic> session(String token, String refresh) => {
      'access_token': token,
      'refresh_token': refresh,
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': 'user-a',
        'aud': 'authenticated',
        'created_at': '2026-09-20T00:00:00Z',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
      },
    };
    final expired = jwt(1);
    final fresh = jwt(4102444800);
    final authTransport = MockClient((request) async {
      expect(request.url.path, '/auth/v1/token');
      expect(request.url.queryParameters['grant_type'], 'refresh_token');
      return http.Response(
        jsonEncode(session(fresh, 'refresh-2')),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final supabase = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: authTransport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(supabase.dispose);
    await supabase.auth.setInitialSession(
      jsonEncode(session(expired, 'refresh-1')),
    );
    expect(supabase.auth.currentSession!.isExpired, isTrue);

    final sent = <String?>[];
    final result = await EdgeFunctionRecipeImportService(
      baseUrl: 'https://ci.invalid',
      anonKey: 'ci-dummy-key',
      auth: supabase.auth,
      currentUserId: () => 'user-a',
      clientFactory: () => MockClient((request) async {
        sent.add(request.headers['Authorization']);
        return http.Response(emptyResult, 200);
      }),
    ).extract('caption', locale: 'en');

    expect(result.status, RecipeImportStatus.needsText);
    expect(sent, ['Bearer $fresh']);
  });
}
