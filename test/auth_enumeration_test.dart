import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart' hide AuthException;
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/account_change_messages.dart';

// Account enumeration and what `signUp` used to hide (Audit 2026-08-14):
//
//  * The email change confirmed account existence verbatim, contradicting the
//    line the password reset defends.
//  * `signUp` returned `Future<void>` and dropped the `AuthResponse`, which is
//    where GoTrue signals a taken address: success status, EMPTY `identities`,
//    no mail.
//  * Plus the unresolved nonce contradiction — only pinned here, not changed.

const Map<String, String> _jsonHeader = {'Content-Type': 'application/json'};

Map<String, dynamic> _userJson({List<Map<String, dynamic>>? identities}) => {
      'id': 'user-1',
      'aud': 'authenticated',
      'created_at': '2026-08-14T10:00:00Z',
      'email': 'neu@eatova.de',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{'display_name': 'Moritz'},
      if (identities != null) 'identities': identities,
    };

Map<String, dynamic> _sessionJson() => {
      'access_token': 'test-jwt',
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'test-refresh',
      'user': _userJson(),
    };

/// Raw Supabase client on a MockClient. `implicit` rather than `pkce` because
/// without `Supabase.initialize` there is no PKCE storage; the wire format of
/// the calls checked here is unaffected.
SupabaseClient _clientAm(MockClient transport) => SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );

