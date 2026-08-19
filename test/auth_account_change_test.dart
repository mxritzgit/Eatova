import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
// http kommt transitiv ueber supabase_flutter (gotrue fusst darauf);
// depend_on_referenced_packages ist dafuer in analysis_options.yaml demotet.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart'
    show AuthClientOptions, AuthFlowType, SupabaseClient;

import 'package:eatova/src/auth/auth_repository.dart';

// Konto-Aenderungen aus der App heraus (2026-08-10):
//
//   * Passwort aendern  -> ein Code an die hinterlegte Adresse
//   * E-Mail aendern    -> je ein Code an die ALTE und die NEUE Adresse
//
// Beide Wege laufen ueber GoTrue-Bordmittel, nicht ueber selbstgebaute
// Token: `reauthenticate()` + `updateUser(nonce:)` fuer das Passwort,
// `updateUser(email:)` + zweimal `verifyOTP(emailChange)` fuer die Adresse.
// Serverseitig ist dafuer `mailer_secure_email_change_enabled` an (deshalb
// ZWEI Mails) und `security_update_password_require_reauthentication` an
// (deshalb ist der Code Pflicht und nicht Zierde) — s. supabase/AUTH_EMAIL_OTP.md.
//
// Die erste Haelfte dieser Datei prueft den Vertrag am
// [InMemoryAuthRepository]: die Attrappe ist das, was jeder Widget-Test der
// Einstellungen faehrt, sie muss sich also wie der Server verhalten.
//
// Review 2026-08-19, Befund 2: das allein war zu wenig. Die zentrale Zusage
// „erst NACH beiden Codes traegt das Konto die neue Adresse" war AUSSCHLIESSLICH
// in der Attrappe implementiert (`_offeneBestaetigungen`) — der Produktivpfad
// [SupabaseAuthRepository] hatte dafuer null Deckung, und die Attrappe kann per
// Konstruktion nicht beweisen, dass der echte Weg dieselbe Zusage haelt. Die
// zweite Haelfte schliesst das am WIRE-Format: echter
// [SupabaseAuthRepository] ueber einen echten [SupabaseClient] an einem
// [MockClient], der die GoTrue-Antworten der „sicheren E-Mail-Aenderung"
// nachstellt. Muster: `test/auth_enumeration_test.dart`,
// `test/delete_account_wire_test.dart`.

const Map<String, String> _jsonHeader = {'Content-Type': 'application/json'};

/// GoTrue-Nutzerzeile. [email] ist die AKTUELLE Adresse, [neueEmail] die
/// angefragte: bei aktiver „sicherer E-Mail-Aenderung" traegt der Server beide
/// nebeneinander, bis der ZWEITE Code da ist — genau das ist der Grund, warum
/// die App vorher nichts umschreiben darf.
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

/// Roher Supabase-Client am MockClient — wie in `auth_enumeration_test.dart`
/// bewusst `implicit` statt `pkce`: ohne `Supabase.initialize` gibt es keinen
/// PKCE-Storage, und `updateUser(email:)` wuerde am fehlenden Code-Verifier
/// scheitern statt am Testgegenstand. Am Wire-Format aendert das nichts.
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

  // --- Produktivpfad: SupabaseAuthRepository am Wire ------------------------

  group('E-Mail aendern (Wire, SupabaseAuthRepository)', () {
    /// Der komplette Server einer laufenden Adressaenderung. Der ERSTE
    /// `/verify` liefert bewusst nur die Nutzerzeile ohne `access_token` —
    /// so antwortet GoTrue bei `mailer_secure_email_change_enabled`, solange
    /// der zweite Code fehlt; erst der zweite Aufruf gibt eine Sitzung heraus.
    /// Genau an dieser Antwortform haengt die Zwei-Postfach-Zusage.
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

    /// Angemeldetes Repository am [transport] — `updateUser` verlangt eine
    /// bestehende Sitzung, sonst wirft GoTrue vor dem Testgegenstand.
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

      // Das Wire-Format, an dem die Zusage haengt: BEIDE Codes gehen als
      // `email_change` an denselben Endpunkt, unterschieden allein durch die
      // Adresse. Verrutscht der `type` (GoTrue kennt daneben `signup`,
      // `recovery`, `email`), verifiziert der Server einen anderen Vorgang —
      // die zweite Bestaetigung faende nie statt, und der Wechsel bliebe
      // entweder haengen oder haenge an nur EINEM Postfach.
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
          // Wortlaut und Status wie GoTrue bei abgelaufenem/falschem OTP.
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
      // Bewusst „kommt vorher nicht vor" statt „ist vorher immer die alte":
      // der Strom ist ein ReplaySubject und traegt am Anfang auch den
      // Sitzungsaufbau (initialSession/signedIn) — geprueft wird die Zusage,
      // nicht die Zahl der Ereignisse davor.
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
      // Die Gegenprobe (der Code laeuft als `nonce` in `PUT /user` mit) steht
      // in `test/auth_enumeration_test.dart`, zusammen mit dem
      // festgenagelten Nonce-Widerspruch aus dem Audit 2026-08-14.
    });
  });
}
