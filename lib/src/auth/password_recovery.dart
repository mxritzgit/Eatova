import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';

/// A mail-verified, in-memory capability. It is never an application login.
abstract interface class PasswordRecovery {
  bool get isActive;
  Future<void> updatePassword(String newPassword);

  /// Invalidates immediately; remote revocation is bounded and best-effort.
  Future<void> close();
}

Future<PasswordRecovery> beginPasswordRecovery(
  SupabaseClient client, {
  required String email,
  required String code,
  http.Client? httpClient,
  Duration authorizationLifetime = const Duration(minutes: 10),
}) async {
  final recovery = _TemporaryEmailSession(
    client,
    httpClient: httpClient,
    authorizationLifetime: authorizationLifetime,
  );
  await recovery.verify(email, code, OtpType.recovery);
  return recovery;
}

/// Confirmation consumes the OTP, then discards its privileged session.
Future<void> confirmSignupWithoutLogin(
  SupabaseClient client, {
  required String email,
  required String code,
  http.Client? httpClient,
}) async {
  final confirmation = _TemporaryEmailSession(client, httpClient: httpClient);
  try {
    await confirmation.verify(email, code, OtpType.signup);
  } finally {
    await confirmation.close();
  }
}

class _TemporaryEmailSession implements PasswordRecovery {
  _TemporaryEmailSession(
    this._client, {
    http.Client? httpClient,
    this.authorizationLifetime = const Duration(minutes: 10),
  }) : _transport = httpClient ?? http.Client(),
       _ownsTransport = httpClient == null {
    if (kIsWeb) {
      if (_ownsTransport) _transport.close();
      throw UnsupportedError('Account changes require the mobile app');
    }
    if (_client.auth.currentSession != null) {
      if (_ownsTransport) _transport.close();
      throw const AuthException('Sign out before verifying a login code');
    }
    _scoped = GoTrueClient(
      url: _client.rest.url.replaceFirst(RegExp(r'/rest/v1/?$'), '/auth/v1'),
      headers: Map<String, String>.of(_client.auth.headers),
      httpClient: _transport,
      autoRefreshToken: false,
      flowType: AuthFlowType.implicit,
    );
    // Keep this observer for the whole capability lifetime, including ABA.
    // ignore: invalid_use_of_internal_member
    _subscription = _client.auth.onAuthStateChangeSync.listen((event) {
      if (event.session != null) unawaited(close());
    }, onError: (Object _, StackTrace __) => unawaited(close()));
    if (_closed) unawaited(_subscription!.cancel());
  }

  final SupabaseClient _client;
  final http.Client _transport;
  final bool _ownsTransport;
  final Duration authorizationLifetime;
  late final GoTrueClient _scoped;
  StreamSubscription<AuthState>? _subscription;
  Session? _verified;
  Timer? _expiry;
  final _lifetime = Stopwatch();
  bool _closed = false;
  bool _busy = false;
  bool _disposed = false;
  Future<void>? _closing;

  Duration get _deadline =>
      _client.rest.requestTimeout ??
      EatovaSupabaseConfig.postgrestOptions.requestTimeout!;

  @override
  bool get isActive =>
      !_closed &&
      _client.auth.currentSession == null &&
      (!_lifetime.isRunning || _lifetime.elapsed < authorizationLifetime);

  void _requireActive() {
    if (!isActive) {
      unawaited(close());
      throw const AuthException(
        'Recovery authorization expired. Request a new code.',
        code: 'otp_expired',
      );
    }
  }

  Future<void> verify(String email, String code, OtpType type) async {
    _requireActive();
    _busy = true;
    // Consume any response already arriving during cancellation before disposing
    // the SDK. Closing owned HTTP may abort it: an unseen token cannot be revoked.
    Future<void> exchange() async {
      try {
        final response = await _scoped.verifyOTP(
          email: email.trim(),
          token: code.trim(),
          type: type,
        );
        _verified = response.session;
        if (_closed) {
          await _revoke();
          _requireActive();
        }
        _requireActive();
        final session = _verified;
        if (session == null ||
            !_hasBoundIdentity(session) ||
            session.user.email?.trim().toLowerCase() !=
                email.trim().toLowerCase()) {
          throw const AuthException(
            'Code verification returned another account',
          );
        }
        _lifetime.start();
        _expiry = Timer(authorizationLifetime, () => unawaited(close()));
      } finally {
        _busy = false;
        if (_closed) _dispose();
      }
    }

    try {
      await exchange().timeout(_deadline);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  bool _hasBoundIdentity(Session session) {
    try {
      final parts = session.accessToken.split('.');
      if (parts.length != 3 || session.user.id.isEmpty) return false;
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return claims is Map<String, dynamic> &&
          claims['sub'] == session.user.id &&
          claims['session_id'] is String &&
          (claims['session_id'] as String).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    _requireActive();
    if (_busy || _verified == null) {
      throw const AuthException('Recovery authorization is already in use');
    }
    _busy = true;
    Future<UserResponse> update() async {
      try {
        return await _scoped.updateUser(UserAttributes(password: newPassword));
      } finally {
        _busy = false;
        if (_closed) _dispose();
      }
    }

    try {
      final response = await update().timeout(_deadline);
      _requireActive();
      if (response.user?.id != _verified!.user.id) {
        throw const AuthException('Password update returned another account');
      }
    } on AuthException catch (error) {
      // Explicit validation rejection is safe to correct without another OTP.
      // All other failures may represent a committed-but-unacknowledged write.
      if (isActive &&
          (error.code == 'weak_password' || error.code == 'same_password')) {
        rethrow;
      }
      await close();
      rethrow;
    } catch (_) {
      await close();
      rethrow;
    }
    await close();
  }

  @override
  Future<void> close() {
    _closed = true;
    _expiry?.cancel();
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await _subscription?.cancel();
    await _revoke();
    // Do not close an injected client owned by the app/test harness.
    if (_ownsTransport) _transport.close();
    if (!_busy) _dispose();
  }

  Future<void> _revoke() async {
    final session = _verified;
    _verified = null;
    if (session == null) return;
    try {
      // Never use global logout: a newer login must survive this cleanup.
      await _scoped.admin
          .signOut(session.accessToken, scope: SignOutScope.local)
          .timeout(_deadline);
    } catch (_) {
      // No credential is persisted for a retry. Remote revocation cannot be
      // guaranteed offline; issued JWTs may remain valid until their expiry.
    }
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _scoped.dispose();
  }
}
