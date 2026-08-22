import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
// http arrives transitively via supabase_flutter; the
// depend_on_referenced_packages lint is demoted in analysis_options.yaml.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart'
    show AuthClientOptions, AuthFlowType, SupabaseClient;

import 'package:eatova/src/auth/auth_repository.dart';

// In-app account changes:
//
//   * change password -> one code to the stored address
//   * change email    -> one code each to the OLD and the NEW address
//
// Both use GoTrue built-ins, not hand-rolled tokens: `reauthenticate()` +
// `updateUser(nonce:)` for the password, `updateUser(email:)` plus two
// `verifyOTP(emailChange)` for the address. Server-side this needs
// `mailer_secure_email_change_enabled` (two mails) and
// `security_update_password_require_reauthentication` (code mandatory) —
// see supabase/AUTH_EMAIL_OTP.md.
//
// First half checks the contract on [InMemoryAuthRepository], the fake every
// settings widget test drives. Second half covers the production path at the
// WIRE level: real [SupabaseAuthRepository] over a real [SupabaseClient] on a
// [MockClient] replaying the secure-email-change responses — the fake alone
// cannot prove the real path keeps the same promise.

const Map<String, String> _jsonHeader = {'Content-Type': 'application/json'};

/// GoTrue user row. [email] is the CURRENT address, [neueEmail] the requested
/// one: with secure email change the server carries both until the SECOND
/// code arrives, which is why the app must not rewrite anything earlier.
Map<String, dynamic> _userJson({
  String email = 'alt@eatova.de',
  String? neueEmail,
}) => {
      'id': 'u1',
      'aud': 'authenticated',
      'created_at': '2026-08-19T10:00:00Z',
      'email': email,
      if (neueEmail != null) 'new_email': neueEmail,
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{'display_name': 'Moritz'},
    };

Map<String, dynamic> _sessionJson({String email = 'alt@eatova.de'}) => {
      'access_token': 'test-jwt',
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'test-refresh',
      'user': _userJson(email: email),
    };