void main() {
  group('Kontoenumeration', () {
    // Every phrasing GoTrue uses to report a taken address.
    const belegtMeldungen = <String>[
      'A user with this email address has already been registered',
      'User already registered',
      'email_exists',
      'Email address already in use',
    ];

    // The ASSERTING phrasings, in both languages; none may appear in a user
    // message. Bare "exists" is not listed: in the conditional form it asserts
    // nothing, and that form is the intended one.
    const verraeter = <String>[
      'bereits verwendet',
      'bereits vergeben',
      'schon registriert',
      'already registered',
      'already in use',
      'is already',
    ];

    test('der Adresswechsel bestaetigt keine fremde Kontoexistenz', () {
      for (final rohtext in belegtMeldungen) {
        final fehler = AuthException(rohtext);
        final de = accountChangeErrorMessage(fehler);
        final en = accountChangeErrorMessage(fehler, enL10n);

        expect(de, deL10n.settingsAccountEmailNotAvailable, reason: rohtext);
        expect(en, enL10n.settingsAccountEmailNotAvailable, reason: rohtext);

        for (final wort in verraeter) {
          expect(de.toLowerCase(), isNot(contains(wort)), reason: rohtext);
          expect(en.toLowerCase(), isNot(contains(wort)), reason: rohtext);
        }
      }
    });

    test('die Meldung laesst den Nutzer trotzdem nicht im Regen stehen', () {
      // Conditional rather than asserting, and with the way out that exists in
      // BOTH cases.
      expect(deL10n.settingsAccountEmailNotAvailable.toLowerCase(),
          contains('falls'));
      expect(enL10n.settingsAccountEmailNotAvailable.toLowerCase(),
          contains('if an account'));
      expect(deL10n.settingsAccountEmailNotAvailable,
          isNot(deL10n.commonGenericRetryError),
          reason: 'neutral heisst nicht nichtssagend');
    });
  });

  group('signUp meldet den Existenzfall zurueck', () {
    test('leeres identities-Array => emailAlreadyRegistered', () async {
      final client = _clientAm(MockClient((req) async => http.Response(
            jsonEncode(_userJson(identities: const [])),
            200,
            headers: _jsonHeader,
          )));
      addTearDown(client.dispose);

      final ergebnis = await SupabaseAuthRepository(client).signUp(
        email: 'schon@eatova.de',
        password: 'eatova123',
        displayName: 'Moritz',
      );

      expect(ergebnis, SignUpOutcome.emailAlreadyRegistered,
          reason: 'sonst verspricht die UI einen Code, der nie kommt');
    });

    test('gefuelltes identities-Array => created', () async {
      final client = _clientAm(MockClient((req) async => http.Response(
            jsonEncode(_userJson(identities: [
              {
                'id': 'ident-1',
                'user_id': 'user-1',
                'identity_id': 'ident-1',
                'provider': 'email',
                'identity_data': <String, dynamic>{'email': 'neu@eatova.de'},
              }
            ])),
            200,
            headers: _jsonHeader,
          )));
      addTearDown(client.dispose);

      final ergebnis = await SupabaseAuthRepository(client).signUp(
        email: 'neu@eatova.de',
        password: 'eatova123',
        displayName: 'Moritz',
      );

      expect(ergebnis, SignUpOutcome.created);
    });

    test('fehlendes identities-Feld gilt als frische Registrierung', () async {
      final client = _clientAm(MockClient((req) async => http.Response(
            jsonEncode(_userJson()),
            200,
            headers: _jsonHeader,
          )));
      addTearDown(client.dispose);

      final ergebnis = await SupabaseAuthRepository(client).signUp(
        email: 'neu@eatova.de',
        password: 'eatova123',
        displayName: 'Moritz',
      );

      expect(ergebnis, SignUpOutcome.created,
          reason: 'aus einer Wissensluecke keine Aussage ueber ein Konto');
    });

    test('das Test-Double unterscheidet denselben Fall', () async {
      final repo = InMemoryAuthRepository();
      addTearDown(repo.dispose);
      repo.existingEmails.add('schon@eatova.de');

      expect(
        await repo.signUp(
            email: 'schon@eatova.de',
            password: 'eatova123',
            displayName: 'Moritz'),
        SignUpOutcome.emailAlreadyRegistered,
      );
      expect(repo.currentUser, isNull,
          reason: 'kein Konto angelegt, keine Sitzung — wie bei GoTrue');

      expect(
        await repo.signUp(
            email: 'neu@eatova.de',
            password: 'eatova123',
            displayName: 'Moritz'),
        SignUpOutcome.created,
      );
      expect(repo.currentUser?.email, 'neu@eatova.de');
    });
  });

  // FINDING B: not changed, only pinned. Which branch is wrong depends on live
  // GoTrue behaviour (see
  // `.superpowers/sdd/audit-2026-08-14/reports/auth-repo-hygiene.md`). This
  // test fails as soon as someone aligns one side, and the clarification then
  // belongs in the same commit.
  group('Nonce: heutiges Wire-Verhalten', () {
    test('Recovery setzt ohne Nonce, die Einstellungen mit', () async {
      final koerper = <Map<String, dynamic>>[];
      final client = _clientAm(MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return http.Response(jsonEncode(_sessionJson()), 200,
              headers: _jsonHeader);
        }
        if (req.url.path.endsWith('/user')) {
          expect(req.method, 'PUT');
          koerper.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(jsonEncode(_userJson()), 200,
              headers: _jsonHeader);
        }
        return http.Response('{}', 200, headers: _jsonHeader);
      }));
      addTearDown(client.dispose);

      final repo = SupabaseAuthRepository(client);
      // Session as after `verifyRecoveryCode`: fresh and carrying no nonce.
      await repo.signIn(email: 'user@eatova.de', password: 'eatova123');

      await repo.updatePassword('neues-passwort');
      await repo.confirmPasswordChange(
          code: ' 123456 ', newPassword: 'neues-passwort');

      expect(koerper, hasLength(2));
      expect(koerper.first['password'], 'neues-passwort');
      expect(koerper.first.containsKey('nonce'), isFalse,
          reason: 'der Recovery-Abschluss hat keinen Code zur Hand — verlangt '
              'GoTrue ihn hier, ist „Passwort vergessen" eine Sackgasse');
      expect(koerper.last['nonce'], '123456',
          reason: 'getrimmt, wie confirmPasswordChange es zusagt');
    });
  });
}
