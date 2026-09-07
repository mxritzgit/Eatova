import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/user_rpc.dart';

import '../outbox/outbox_test_helpers.dart' as h;

// Exercise the SDK's real AuthHttpClient with a token lookup paused until B
// logs in. The auth getter supplies the session inspected by userRpc.
class _DelayedTokenClient extends SupabaseClient {
  _DelayedTokenClient(
    this.sessionClient,
    Future<String?> Function() token,
    http.Client transport,
  ) : super(
        'https://example.invalid',
        'anon-fixture',
        accessToken: token,
        httpClient: transport,
      );

  final SupabaseClient sessionClient;

  @override
  GoTrueClient get auth => sessionClient.auth;
}

Future<void> signIn(SupabaseClient client, String id) => client.auth
    .recoverSession(
      jsonEncode({
        'access_token': 'fixture-$id',
        'refresh_token': 'refresh-$id',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        'user': {
          'id': id,
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
          'app_metadata': {},
          'user_metadata': {},
        },
      }),
    )
    .then((_) {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pinned bearer wins when delayed SDK token lookup returns B', () async {
    final sessionClient = SupabaseClient(
      'https://example.invalid',
      'anon-fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(sessionClient.dispose);
    await signIn(sessionClient, 'A');
    final entered = Completer<void>();
    final release = Completer<void>();
    final headers = <String?>[];
    final client = _DelayedTokenClient(
      sessionClient,
      () async {
        entered.complete();
        await release.future;
        return sessionClient.auth.currentSession!.accessToken;
      },
      MockClient((request) async {
        headers.add(request.headers['authorization']);
        return http.Response('{}', 200, request: request);
      }),
    );
    addTearDown(client.dispose);
    final pending = userRpc(client, 'A', 'delete_account');
    await entered.future;
    await signIn(sessionClient, 'B');
    release.complete();
    await pending;
    expect(headers, ['Bearer fixture-A']);
  });

  test(
    'RPC captures A bearer before the SDK yields to a new session',
    () async {
      final headers = <String?>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'anon-fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          headers.add(request.headers['authorization']);
          return http.Response('{}', 200, request: request);
        }),
      );
      addTearDown(client.dispose);
      await signIn(client, 'A');
      final pending = userRpc(client, 'A', 'delete_account');
      await signIn(client, 'B');
      await pending;
      expect(headers, ['Bearer fixture-A']);
      await expectLater(
        userRpc(client, 'A', 'delete_account'),
        throwsA(isA<AuthException>()),
      );
      expect(headers, hasLength(1));
    },
  );

  test(
    'a request made without a session cannot inherit a later login',
    () async {
      final headers = <String?>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'anon-fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          headers.add(request.headers['authorization']);
          return http.Response('{}', 200, request: request);
        }),
      );
      addTearDown(client.dispose);
      final pending = userRpc(client, 'A', 'delete_account');
      await signIn(client, 'B');
      await pending;
      expect(headers, ['Bearer ']);
    },
  );

  for (final switchAccount in [false, true]) {
    test(
      'disposed outbox stops and keeps pending entries (switch=$switchAccount)',
      () async {
        final kv = InMemoryKeyValueStore();
        await h.seedRawOutbox(kv, [
          SyncOp.statsIncrement(
            requestId: '11111111-1111-4111-8111-111111111111',
            meals: 1,
          ).toJson(),
          SyncOp.statsIncrement(
            requestId: '22222222-2222-4222-8222-222222222222',
            meals: 2,
          ).toJson(),
        ]);
        final gate = Completer<void>();
        final entered = Completer<void>();
        final server = h.FakeServer();
        final transport = server.client();
        final sent = <String?>[];
        final client = SupabaseClient(
          'https://example.supabase.co',
          'fixture-anon',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/rpc/increment_lifetime_stats')) {
              sent.add(request.headers['authorization']);
              if (sent.length == 1) {
                entered.complete();
                await gate.future;
              }
            }
            return http.Response.fromStream(await transport.send(request));
          }),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(client.dispose);
        await signIn(client, 'user-outbox');
        final cache = LocalCache(kv, 'user-outbox');
        final store = HomeStore(
          sync: EatovaSync.forUser(client, 'user-outbox'),
          health: const NoopHealthService(),
          notificationService: const NoopNotificationService(),
          initialUserName: 'Review',
          emitSnack: h.SnackCapture().call,
          debugCache: cache,
        );
        store.start();
        await entered.future.timeout(const Duration(seconds: 5));
        store.dispose();
        if (switchAccount) await signIn(client, 'B');
        gate.complete();
        await h.settle();
        expect(sent, ['Bearer fixture-user-outbox']);
        expect(await cache.readOutbox(), hasLength(2));
      },
    );
  }
}
