import 'dart:convert';

import 'package:supabase/supabase.dart';

String syncFixtureToken(String id) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': id, 'session_id': 'session-$id', 'role': 'authenticated', 'exp': 4102444800})}.'
      'synthetic-signature';
}

Future<void> signInSyncFixture(SupabaseClient client, String id) => client.auth
    .recoverSession(
      jsonEncode({
        'access_token': syncFixtureToken(id),
        'refresh_token': 'synthetic-refresh-$id',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at': 4102444800,
        'user': {
          'id': id,
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
        },
      }),
    )
    .then((_) {});
