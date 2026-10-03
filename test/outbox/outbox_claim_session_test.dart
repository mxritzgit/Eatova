import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// Replay with a real signed-in session, i.e. through the account/session
// claim that the session-less outbox harness never takes.

const _owner = 'user-outbox';
const _session = 'claim-session';
const _mealId = '5b0c1d2e-3f40-4a51-8b62-7c83d94ea5f6';

Future<void> _signIn(SupabaseClient client) {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': _owner,
            'session_id': _session,
            'exp': 4102444800,
          }),
        ),
      )
      .replaceAll('=', '');
  return client.auth.recoverSession(
    jsonEncode({
      'access_token': 'fixture.$payload.signature',
      'refresh_token': 'fixture-refresh',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at': 4102444800,
      'user': {
        'id': _owner,
        'aud': 'authenticated',
        'created_at': '2026-01-01T00:00:00Z',
        'app_metadata': <dynamic, dynamic>{},
        'user_metadata': <dynamic, dynamic>{},
      },
    }),
  );
}

/// One queued meal insert, as a previous process left it.
Map<String, String> _queuedMeal() => {
  'eatova.v1.outbox.$_owner': jsonEncode({
    'items': [
      SyncOp.mealInsert(
        LoggedMeal(
          id: _mealId,
          loggedAt: DateTime.utc(2026, 9, 20, 11),
          result: mealResult('Vor dem Kill'),
        ),
        trackDay: false,
      ).toJson(),
    ],
  }),
};

HomeStore _store(FakeServer server, SupabaseClient client, LocalCache cache) =>
    HomeStore(
      sync: EatovaSync.forUser(client, _owner),
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Test',
      emitSnack: SnackCapture().call,
      debugCache: cache,
    );

SupabaseClient _client(FakeServer server) => SupabaseClient(
  'https://example.supabase.co',
  'test-anon-key',
  httpClient: server.client(),
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ein noch gueltiger Claim eines gekillten Prozesses blockiert den '
      'Boot-Replay nur bis zum Lease-Ende, nicht bis zum naechsten '
      'Lifecycle-Ereignis', () {
    fakeAsync((async) {
      final server = FakeServer()..profileRow = serverProfileRow(testProfile());
      final client = _client(server);
      _signIn(client);
      async.flushMicrotasks();
      final start = clock.now().toUtc();
      // The killed process activated this session and held the claim when it
      // died; its finally never released it.
      final kv = InMemoryKeyValueStore({
        ..._queuedMeal(),
        syncSessionKey: jsonEncode({
          'owner': _owner,
          'session': _session,
          'generation': 'generation-before-kill',
        }),
        syncClaimKey(_owner): jsonEncode({
          'generation': 'generation-before-kill',
          'token': 'dead-worker',
          'expires_at': start
              .add(SyncExecutionGuard.leaseDuration)
              .toIso8601String(),
        }),
      });
      final store = _store(server, client, LocalCache(kv, _owner));
      store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();

      expect(
        server.mealRows,
        isEmpty,
        reason: 'Vorbedingung: der fremde Lease haelt den Boot-Replay an',
      );
      expect(
        store.pendingOutbox.map((op) => op.entityId),
        contains(_mealId),
        reason: 'Vorbedingung',
      );

      // No pause/resume, no new write, no connectivity event.
      async.elapse(const Duration(seconds: 90));
      async.flushMicrotasks();

      expect(
        server.mealRows.keys,
        contains(_mealId),
        reason:
            'nach Ablauf des toten Leases muss der eigene Wecker zustellen; '
            'ohne ihn bleibt die Mahlzeit bis zum naechsten '
            'Lifecycle-Ereignis liegen',
      );
      expect(store.pendingOutbox, isEmpty);
      store.dispose();
    }, initialTime: DateTime(2026, 9, 20, 12));
  });
}
