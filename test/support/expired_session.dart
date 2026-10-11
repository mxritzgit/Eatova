import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

/// A synthetic JWT of [user] that expires at [exp] (seconds since epoch).
String syntheticJwt(String user, int exp) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.'
      '${part({'sub': user, 'session_id': 's-$user', 'exp': exp})}.sig';
}

/// The state after a long background period, before the SDK's own refresh
/// has landed: the stored access token ([stale]) has expired, the refresh
/// token is valid, and a refresh hands out [fresh] (of `refreshedUser`, by
/// default the same account).
typedef ExpiredSession = ({
  SupabaseClient client,
  String stale,
  String fresh,
  List<http.Request> refreshes,
});

Future<ExpiredSession> expiredSession({
  String user = 'user-a',
  String? refreshedUser,
}) async {
  Map<String, dynamic> session(String owner, String token, String refresh) => {
    'access_token': token,
    'refresh_token': refresh,
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': owner,
      'aud': 'authenticated',
      'created_at': '2026-09-20T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  };
  final stale = syntheticJwt(user, 1);
  final fresh = syntheticJwt(refreshedUser ?? user, 4102444800);
  final refreshes = <http.Request>[];
  final client = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    httpClient: MockClient((request) async {
      expect(request.url.path, '/auth/v1/token');
      expect(request.url.queryParameters['grant_type'], 'refresh_token');
      refreshes.add(request);
      return http.Response(
        jsonEncode(session(refreshedUser ?? user, fresh, 'refresh-2')),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  await client.auth.setInitialSession(
    jsonEncode(session(user, stale, 'refresh-1')),
  );
  expect(client.auth.currentSession!.isExpired, isTrue);
  return (client: client, stale: stale, fresh: fresh, refreshes: refreshes);
}
