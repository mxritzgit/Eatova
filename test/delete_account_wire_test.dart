import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// http comes in transitively via supabase_flutter;
// depend_on_referenced_packages is demoted for it in analysis_options.yaml.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart'
    show AuthClientOptions, AuthFlowType, PostgrestException, SupabaseClient;

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// The SERVER-SIDE re-auth requirement for account deletion
// (`20260815120000_delete_account_reauth.sql`) rejects a JWT without a fresh
// 'otp'/'recovery' `amr` entry with errcode 28000. That the delete RPC carries
// the isolated recovery bearer and that the 403 arrives as a
// PostgrestException 28000 is pinned at the wire in
// `test/delete_account_scope_test.dart`; the UI half is in
// `test/delete_account_reauth_test.dart`. Here: the rejection gets its own
// sentence, and the store clears NOTHING when the server refused.

/// The rejection as postgrest parses PostgREST's 403 body for errcode 28000.
const PostgrestException _reauthRejection =
    PostgrestException(message: 'EX_REAUTH_REQUIRED', code: '28000');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nur die Reauth-Ablehnung bekommt den eigenen Satz, der Rest bleibt '
      'generisch', () {
    expect(isReauthRequiredError(_reauthRejection), isTrue);
    expect(deleteAccountErrorMessage(_reauthRejection),
        deL10n.settingsDeleteAccountReauthExpired);
    expect(deleteAccountErrorMessage(_reauthRejection, enL10n),
        enL10n.settingsDeleteAccountReauthExpired);

    // Any other server rejection keeps the house message.
    const constraint = PostgrestException(message: 'boom', code: '23514');
    expect(isReauthRequiredError(constraint), isFalse);
    expect(deleteAccountErrorMessage(constraint),
        deL10n.commonGenericRetryError);

    // Network errors keep the offline hint.
    final offline = http.ClientException('kein Netz');
    expect(isReauthRequiredError(offline), isFalse);
    expect(deleteAccountErrorMessage(offline), deL10n.commonSyncErrorOffline);

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

  test('HomeStore.deleteAccount: eine Server-Ablehnung liefert false, raeumt '
      'nichts und nennt den Reauth-Grund', () async {
    // Any other request would be a second deletion attempt.
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient(
        (req) async => throw StateError('unexpected ${req.url.path}'),
      ),
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );
    addTearDown(client.dispose);
    final cache = LocalCache(InMemoryKeyValueStore(), 'u1');
    await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 12));
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
    addTearDown(store.dispose);

    // The production path: the sheet's scoped deletion hands its RPC over.
    final deleted = await store.deleteAccount(
      deleteRemote: () async => throw _reauthRejection,
      isCurrentSession: () => true,
    );

    expect(deleted, isFalse,
        reason: 'false haelt die Schale vom Logout ab — der Nutzer sitzt '
            'sonst vor einem Login-Screen, waehrend sein Konto noch steht');
    expect(spy.cancelAllCalls, 0,
        reason: 'die Erinnerungen gehoeren zu einem Konto, das es noch gibt');
    expect(await cache.readLifetimeStats(), isNotNull,
        reason: 'nichts wurde geloescht, also darf auch lokal nichts fehlen');
    expect(snacks, [deL10n.settingsDeleteAccountReauthExpired],
        reason: '„bitte spaeter erneut" waere hier falsch: der Code muss neu '
            'angefordert werden');
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
