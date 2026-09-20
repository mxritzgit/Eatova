import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:postgrest/postgrest.dart' as postgrest;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';

typedef _MutationResult = ({User? user, Session? session});

typedef ScopedAccountDeleteAction =
    Future<void> Function(
      Future<void> Function() deleteRemote,
      bool Function() isCurrentSession,
    );

/// Recovery authorizes only this deletion and never replaces the app session.
Future<void> runAccountDeletionCode(
  SupabaseClient client, {
  required String userId,
  required String email,
  required String code,
  required ScopedAccountDeleteAction performDeletion,
  http.Client? httpClient,
}) async {
  if (kIsWeb) throw UnsupportedError('Account changes require the mobile app');
  final original = client.auth.currentSession;
  if (original == null ||
      original.user.id != userId ||
      original.user.email?.trim().toLowerCase() != email.trim().toLowerCase()) {
    throw const AuthException('Authentication session changed');
  }
  final identity = _identity(original);
  var changed = false;
  var active = true;
  bool isCurrent() =>
      active && !changed && _identity(client.auth.currentSession) == identity;
  void requireCurrent() {
    if (!isCurrent()) {
      throw const AuthException('Authentication session changed');
    }
  }

  // Keep the synchronous observer through verification, RPC and local cleanup.
  // ignore: invalid_use_of_internal_member
  final subscription = client.auth.onAuthStateChangeSync.listen(
    (event) {
      if (_identity(event.session) != identity) changed = true;
    },
    onError: (Object _, StackTrace __) {
      changed = true;
    },
  );
  final transport = httpClient ?? http.Client();
  final deadline =
      client.rest.requestTimeout ??
      EatovaSupabaseConfig.postgrestOptions.requestTimeout!;
  final scoped = GoTrueClient(
    url: client.rest.url.replaceFirst(RegExp(r'/rest/v1/?$'), '/auth/v1'),
    headers: Map<String, String>.of(client.auth.headers),
    httpClient: transport,
    autoRefreshToken: false,
    flowType: AuthFlowType.implicit,
  );
  try {
    requireCurrent();
    final response = await scoped
        .verifyOTP(
          type: OtpType.recovery,
          email: email.trim(),
          token: code.trim(),
        )
        .timeout(deadline);
    requireCurrent();
    final verified = response.session;
    if (verified == null || verified.user.id != userId) {
      throw const AuthException('Authentication session changed');
    }
    var used = false;
    await performDeletion(() async {
      requireCurrent();
      if (used) {
        throw const AuthException('Deletion authorization already used');
      }
      used = true;
      // Use the scoped transport: the shared auth HTTP client may refresh the
      // app login. This RPC only needs the newly verified, fixed bearer.
      await postgrest.PostgrestBuilder<dynamic, dynamic, dynamic>(
        url: Uri.parse('${client.rest.url}/rpc/delete_account'),
        method: postgrest.HttpMethod.post,
        headers: {
          for (final entry in client.rest.headers.entries)
            if (entry.key.toLowerCase() != 'authorization')
              entry.key: entry.value,
          'Authorization': 'Bearer ${verified.accessToken}',
        },
        httpClient: transport,
        retryEnabled: false,
        requestTimeout: deadline,
      );
    }, isCurrent);
    if (!used) throw StateError('Deletion was not requested');
  } finally {
    active = false;
    await subscription.cancel();
    scoped.dispose();
    if (httpClient == null) transport.close();
  }
}

/// Isolates a credential exchange from other logins, including the time spent
/// in a native account chooser. Signup may return a user without a session
/// while email confirmation is pending.
Future<AuthResponse> authenticateSession(
  SupabaseClient client,
  Future<AuthResponse> Function(GoTrueClient scoped) operation, {
  http.Client? httpClient,
  bool requireSession = false,
}) async {
  late AuthResponse response;
  await _mutate(
    client,
    (scoped) async {
      response = await operation(scoped);
      if (requireSession && response.session == null) {
        throw const AuthException('Authentication returned no session');
      }
      return (user: null, session: response.session);
    },
    httpClient: httpClient,
    allowSignedOut: true,
    allowAccountSwitch: true,
    loginEvent: true,
  );
  return response;
}

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

/// Verifies a login/reauthentication code without letting a late SDK response
/// replace a newer login. Recovery also serves account-deletion reauth.
Future<void> verifySessionLoginCode(
  SupabaseClient client, {
  required OtpType type,
  required String email,
  required String code,
  http.Client? httpClient,
}) => _mutate(
  client,
  (scoped) async {
    final response = await scoped.verifyOTP(
      type: type,
      email: email,
      token: code,
    );
    if (response.session == null) {
      throw const AuthException('Code verification returned no session');
    }
    return (user: null, session: response.session);
  },
  httpClient: httpClient,
  allowSignedOut: true,
);

Future<void> _mutate(
  SupabaseClient client,
  Future<_MutationResult> Function(GoTrueClient scoped) operation, {
  http.Client? httpClient,
  bool allowSignedOut = false,
  bool allowAccountSwitch = false,
  bool loginEvent = false,
}) async {
  // A browser GoTrueClient broadcasts sessions to sibling clients before this
  // guard can adopt them. Eatova's account flows currently target Android/iOS.
  if (kIsWeb) throw UnsupportedError('Account changes require the mobile app');
  final original = client.auth.currentSession;
  if (original == null && !allowSignedOut) throw AuthSessionMissingException();
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
  var changed = false;
  // GoTrue 2.27.2: the synchronous stream observes even A -> B -> A or
  // signed-out -> B -> signed-out before queued responses can be adopted.
  // supabase_common 0.1.2 also replays its latest event: a historical signedOut
  // matches an already signed-out baseline and must not reject a new login.
  // ignore: invalid_use_of_internal_member
  final subscription = client.auth.onAuthStateChangeSync.listen(
    (event) {
      if (_identity(event.session) != identity) {
        changed = true;
      }
    },
    onError: (Object _, StackTrace __) {
      changed = true;
    },
  );
  try {
    if (original != null) {
      await scoped.setInitialSession(jsonEncode(original.toJson()));
    }
    if (changed || _identity(client.auth.currentSession) != identity) {
      throw const AuthException('Authentication session changed');
    }
    final result = await operation(scoped);
    final current = client.auth.currentSession;
    if (changed || _identity(current) != identity) {
      throw const AuthException('Authentication session changed');
    }
    final user = result.session?.user ?? result.user;
    if (!allowAccountSwitch &&
        user != null &&
        original != null &&
        user.id != original.user.id) {
      throw const AuthException('Authentication session changed');
    }
    // User-only updates keep a concurrently refreshed token. Successful
    // credential or OTP exchanges provide their own replacement session.
    final next =
        result.session ??
        (result.user == null ? null : current!.copyWith(user: result.user));
    if (next != null) {
      // For a valid SDK-parsed session, setInitialSession assigns synchronously
      // before its first await. No account switch fits between this check and
      // adoption. Its event updates AuthGate, encrypted storage and Realtime.
      final adoption = client.auth.setInitialSession(jsonEncode(next.toJson()));
      // Keep the SDK's interactive-login event for session-bound operations
      // and OAuth sheet dismissal. Synchronous listeners may replace the
      // adopted session, so never announce a login for that replacement.
      if (loginEvent &&
          _identity(client.auth.currentSession) == _identity(next)) {
        // ignore: invalid_use_of_internal_member
        client.auth.notifyAllSubscribers(AuthChangeEvent.signedIn);
      }
      await adoption;
    }
  } finally {
    await subscription.cancel();
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
