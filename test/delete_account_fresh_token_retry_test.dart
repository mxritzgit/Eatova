import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
// http comes in transitively via supabase_flutter;
// depend_on_referenced_packages is demoted for it in analysis_options.yaml.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart'
    show AuthClientOptions, AuthFlowType, PostgrestException, SupabaseClient;

import 'package:eatova/src/auth/auth_session_mutation.dart';

// Sentry 2026-10-04 (PostgrestException code=401, context "Konto-Löschung",
// iPhone, 1.1.0 (4)): the deletion RPC runs with the token the recovery code
// minted a moment earlier, and the server now and then rejects a brand-new
// token once — the pattern StaleAuthRetry documents for the boot reads (edge
// logs 2026-08-26: PGRST303 from PostgREST, or a bare 401 from the gateway).
// The code was spent, so the user had to request a new one. A 401 is raised
// before PostgREST runs the function, so one retry after a short wait is safe;
// a real refusal (28000, 403) is never repeated.

const Map<String, String> _jsonHeader = {'Content-Type': 'application/json'};

http.Response _json(http.Request req, Object? body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, request: req, headers: _jsonHeader);

Map<String, dynamic> _session(String accessToken) => {
  'access_token': accessToken,
  'token_type': 'bearer',
  'expires_in': 3600,
  'refresh_token': 'test-refresh',
  'user': {
    'id': 'u1',
    'aud': 'authenticated',
    'created_at': '2026-10-04T09:00:00Z',
    'email': 'jonas@eatova.de',
    'app_metadata': <String, dynamic>{},
    'user_metadata': <String, dynamic>{},
  },
};

/// The server's answers to the delete RPC, in order; the last one repeats.
Future<({int rpcCalls, List<Duration> waits, Object? error})> _deleteWith(
  List<({int status, Object? body})> rpcAnswers,
) async {
  var rpcCalls = 0;
  final transport = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/token')) return _json(req, _session('login-jwt'));
    if (path.endsWith('/verify')) return _json(req, _session('reauth-jwt'));
    if (path.endsWith('/rpc/delete_account')) {
      final answer = rpcAnswers[rpcCalls.clamp(0, rpcAnswers.length - 1)];
      rpcCalls++;
      if (answer.status == 204) return http.Response('', 204, request: req);
      return _json(req, answer.body, status: answer.status);
    }
    return _json(req, <String, dynamic>{});
  });
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: transport,
    authOptions: const AuthClientOptions(
      autoRefreshToken: false,
      authFlowType: AuthFlowType.implicit,
    ),
  );
  addTearDown(client.dispose);
  await client.auth.signInWithPassword(
    email: 'jonas@eatova.de',
    password: 'eatova123',
  );

  final waits = <Duration>[];
  Object? error;
  try {
    await runAccountDeletionCode(
      client,
      userId: 'u1',
      email: 'jonas@eatova.de',
      code: '12345678',
      httpClient: transport,
      retryDelay: (duration) async => waits.add(duration),
      performDeletion: (deleteRemote, isCurrent) => deleteRemote(),
    );
  } catch (e) {
    error = e;
  }
  return (rpcCalls: rpcCalls, waits: waits, error: error);
}

const _jwtFuture = <String, Object?>{
  'code': 'PGRST303',
  'message': 'JWT issued at future',
  'details': null,
  'hint': null,
};

void main() {
  test('a fresh token the server rejects once is retried once and deletes', () async {
    final run = await _deleteWith([
      (status: 401, body: _jwtFuture),
      (status: 204, body: null),
    ]);

    expect(run.error, isNull, reason: 'the second attempt deleted');
    expect(run.rpcCalls, 2);
    expect(run.waits, hasLength(1), reason: 'one short wait, no loop');
  });

  test('a bare gateway 401 counts as the same rejection', () async {
    final run = await _deleteWith([
      (status: 401, body: <String, Object?>{'message': 'Invalid JWT'}),
      (status: 204, body: null),
    ]);

    expect(run.error, isNull);
    expect(run.rpcCalls, 2);
  });

  test('a second rejection reaches the caller after exactly two calls', () async {
    final run = await _deleteWith([(status: 401, body: _jwtFuture)]);

    expect(
      run.error,
      isA<PostgrestException>().having((e) => e.code, 'code', 'PGRST303'),
    );
    expect(run.rpcCalls, 2);
  });

  test('a real re-auth refusal (28000) is never repeated', () async {
    final run = await _deleteWith([
      (
        status: 403,
        body: <String, Object?>{
          'code': '28000',
          'message': 'EX_REAUTH_REQUIRED',
          'details': null,
          'hint': null,
        },
      ),
    ]);

    expect(
      run.error,
      isA<PostgrestException>().having((e) => e.code, 'code', '28000'),
    );
    expect(run.rpcCalls, 1);
    expect(run.waits, isEmpty);
  });
}
