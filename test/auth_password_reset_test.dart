import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart' hide AuthException;
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/config/supabase_config.dart';

// „Passwort vergessen" (2026-08-08): der Sign-in bekommt einen Reset-Weg.
//
// Kontrakt der Repository-Schicht:
//  * [AuthRepository.sendPasswordReset] stoesst die Recovery-Mail an
//    (GoTrue /auth/v1/recover) und traegt den App-Deep-Link als redirect_to,
//    damit der Mail-Link zurueck in die App fuehrt (dort loest
//    supabase_flutter das passwordRecovery-Event aus).
//  * Die UI zeigt IMMER eine neutrale Bestaetigung — ob die Mail existiert
//    (oder ein reines Google-Konto ist), verraet weder Server noch App:
//    alles andere waere ein Konto-Enumerations-Leck.
//  * [UnavailableAuthRepository] scheitert LAUT (wie signIn), statt still
//    eine Mail zu versprechen, die nie rausgeht.

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
      // implicit statt pkce: der rohe Test-Client hat keinen PKCE-Storage
      // (in Produktion liefert SecurePkceAsyncStorage ihn via
      // Supabase.initialize); am /recover-Wire-Format aendert das nichts.
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
    expect(captured!.url.queryParameters['redirect_to'],
        EatovaSupabaseConfig.oauthRedirectUrl,
        reason: 'der Mail-Link muss zurueck in die App fuehren, sonst landet '
            'der Nutzer auf einer leeren Supabase-Seite');
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
