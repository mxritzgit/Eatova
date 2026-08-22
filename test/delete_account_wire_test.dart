import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// http comes in transitively via supabase_flutter;
// depend_on_referenced_packages is demoted for it in analysis_options.yaml.
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

// The SERVER-SIDE re-auth requirement for account deletion
// (`20260815120000_delete_account_reauth.sql`), which needs a JWT with a fresh
// 'otp'/'recovery' `amr` entry. That the in-app flow satisfies this is an
// ASSUMPTION about gotrue and SupabaseClient; group (a) pins it at the wire,
// (b) through the real postgrest parser, (c) through the store, which must
// clear NOTHING. The UI half is in `test/delete_account_reauth_test.dart`.

const Map<String, String> _jsonHeader = {'Content-Type': 'application/json'};

/// `request:` is mandatory: `_parseResponse` dereferences `response.request!`
/// unchecked, so without it every RPC dies on a TypeError.
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

/// [accessToken] is the probe: login and verify carry different tokens.
Map<String, dynamic> _sessionJson(String accessToken) => {
      'access_token': accessToken,
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'test-refresh',
      'user': _userJson(),
    };

/// Raw Supabase client on the MockClient — `implicit`, not `pkce`: there is no
/// PKCE storage here, and this is the flow that makes GoTrue issue 'otp'.
SupabaseClient _clientAm(MockClient transport) => SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );

/// Body as PostgREST returns it for errcode '28000' (class 28 -> HTTP 403).
Map<String, dynamic> _reauthFehlerBody() => <String, dynamic>{
      'code': '28000',
      'message': 'EX_REAUTH_REQUIRED',
      'details': null,
      'hint': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- (a) Wire: which token does the delete RPC carry? ---------------------

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
          // `returns void` -> empty body, as PostgREST delivers it.
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

  // --- (b) Error round trip: 403 -> PostgrestException -> text --------------

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

      // The body's own `code` beats the HTTP status: '28000', not '403'.
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
      // Any other server rejection keeps the house message.
      const constraint = PostgrestException(message: 'boom', code: '23514');
      expect(isReauthRequiredError(constraint), isFalse);
      expect(deleteAccountErrorMessage(constraint),
          deL10n.commonGenericRetryError);
      expect(deleteAccountErrorMessage(constraint, enL10n),
          enL10n.commonGenericRetryError);

      // Network errors keep the offline hint.
      final offline = http.ClientException('kein Netz');
      expect(isReauthRequiredError(offline), isFalse);
      expect(deleteAccountErrorMessage(offline), deL10n.commonSyncErrorOffline);
      expect(deleteAccountErrorMessage(offline, enL10n),
          enL10n.commonSyncErrorOffline);

      // A raw HTTP 403 (no body `code`) is NOT the reauth rejection.
      expect(
          isReauthRequiredError(
              const PostgrestException(message: 'Forbidden', code: '403')),
          isFalse);

      // Either marker carries alone: errcode or message token.
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
      // Catches an ARB merge that fills the new key with the existing text.
      expect(deL10n.settingsDeleteAccountReauthExpired,
          isNot(deL10n.commonGenericRetryError));
      expect(enL10n.settingsDeleteAccountReauthExpired,
          isNot(enL10n.commonGenericRetryError));
      expect(deL10n.settingsDeleteAccountReauthExpired,
          isNot(enL10n.settingsDeleteAccountReauthExpired),
          reason: 'zwei Sprachen, zwei Texte');
    });
  });

  // --- (c) Store: the rejection clears NOTHING ------------------------------

  group('HomeStore.deleteAccount bei serverseitiger Ablehnung', () {
    // No sync stub: the error runs through the production postgrest parser.
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

/// Counts [cancelAll]: on a rejected deletion it must NOT happen.
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