/// Raw Supabase client on the MockClient. `implicit` instead of `pkce` on
/// purpose: without `Supabase.initialize` there is no PKCE storage, so
/// `updateUser(email:)` would fail on the missing verifier rather than on the
/// thing under test. The wire format is unaffected.
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
  group('Passwort aendern', () {
    test('fordert einen Code an die hinterlegte Adresse an', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startPasswordChange();

      expect(repo.reauthRequests, <String>['alt@eatova.de']);
    });

    test('setzt das Passwort NUR zusammen mit dem Code', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startPasswordChange();
      await repo.confirmPasswordChange(code: '123456', newPassword: 'geheim99');

      expect(repo.passwordUpdates, <String>['geheim99']);
      expect(repo.usedNonces, <String>['123456']);
    });

    test('ein falscher Code aendert nichts', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startPasswordChange();
      repo.verifyFails = true;

      await expectLater(
        repo.confirmPasswordChange(code: '000000', newPassword: 'geheim99'),
        throwsA(isA<Exception>()),
      );
      expect(repo.passwordUpdates, isEmpty,
          reason: 'ein abgelehnter Code darf kein Passwort setzen');
    });
  });

  group('E-Mail aendern', () {
    test('stoesst die Aenderung an und merkt sich die Zieladresse', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startEmailChange('neu@eatova.de');

      expect(repo.emailChangeRequests, <String>['neu@eatova.de']);
      expect(repo.currentUser?.email, 'alt@eatova.de',
          reason: 'vor der doppelten Bestaetigung aendert sich nichts');
    });

    test('erst NACH beiden Codes traegt das Konto die neue Adresse', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startEmailChange('neu@eatova.de');

      await repo.confirmEmailChange(email: 'alt@eatova.de', code: '111111');
      expect(repo.currentUser?.email, 'alt@eatova.de',
          reason: 'ein einzelner Code genuegt nicht — sonst reichte der '
              'Zugriff auf EIN Postfach');

      await repo.confirmEmailChange(email: 'neu@eatova.de', code: '222222');
      expect(repo.currentUser?.email, 'neu@eatova.de');
    });

    test('die Reihenfolge der beiden Codes ist egal', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startEmailChange('neu@eatova.de');
      await repo.confirmEmailChange(email: 'neu@eatova.de', code: '222222');
      expect(repo.currentUser?.email, 'alt@eatova.de');
      await repo.confirmEmailChange(email: 'alt@eatova.de', code: '111111');

      expect(repo.currentUser?.email, 'neu@eatova.de');
    });

    test('ein falscher Code laesst die Adresse stehen', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startEmailChange('neu@eatova.de');
      repo.verifyFails = true;

      await expectLater(
        repo.confirmEmailChange(email: 'alt@eatova.de', code: '000000'),
        throwsA(isA<Exception>()),
      );
      expect(repo.currentUser?.email, 'alt@eatova.de');
    });

    test('der Adresswechsel meldet sich am authStateChanges-Strom', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      final gesehen = <String?>[];
      final sub = repo.authStateChanges.listen((u) => gesehen.add(u?.email));

      await repo.startEmailChange('neu@eatova.de');
      await repo.confirmEmailChange(email: 'alt@eatova.de', code: '111111');
      await repo.confirmEmailChange(email: 'neu@eatova.de', code: '222222');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(gesehen.last, 'neu@eatova.de',
          reason: 'die Schale zeigt die Adresse in den Einstellungen an — '
              'sie muss den Wechsel mitbekommen');
    });
  });

  // --- Production path: SupabaseAuthRepository on the wire ------------------

  group('E-Mail aendern (Wire, SupabaseAuthRepository)', () {
    /// The whole server of an in-flight address change. The FIRST `/verify`
    /// returns only the user row without `access_token`, as GoTrue does under
    /// `mailer_secure_email_change_enabled` while the second code is missing;
    /// only the second call hands out a session. The two-mailbox promise
    /// hangs on exactly this response shape.
    MockClient serverMitZweiCodes({
      required List<Map<String, dynamic>> verifyKoerper,
      List<http.Request>? userAnfragen,
      List<Map<String, dynamic>>? userKoerper,
    }) {
      return MockClient((req) async {
        final pfad = req.url.path;
        if (pfad.endsWith('/token')) {
          return http.Response(jsonEncode(_sessionJson()), 200,
              headers: _jsonHeader);
        }
        if (pfad.endsWith('/user')) {
          userAnfragen?.add(req);
          userKoerper?.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(
              jsonEncode(_userJson(neueEmail: 'neu@eatova.de')), 200,
              headers: _jsonHeader);
        }
        if (pfad.endsWith('/verify')) {
          verifyKoerper.add(jsonDecode(req.body) as Map<String, dynamic>);
          if (verifyKoerper.length < 2) {
            return http.Response(
                jsonEncode(_userJson(neueEmail: 'neu@eatova.de')), 200,
                headers: _jsonHeader);
          }
          return http.Response(
              jsonEncode(_sessionJson(email: 'neu@eatova.de')), 200,
              headers: _jsonHeader);
        }
        return http.Response('{}', 200, headers: _jsonHeader);
      });
    }

    /// Signed-in repository on [transport]; `updateUser` needs an existing
    /// session or GoTrue throws before the thing under test.
    Future<SupabaseAuthRepository> angemeldetesRepo(MockClient transport) async {
      final client = _clientAm(transport);
      addTearDown(client.dispose);
      final repo = SupabaseAuthRepository(client);
      await repo.signIn(email: 'alt@eatova.de', password: 'eatova123');
      return repo;
    }

    test('stoesst die Aenderung an, ohne lokal etwas umzuschreiben', () async {
      final anfragen = <http.Request>[];
      final koerper = <Map<String, dynamic>>[];
      final repo = await angemeldetesRepo(serverMitZweiCodes(
        verifyKoerper: <Map<String, dynamic>>[],
        userAnfragen: anfragen,
        userKoerper: koerper,
      ));

      await repo.startEmailChange('  neu@eatova.de  ');

      expect(anfragen, hasLength(1));
      expect(anfragen.single.method, 'PUT');
      expect(koerper.single['email'], 'neu@eatova.de',
          reason: 'getrimmt, wie startEmailChange es zusagt');
      expect(koerper.single.containsKey('password'), isFalse,
          reason: 'ein Adresswechsel fasst das Passwort nicht an');
      expect(anfragen.single.url.queryParameters.containsKey('redirect_to'),
          isFalse,
          reason: 'BEWUSST ohne emailRedirectTo — ein redirect_to reaktivierte '
              'bei einem Server-Template-Rueckfall den kaperbaren '
              'eatova://-Deep-Link (Sicherheits-Audit 2026-08-09)');
      expect(repo.currentUser?.email, 'alt@eatova.de',
          reason: 'die Antwort traegt `new_email` neben `email` — wer daraus '
              'schon die neue Adresse anzeigt, behauptet einen Wechsel, den '
              'der Server noch gar nicht vollzogen hat');
    });

    test('erst NACH beiden Codes traegt das Konto die neue Adresse', () async {
      final verifys = <Map<String, dynamic>>[];
      final repo = await angemeldetesRepo(
          serverMitZweiCodes(verifyKoerper: verifys));

      await repo.startEmailChange('neu@eatova.de');
      expect(repo.currentUser?.email, 'alt@eatova.de');

      await repo.confirmEmailChange(email: 'alt@eatova.de', code: ' 11111111 ');
      expect(repo.currentUser?.email, 'alt@eatova.de',
          reason: 'ein einzelner Code genuegt nicht — sonst reichte der '
              'Zugriff auf EIN Postfach');

      await repo.confirmEmailChange(email: 'neu@eatova.de', code: '22222222');
      expect(repo.currentUser?.email, 'neu@eatova.de');

      // The wire format the promise hangs on: BOTH codes go to the same
      // endpoint as `email_change`, told apart only by the address. A wrong
      // `type` would verify a different operation, so the second confirmation
      // would never happen.
      expect(verifys.map((k) => k['type']), everyElement('email_change'));
      expect(verifys.first['email'], 'alt@eatova.de');
      expect(verifys.first['token'], '11111111',
          reason: 'getrimmt, wie confirmEmailChange es zusagt');
      expect(verifys.last['email'], 'neu@eatova.de');
      expect(verifys.last['token'], '22222222');
    });

    test('ein abgelehnter Code laesst die Adresse stehen', () async {
      final repo = await angemeldetesRepo(MockClient((req) async {
        final pfad = req.url.path;
        if (pfad.endsWith('/token')) {
          return http.Response(jsonEncode(_sessionJson()), 200,
              headers: _jsonHeader);
        }
        if (pfad.endsWith('/user')) {
          return http.Response(
              jsonEncode(_userJson(neueEmail: 'neu@eatova.de')), 200,
              headers: _jsonHeader);
        }
        if (pfad.endsWith('/verify')) {
          // Wording and status as GoTrue sends for an expired/wrong OTP.
          return http.Response(
              jsonEncode(<String, dynamic>{
                'error_code': 'otp_expired',
                'msg': 'Token has expired or is invalid',
              }),
              401,
              headers: _jsonHeader);
        }
        return http.Response('{}', 200, headers: _jsonHeader);
      }));

      await repo.startEmailChange('neu@eatova.de');
      await expectLater(
        repo.confirmEmailChange(email: 'alt@eatova.de', code: '00000000'),
        throwsA(isA<Exception>()),
      );

      expect(repo.currentUser?.email, 'alt@eatova.de',
          reason: 'der Fehler muss beim Aufrufer ankommen — schluckt ihn '
              'jemand, meldet die UI einen Wechsel, den es nicht gab');
    });

    test('der Adresswechsel meldet sich am authStateChanges-Strom', () async {
      final repo = await angemeldetesRepo(
          serverMitZweiCodes(verifyKoerper: <Map<String, dynamic>>[]));

      final gesehen = <String?>[];
      final sub = repo.authStateChanges.listen((u) => gesehen.add(u?.email));

      await repo.startEmailChange('neu@eatova.de');
      await repo.confirmEmailChange(email: 'alt@eatova.de', code: '11111111');
      await repo.confirmEmailChange(email: 'neu@eatova.de', code: '22222222');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(gesehen.last, 'neu@eatova.de',
          reason: 'die Schale zeigt die Adresse in den Einstellungen an — '
              'sie muss den Wechsel mitbekommen');
      // "Does not appear before" rather than "is always the old one": the
      // stream is a ReplaySubject and also carries the session setup, so the
      // promise is checked, not the number of preceding events.
      expect(gesehen.sublist(0, gesehen.length - 1),
          isNot(contains('neu@eatova.de')),
          reason: 'bis zum zweiten Code darf der Strom die neue Adresse nicht '
              'zeigen — die Einstellungen haetten den Wechsel sonst schon '
              'gemeldet, waehrend das zweite Postfach noch fehlt');
    });
  });

  group('Passwort aendern (Wire, SupabaseAuthRepository)', () {
    test('holt den Code ueber /reauthenticate — ohne Adress-Parameter',
        () async {
      final wege = <String>[];
      final kopfzeilen = <String?>[];
      final client = _clientAm(MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return http.Response(jsonEncode(_sessionJson()), 200,
              headers: _jsonHeader);
        }
        if (req.url.path.endsWith('/reauthenticate')) {
          wege.add('${req.method} ${req.url.path}');
          kopfzeilen.add(req.headers['Authorization']);
          expect(req.url.queryParameters.containsKey('email'), isFalse);
          return http.Response('{}', 200, headers: _jsonHeader);
        }
        return http.Response('{}', 200, headers: _jsonHeader);
      }));
      addTearDown(client.dispose);

      final repo = SupabaseAuthRepository(client);
      await repo.signIn(email: 'alt@eatova.de', password: 'eatova123');
      await repo.startPasswordChange();

      expect(wege, hasLength(1));
      expect(wege.single, endsWith(' /auth/v1/reauthenticate'));
      expect(wege.single, startsWith('GET '));
      expect(kopfzeilen.single, 'Bearer test-jwt',
          reason: 'die Empfaengeradresse zieht der Server aus dem Token — die '
              'App kann hier kein fremdes Postfach adressieren, und genau '
              'deshalb ist der Code ueberhaupt eine Huerde');
      // The counterpart (the code travels as `nonce` in `PUT /user`) lives in
      // `test/auth_enumeration_test.dart`.
    });
  });
}
