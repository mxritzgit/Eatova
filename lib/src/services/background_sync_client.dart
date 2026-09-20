import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

/// A snapshot of the existing secure session; it contains no refresh token.
class BackgroundSyncSession {
  BackgroundSyncSession._(
    this.userId,
    this.sessionId,
    this.accessToken,
    this.expiresAt,
  );

  final String userId;
  final String sessionId;
  final String accessToken;
  final DateTime expiresAt;
  static const expiryMargin = Duration(minutes: 2);

  static BackgroundSyncSession? fromPersisted(String? encoded) {
    if (encoded == null || encoded.length > 65536) return null;
    try {
      final data = jsonDecode(encoded);
      if (data is! Map || data['user'] is! Map) return null;
      final user = data['user'] as Map;
      final token = data['access_token'];
      final userId = user['id'];
      if (token is! String || userId is! String || userId.isEmpty) return null;
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (claims is! Map ||
          claims['sub'] != userId ||
          claims['role'] != 'authenticated') {
        return null;
      }
      final sessionId = claims['session_id'];
      final expiry = claims['exp'];
      if (sessionId is! String || sessionId.isEmpty || expiry is! int) {
        return null;
      }
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        expiry * 1000,
        isUtc: true,
      );
      final session = BackgroundSyncSession._(
        userId,
        sessionId,
        token,
        expiresAt,
      );
      return session.isUsable ? session : null;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  bool get isUsable =>
      clock.now().toUtc().add(expiryMargin).isBefore(expiresAt);
}

/// Headless Supabase has no mutable Auth session and can never refresh it.
class BackgroundSyncClient extends SupabaseClient {
  factory BackgroundSyncClient({
    required String url,
    required String anonKey,
    required BackgroundSyncSession session,
    required Future<bool> Function() permitted,
    http.Client? transport,
  }) => BackgroundSyncClient._(
    url: url,
    anonKey: anonKey,
    session: session,
    permitted: permitted,
    transport: _GuardedSyncTransport(
      Uri.parse(url),
      session,
      permitted,
      transport ?? http.Client(),
    ),
  );

  BackgroundSyncClient._({
    required String url,
    required String anonKey,
    required this.session,
    required Future<bool> Function() permitted,
    required _GuardedSyncTransport transport,
  }) : _permitted = permitted,
       _ownedTransport = transport,
       super(
         url,
         anonKey,
         authOptions: const AuthClientOptions(autoRefreshToken: false),
         postgrestOptions: const PostgrestClientOptions(
           requestTimeout: Duration(seconds: 12),
         ),
         accessToken: () async {
           if (!session.isUsable || !await permitted()) {
             throw const AuthException('Background session unavailable');
           }
           return session.accessToken;
         },
         httpClient: transport,
       );

  final BackgroundSyncSession session;
  final Future<bool> Function() _permitted;
  final _GuardedSyncTransport _ownedTransport;

  @override
  Future<void> dispose() async {
    // Supabase deliberately leaves injected HTTP clients open.
    _ownedTransport.close();
    await super.dispose();
  }

  Future<String> authorizationFor(String userId) async {
    if (userId != session.userId || !session.isUsable || !await _permitted()) {
      throw const AuthException('Background session unavailable');
    }
    return 'Bearer ${session.accessToken}';
  }
}

class _GuardedSyncTransport extends http.BaseClient {
  _GuardedSyncTransport(this.origin, this.session, this.permitted, this.inner);

  final Uri origin;
  final BackgroundSyncSession session;
  final Future<bool> Function() permitted;
  final http.Client inner;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final target = request.url;
    if (_closed ||
        target.origin != origin.origin ||
        !target.path.startsWith('/rest/v1/') ||
        !session.isUsable ||
        !await permitted()) {
      throw const AuthException('Background session unavailable');
    }
    return inner.send(request);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    inner.close();
  }
}
