import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

typedef _MutationResult = ({User? user, Session? session});

/// Runs account mutations outside the shared GoTrue session. GoTrue 2.27.2
/// applies a late updateUser response to whichever session is then current.
/// A separate client keeps that response from changing another login.
Future<void> updateSessionUser(
  SupabaseClient client,
  UserAttributes attributes, {
  http.Client? httpClient,
}) => _mutate(client, (scoped) async {
  final response = await scoped.updateUser(attributes);
  return (user: response.user, session: null);
}, httpClient: httpClient);

Future<void> verifySessionEmailChange(
  SupabaseClient client, {
  required String email,
  required String code,
  http.Client? httpClient,
}) => _mutate(client, (scoped) async {
  final response = await scoped.verifyOTP(
    type: OtpType.emailChange,
    email: email,
    token: code,
  );
  // The first secure-email code returns no session: keep the old address.
  return (user: null, session: response.session);
}, httpClient: httpClient);

Future<void> _mutate(
  SupabaseClient client,
  Future<_MutationResult> Function(GoTrueClient scoped) operation, {
  http.Client? httpClient,
}) async {
  // A browser GoTrueClient broadcasts sessions to sibling clients before this
  // guard can adopt them. Eatova's account flows currently target Android/iOS.
  if (kIsWeb) throw UnsupportedError('Account changes require the mobile app');
  final original = client.auth.currentSession;
  if (original == null) throw AuthSessionMissingException();
  final identity = _identity(original);
  final transport = httpClient ?? http.Client();
  final scoped = GoTrueClient(
    url: client.rest.url.replaceFirst(RegExp(r'/rest/v1/?$'), '/auth/v1'),
    headers: Map<String, String>.of(client.auth.headers),
    httpClient: transport,
    autoRefreshToken: false,
    // These flows verify mail codes directly and never use a callback link.
    // They must not replace the shared client's pending OAuth PKCE verifier.
    flowType: AuthFlowType.implicit,
  );
  try {
    await scoped.setInitialSession(jsonEncode(original.toJson()));
    if (_identity(client.auth.currentSession) != identity) {
      throw const AuthException('Authentication session changed');
    }
    final result = await operation(scoped);
    final current = client.auth.currentSession;
    if (_identity(current) != identity) {
      throw const AuthException('Authentication session changed');
    }
    final user = result.session?.user ?? result.user;
    if (user != null && user.id != original.user.id) {
      throw const AuthException('Authentication session changed');
    }
    // Keep a concurrently refreshed token on PUT /user. Only successful OTP
    // verification supplies a replacement session; a partial response does not.
    final next =
        result.session ??
        (result.user == null ? null : current!.copyWith(user: result.user));
    if (next != null) {
      // For a valid SDK-parsed session, setInitialSession assigns synchronously
      // before its first await. No account switch fits between this check and
      // adoption. Its event updates AuthGate, encrypted storage and Realtime.
      await client.auth.setInitialSession(jsonEncode(next.toJson()));
    }
  } finally {
    scoped.dispose();
    if (httpClient == null) transport.close();
  }
}

/// session_id survives token refresh but changes on a new login, including
/// another login by the same user. This compares identity, not authenticity.
({String userId, String sessionId})? _identity(Session? session) {
  if (session == null) return null;
  final token = session.accessToken;
  try {
    final parts = token.split('.');
    if (parts.length == 3) {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is Map<String, dynamic>) {
        final sessionId = payload['session_id'];
        if (sessionId is String && sessionId.isNotEmpty) {
          return (userId: session.user.id, sessionId: sessionId);
        }
      }
    }
  } on FormatException {
    // Tokens without a session id fail closed on any token replacement.
  }
  return (userId: session.user.id, sessionId: token);
}
