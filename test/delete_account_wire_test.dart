import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// http kommt transitiv ueber supabase_flutter (postgrest/gotrue fussen darauf);
// depend_on_referenced_packages ist dafuer in analysis_options.yaml demotet.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart'
    show AuthClientOptions, AuthFlowType, PostgrestException, SupabaseClient;

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Die SERVERSEITIGE Re-Auth-Pflicht der Kontoloeschung (Nachpruefung
// 2026-08-15, Befund 1) — Migration
// `supabase/migrations/20260815120000_delete_account_reauth.sql`.
//
// Die Migration verlangt ein JWT, dessen `amr`-Claim einen 'otp'/'recovery'-
// Eintrag aus den letzten 5 Minuten traegt. Dass der legitime In-App-Flow das
// erfuellt, ist keine Absicht des App-Codes, sondern eine ANNAHME ueber zwei
// Fremdbibliotheken:
//
//   * gotrue speichert die bei `verifyOTP` zurueckgegebene NEUE Session
//     (`gotrue_client.dart`, `_saveSession`),
//   * der SupabaseClient holt das Access-Token PRO REQUEST aus genau dieser
//     Session (`supabase_client.dart`, `_getAccessToken`).
//
// Faellt eine der beiden weg — etwa weil ein Paket-Upgrade das Token cached —,
// traegt der Loesch-RPC das alte Login-Token, und die Kontoloeschung bricht im
// Feld mit EX_REAUTH_REQUIRED. Gruppe (a) haelt genau diese Annahme am
// Wire-Format fest; sie ist der Vertrag, auf dem die Migration steht.
//
// Gruppe (b) fuehrt die Server-Ablehnung durch den echten Postgrest-Parser
// (403 + Fehler-Body -> PostgrestException -> [isReauthRequiredError] ->
// [deleteAccountErrorMessage]) und (c) durch den Store, der daraufhin NICHTS
// raeumen darf: das Konto existiert ja noch.
//
// Die UI-Haelfte (Wort-Huerde, Code-Schritt, abgelehnter Code) liegt
// unveraendert in `test/delete_account_reauth_test.dart`.
// Muster fuer MockClient/`_clientAm`/`_sessionJson`:
// `test/auth_enumeration_test.dart`.

const Map<String, String> _jsonHeader = {'Content-Type': 'application/json'};

/// `request:` ist Pflicht, nicht Kosmetik: `PostgrestBuilder._parseResponse`
/// greift ungeprueft auf `response.request!` zu (postgrest 2.9.1, Z. 462 im
/// Erfolgs- und Z. 551 im Fehlerzweig). Echte HTTP-Clients setzen das Feld
/// selbst (`IOClient.send`), `MockClient` reicht dagegen nur durch, was der
/// Handler mitgibt — fehlt es, scheitert JEDER RPC im Test an einem
/// TypeError, noch bevor die `PostgrestException` entsteht. Hausmuster,
/// siehe `test/coach_quota_unbekannt_test.dart`.
http.Response _json(http.Request req, Object? koerper, {int status = 200}) =>
    http.Response(jsonEncode(koerper), status,
        request: req, headers: _jsonHeader);

Map<String, dynamic> _userJson() => {
      'id': 'u1',
      'aud': 'authenticated',
      'created_at': '2026-08-15T10:00:00Z',
      'email': 'jonas@eatova.de',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{'display_name': 'Jonas'},
    };

/// [accessToken] ist der Pruefstein: die Login-Antwort und die Verify-Antwort
/// tragen verschiedene Tokens, sonst waere die Zuordnung am RPC nicht lesbar.
Map<String, dynamic> _sessionJson(String accessToken) => {
      'access_token': accessToken,
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'test-refresh',
      'user': _userJson(),
    };

/// Roher Supabase-Client am MockClient — wie in `auth_enumeration_test.dart`
/// bewusst `implicit` statt `pkce`: ohne `Supabase.initialize` gibt es keinen
/// PKCE-Storage. Das ist zugleich der Flow, den die App real faehrt (und in
/// dem GoTrue die Methode 'otp' vergibt).
SupabaseClient _clientAm(MockClient transport) => SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );

/// Antwort-Body, wie PostgREST ihn fuer `raise exception 'EX_REAUTH_REQUIRED'
/// using errcode = '28000'` ausliefert (Klasse 28 -> HTTP 403).
Map<String, dynamic> _reauthFehlerBody() => <String, dynamic>{
      'code': '28000',
      'message': 'EX_REAUTH_REQUIRED',
      'details': null,
      'hint': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- (a) Wire: welches Token traegt der Loesch-RPC? -----------------------

  group('Der RPC nach der Code-Bestaetigung', () {
    test('traegt das NEUE Token aus verifyRecoveryCode, nicht das Login-Token',
        () async {
      final rpcAuth = <String>[];
      final client = _clientAm(MockClient((req) async {
        final pfad = req.url.path;
        if (pfad.endsWith('/token')) {
          return _json(req, _sessionJson('login-jwt'));
        }
        if (pfad.endsWith('/verify')) {
          return _json(req, _sessionJson('reauth-jwt'));
        }
        if (pfad.endsWith('/rpc/delete_account')) {
          rpcAuth.add(req.headers['Authorization'] ?? '<ohne Authorization>');
          // `returns void` -> leerer Body, wie PostgREST ihn liefert.
          return http.Response('', 204, request: req);
        }
        return _json(req, <String, dynamic>{});
      }));
      addTearDown(client.dispose);

      final repo = SupabaseAuthRepository(client);
      await repo.signIn(email: 'jonas@eatova.de', password: 'eatova123');
      expect(client.auth.currentSession?.accessToken, 'login-jwt',
          reason: 'Ausgangslage: eine normale Passwort-Sitzung');

      await repo.verifyRecoveryCode(email: 'jonas@eatova.de', code: '123456');
      await EatovaSync.forUser(client, 'u1').deleteAccount();

      expect(rpcAuth, hasLength(1), reason: 'genau ein RPC-Aufruf');
      expect(
        rpcAuth.single,
        'Bearer reauth-jwt',
        reason: 'nur die von verifyOTP gespeicherte NEUE Sitzung traegt den '
            'frischen amr-Eintrag — mit dem Login-Token lehnt die Migration '
            '20260815120000 ab (EX_REAUTH_REQUIRED), und die Loeschung waere '
            'im Feld tot',
      );
    });
  });

  // --- (b) Fehler-Roundtrip: 403 -> PostgrestException -> Text --------------

  group('Die Server-Ablehnung', () {
    test('kommt als PostgrestException 28000 an und bekommt den eigenen Satz',
        () async {
      final client = _clientAm(MockClient((req) async {
        if (req.url.path.endsWith('/rpc/delete_account')) {
          return _json(req, _reauthFehlerBody(), status: 403);
        }
        return _json(req, <String, dynamic>{});
      }));
      addTearDown(client.dispose);

      Object? gefangen;
      try {
        await EatovaSync.forUser(client, 'u1').deleteAccount();
      } catch (error) {
        gefangen = error;
      }

      // Der Body traegt einen eigenen `code` — der schlaegt den HTTP-Status,
      // beim Aufrufer kommt also '28000' an und NICHT '403'.
      expect(
          gefangen,
          isA<PostgrestException>()
              .having((e) => e.code, 'code', '28000')
              .having((e) => e.message, 'message', 'EX_REAUTH_REQUIRED'));
      final fehler = gefangen!;
      expect(isReauthRequiredError(fehler), isTrue);
      expect(deleteAccountErrorMessage(fehler),
          deL10n.settingsDeleteAccountReauthExpired);
      expect(deleteAccountErrorMessage(fehler, enL10n),
          enL10n.settingsDeleteAccountReauthExpired);
    });

    test('ist der EINZIGE Fall mit eigenem Text — der Rest bleibt generisch',
        () {
      // Sonstige Server-Ablehnung: unveraendert die Hausmeldung.
      const constraint = PostgrestException(message: 'boom', code: '23514');
      expect(isReauthRequiredError(constraint), isFalse);
      expect(deleteAccountErrorMessage(constraint),
          deL10n.commonGenericRetryError);
      expect(deleteAccountErrorMessage(constraint, enL10n),
          enL10n.commonGenericRetryError);

      // Netzfehler: unveraendert der Offline-Hinweis.
      final offline = http.ClientException('kein Netz');
      expect(isReauthRequiredError(offline), isFalse);
      expect(deleteAccountErrorMessage(offline), deL10n.commonSyncErrorOffline);
      expect(deleteAccountErrorMessage(offline, enL10n),
          enL10n.commonSyncErrorOffline);

      // Ein roher HTTP-403 (Body ohne `code`, z.B. Proxy) ist NICHT die
      // Reauth-Ablehnung — meist ein abgelaufener Token, etwas ganz anderes.
      expect(
          isReauthRequiredError(
              const PostgrestException(message: 'Forbidden', code: '403')),
          isFalse);

      // Beide Merkmale tragen je fuer sich: der errcode ueberlebt eine
      // umformulierte Meldung, der Message-Token einen weggefallenen Code.
      expect(
          isReauthRequiredError(const PostgrestException(
              message: 'invalid authorization specification', code: '28000')),
          isTrue);
      expect(
          isReauthRequiredError(
              const PostgrestException(message: 'EX_REAUTH_REQUIRED')),
          isTrue);
    });

    test('sagt etwas anderes als die Generik — sonst waere sie umsonst', () {
      // Faengt einen ARB-Merge, der den neuen Key versehentlich mit dem
      // bestehenden Text belegt: dann liefe der ganze Fall wieder ins Leere
      // („bitte spaeter erneut" hilft hier gerade nicht).
      expect(deL10n.settingsDeleteAccountReauthExpired,
          isNot(deL10n.commonGenericRetryError));
      expect(enL10n.settingsDeleteAccountReauthExpired,
          isNot(enL10n.commonGenericRetryError));
      expect(deL10n.settingsDeleteAccountReauthExpired,
          isNot(enL10n.settingsDeleteAccountReauthExpired),
          reason: 'zwei Sprachen, zwei Texte');
    });
  });

  // --- (c) Store: die Ablehnung raeumt NICHTS -------------------------------

  group('HomeStore.deleteAccount bei serverseitiger Ablehnung', () {
    // Store mit echtem EatovaSync an einem MockClient, der den Loesch-RPC mit
    // 403/EX_REAUTH_REQUIRED beantwortet. Bewusst kein Sync-Stub: so laeuft
    // der Fehler durch denselben Postgrest-Parser wie im Betrieb.
    (HomeStore, LocalCache, _SpyNotificationService, List<String>) baueStore() {
      final client = _clientAm(MockClient((req) async {
        if (req.url.path.endsWith('/rpc/delete_account')) {
          return _json(req, _reauthFehlerBody(), status: 403);
        }
        return _json(req, <String, dynamic>{});
      }));
      addTearDown(client.dispose);

      final cache = LocalCache(InMemoryKeyValueStore(), 'u1');
      final spy = _SpyNotificationService();
      final snacks = <String>[];
      final store = HomeStore(
        sync: EatovaSync.forUser(client, 'u1'),
        health: const NoopHealthService(),
        notificationService: spy,
        initialUserName: 'Jonas',
        emitSnack: (
          String message, {
          IconData icon = Icons.info_outline_rounded,
          SnackTone tone = SnackTone.positive,
          Duration? duration,
          SnackBarAction? action,
        }) =>
            snacks.add(message),
        debugCache: cache,
      );
      return (store, cache, spy, snacks);
    }

    test('liefert false, verwirft keine Erinnerungen, raeumt keinen Cache',
        () async {
      final (store, cache, spy, snacks) = baueStore();
      await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 12));

      expect(await store.deleteAccount(), isFalse,
          reason: 'false haelt die Schale vom Logout ab — der Nutzer sitzt '
              'sonst vor einem Login-Screen, waehrend sein Konto noch steht');

      expect(spy.cancelAllCalls, 0,
          reason: 'die Erinnerungen gehoeren zu einem Konto, das es noch gibt');
      expect(await cache.readLifetimeStats(), isNotNull,
          reason: 'nichts wurde geloescht, also darf auch lokal nichts fehlen');
      expect(snacks, hasLength(1),
          reason: 'genau eine Meldung, kein Schweigen');
    });

    test('nennt im Snack den Reauth-Grund statt der Generik', () async {
      final (store, _, _, snacks) = baueStore();

      await store.deleteAccount();

      expect(snacks.single, deL10n.settingsDeleteAccountReauthExpired,
          reason: '„bitte spaeter erneut" waere hier falsch: spaeter erneut '
              'zu tippen hilft nicht, der Code muss neu angefordert werden');
    });
  });
}

/// Zaehlt [cancelAll] mit — Muster aus `test/sign_out_cleanup_test.dart`, dort
/// fuer den Erfolgsfall (D9). Hier zaehlt der Gegenbeweis: bei einer
/// abgelehnten Loeschung darf der Aufruf NICHT kommen.
class _SpyNotificationService implements NotificationService {
  int cancelAllCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {}

  @override
  Future<void> cancelAll() async => cancelAllCalls++;
}
