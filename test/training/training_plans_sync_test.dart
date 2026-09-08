import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/services/training_plans_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../services/user_rpc_test.dart' show signIn;
import 'training_store_test.dart' show plan;

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
  for (final operation in ['load', 'upsert', 'delete']) {
    test(
      '$operation pins A bearer before delayed SDK lookup returns B',
      () async {
        final sessionClient = SupabaseClient(
          'https://example.invalid',
          'fixture',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(sessionClient.dispose);
        await signIn(sessionClient, 'A');
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
        final pending = switch (operation) {
          'load' => sync.load(),
          'upsert' => sync.upsert(plan()),
          _ => sync.delete('coach_message'),
        };
        await entered.future;
        await signIn(sessionClient, 'B');
        release.complete();
        await pending;
        expect(requests.single.headers['authorization'], 'Bearer fixture-A');
        if (operation == 'upsert') {
          final decoded = jsonDecode(requests.single.body);
          final row = decoded is List ? decoded.single : decoded;
          expect(row['user_id'], 'A');
          expect(
            requests.single.url.queryParameters['on_conflict'],
            'user_id,id',
          );
        } else {
          expect(requests.single.url.queryParameters['user_id'], 'eq.A');
        }
        await expectLater(sync.upsert(plan()), throwsA(isA<AuthException>()));
        expect(requests, hasLength(1));
      },
    );
  }

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

  test('delete validates ID before issuing a request', () async {
    var requested = false;
    final client = SupabaseClient(
      'https://example.invalid',
      'fixture',
      httpClient: MockClient((request) async {
        requested = true;
        return http.Response('', 204, request: request);
      }),
    );
    addTearDown(client.dispose);
    await expectLater(
      TrainingPlansSync(client, 'A').delete('../other'),
      throwsFormatException,
    );
    expect(requested, isFalse);
  });
}
