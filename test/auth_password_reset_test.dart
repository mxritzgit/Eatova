import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart' hide AuthException;
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/config/supabase_config.dart';

// Password reset contract of the repository layer:
//  * [AuthRepository.sendPasswordReset] triggers the recovery mail
//    (GoTrue /auth/v1/recover).
//  * The UI always shows a neutral confirmation — neither server nor app
//    reveals whether the address exists (account enumeration).
//  * [UnavailableAuthRepository] fails LOUDLY instead of silently promising a
//    mail that never goes out.

void main() {
  test('sendPasswordReset ruft /auth/v1/recover mit App-Redirect auf',
      () async {
    http.Request? captured;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response('{}', 200,
            headers: const {'Content-Type': 'application/json'});
      }),
      // implicit instead of pkce: the raw test client has no PKCE storage.
      // The /recover wire format is unaffected.
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );
    addTearDown(client.dispose);

    await SupabaseAuthRepository(client)
        .sendPasswordReset('  user@example.com ');

    expect(captured, isNotNull);
    expect(captured!.url.path, contains('/auth/v1/recover'));
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['email'], 'user@example.com',
        reason: 'getrimmt wie bei signIn');
    // NO redirect_to: the reset runs through the 8-digit code. One would
    // reactivate the hijackable eatova:// deep-link path if the server
    // template ever fell back to {{ .ConfirmationURL }}.
    expect(captured!.url.queryParameters.containsKey('redirect_to'), isFalse,
        reason: 'kein Deep-Link im Reset — nur der Code');
    expect(captured!.body.contains(EatovaSupabaseConfig.oauthRedirectUrl),
        isFalse);
  });

  test('UnavailableAuthRepository scheitert laut statt still zu versprechen',
      () async {
    await expectLater(
      const UnavailableAuthRepository('kaputt')
          .sendPasswordReset('user@example.com'),
      throwsA(isA<AuthException>()),
    );
  });

  test('PreviewAuthRepository bleibt ein gefahrloses No-Op', () async {
    await expectLater(
      const PreviewAuthRepository().sendPasswordReset('user@example.com'),
      completes,
    );
  });
}
