import 'dart:async';

import 'package:eatova/src/services/training_plans_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../services/user_rpc_test.dart' show signIn;

class _DelayedTokenClient extends SupabaseClient {
  _DelayedTokenClient(
    this.sessionClient,
    Future<String?> Function() token,
    http.Client transport,
  ) : super(
        'https://example.invalid',
        'fixture',
        accessToken: token,
        httpClient: transport,
      );
  final SupabaseClient sessionClient;
  @override
  GoTrueClient get auth => sessionClient.auth;
}

void main() {
  test(
    'load pins A bearer before delayed SDK lookup returns B',
    () async {
      final sessionClient = SupabaseClient(
        'https://example.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(sessionClient.dispose);
      await signIn(sessionClient, 'A');
      final pinnedAToken = sessionClient.auth.currentSession!.accessToken;
      final entered = Completer<void>();
      final release = Completer<void>();
      final requests = <http.Request>[];
      final client = _DelayedTokenClient(
        sessionClient,
        () async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          return sessionClient.auth.currentSession!.accessToken;
        },
        MockClient((request) async {
          requests.add(request);
          return http.Response(
            request.method == 'GET' ? '[]' : '',
            request.method == 'GET' ? 200 : 204,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final sync = TrainingPlansSync(client, 'A');
      final pending = sync.load();
      await entered.future;
      await signIn(sessionClient, 'B');
      expect(sessionClient.auth.currentSession!.accessToken, isNot(pinnedAToken));
      release.complete();
      await pending;
      expect(requests.single.headers['authorization'], 'Bearer $pinnedAToken');
      expect(requests.single.url.queryParameters['user_id'], 'eq.A');
      await expectLater(sync.load(), throwsA(isA<AuthException>()));
      expect(requests, hasLength(1));
    },
  );

  test(
    'load rejects malformed server JSON instead of fabricating a plan',
    () async {
      final client = SupabaseClient(
        'https://example.invalid',
        'fixture',
        httpClient: MockClient(
          (request) async => http.Response(
            '[{"id":"x","plan":{"title":"incomplete"}}]',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
      );
      addTearDown(client.dispose);
      await expectLater(
        TrainingPlansSync(client, 'A').load(),
        throwsFormatException,
      );
    },
  );
}
