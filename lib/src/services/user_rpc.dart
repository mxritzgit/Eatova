import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the bearer before the SDK's asynchronous HTTP authentication step.
/// A queued RPC must never inherit the next account's token from a shared client.
Future<dynamic> userRpc(
  SupabaseClient client,
  String userId,
  String function, {
  Map<String, dynamic>? params,
  bool single = false,
}) async {
  var session = client.auth.currentSession;
  if (session != null && session.user.id != userId) {
    throw const AuthException('Session changed');
  }
  if (session != null && session.isExpired) {
    await client.auth.refreshSession();
    session = client.auth.currentSession;
  }
  if (session != null && session.user.id != userId) {
    throw const AuthException('Session changed');
  }
  // An absent session remains anonymous even if login finishes while the SDK
  // awaits its token. An explicit empty bearer is rejected by the server.
  final authorization = 'Bearer ${session?.accessToken ?? ''}';
  final request = client.rpc(function, params: params);
  if (single) {
    return request.select().single().setHeader('Authorization', authorization);
  }
  return request.setHeader('Authorization', authorization);
}
