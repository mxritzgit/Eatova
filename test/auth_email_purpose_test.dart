import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart' as supa;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/config/auth_email_purpose.dart';

void main() {
  test(
    'deletion and password reset request different per-mail purposes',
    () async {
      final requests = <http.Request>[];
      final client = supa.SupabaseClient(
        'https://ci.invalid',
        'test-anon-key',
        authOptions: const supa.AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: supa.AuthFlowType.implicit,
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/token')
                  ? {
                      'access_token': 'dummy-token',
                      'refresh_token': 'dummy-refresh',
                      'token_type': 'bearer',
                      'expires_in': 3600,
                      'user': {
                        'id': 'owner',
                        'aud': 'authenticated',
                        'email': 'owner@example.com',
                        'created_at': '2026-09-20T00:00:00Z',
                        'app_metadata': <String, dynamic>{},
                        'user_metadata': <String, dynamic>{},
                      },
                    }
                  : <String, dynamic>{},
            ),
            200,
            request: request,
            headers: {'Content-Type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final repo = SupabaseAuthRepository(client);
      await expectLater(
        repo.sendAccountDeletionCode(
          userId: 'owner',
          email: 'owner@example.com',
        ),
        throwsA(isA<supa.AuthException>()),
      );
      expect(
        requests,
        isEmpty,
        reason: 'No recovery email without the pinned owner.',
      );
      await client.auth.signInWithPassword(
        email: 'owner@example.com',
        password: 'dummy',
      );
      requests.clear();
      for (final identity in [
        ('other', 'owner@example.com'),
        ('owner', 'other@example.com'),
      ]) {
        await expectLater(
          repo.sendAccountDeletionCode(userId: identity.$1, email: identity.$2),
          throwsA(isA<supa.AuthException>()),
        );
      }
      expect(requests, isEmpty);
      await repo.sendAccountDeletionCode(
        userId: 'owner',
        email: ' owner@example.com ',
      );
      await repo.sendPasswordReset('reset@example.com');
      expect(requests.map((r) => r.url.path), everyElement('/auth/v1/recover'));
      expect(requests.map((r) => r.url.queryParameters['redirect_to']), [
        AuthEmailPurpose.accountDeletion,
        AuthEmailPurpose.passwordReset,
      ]);
      expect(jsonDecode(requests.first.body)['email'], 'owner@example.com');
      expect(jsonDecode(requests.last.body)['email'], 'reset@example.com');
      expect(
        requests.any((r) => r.method == 'PUT'),
        isFalse,
        reason: 'Purpose must never be stored in mutable user metadata.',
      );
    },
  );

  test('unavailable auth cannot promise an account deletion email', () async {
    await expectLater(
      const UnavailableAuthRepository(
        'offline',
      ).sendAccountDeletionCode(userId: 'owner', email: 'owner@example.com'),
      throwsA(isA<AuthUnavailableException>()),
    );
  });
}
