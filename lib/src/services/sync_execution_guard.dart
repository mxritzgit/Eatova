import 'dart:convert';

import 'package:clock/clock.dart';

import 'key_value_store.dart';
import 'uuid.dart';

const syncSessionKey = 'eatova.v1.sync_session.current';
String syncClaimKey(String userId) => 'eatova.v1.sync_claim.$userId';

String? syncSessionIdFromAccessToken(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final id = claims is Map ? claims['session_id'] : null;
    return id is String && id.isNotEmpty && id.length <= 256 ? id : null;
  } on FormatException {
    return null;
  }
}

Map<String, dynamic>? _object(String? encoded) {
  if (encoded == null) return null;
  try {
    final value = jsonDecode(encoded);
    if (value is Map<String, dynamic>) return value;
  } on FormatException {
    // No JSON or identity in diagnostics.
  }
  throw const FormatException('Invalid sync coordination state');
}

/// Account/session generations and expiring claims are real SQLite CAS fences.
class SyncExecutionGuard {
  SyncExecutionGuard(this.store);

  final AtomicKeyValueStore store;
  static const leaseDuration = Duration(seconds: 60);

  /// A missing/mismatched foreground identity is not mere worker contention.
  Future<bool> hasActiveSession(String userId, String sessionId) async {
    final snapshot = await store.readSnapshot([syncSessionKey]);
    final session = _object(snapshot.values[syncSessionKey]);
    return _matchesSession(session, userId, sessionId);
  }

  static bool _matchesSession(
    Map<String, dynamic>? session,
    String userId,
    String? expectedSessionId,
  ) =>
      session != null &&
      session['owner'] == userId &&
      session['generation'] is String &&
      session['session'] is String &&
      (expectedSessionId == null || session['session'] == expectedSessionId);

  Future<void> activate(
    String userId,
    String sessionId, {
    bool Function()? isCurrentSession,
  }) async {
    if (userId.isEmpty || sessionId.isEmpty) {
      throw ArgumentError('Missing sync identity');
    }
    for (var attempt = 0; attempt < 4; attempt++) {
      if (isCurrentSession != null && !isCurrentSession()) return;
      final snapshot = await store.readSnapshot([syncSessionKey]);
      final current = _object(snapshot.values[syncSessionKey]);
      if (current?['owner'] == userId &&
          current?['session'] == sessionId &&
          current?['generation'] is String) {
        return;
      }
      try {
        if (isCurrentSession != null && !isCurrentSession()) return;
        await store.writeBatch({
          syncSessionKey: jsonEncode({
            'owner': userId,
            'session': sessionId,
            'generation': uuidV4(),
          }),
        }, expectedVersions: snapshot.versions);
        return;
      } on KeyValueConflict {
        // Another engine changed identity. Re-evaluate before replacing it.
      }
    }
    throw const KeyValueConflict();
  }

  Future<void> invalidate(String userId, {String? expectedSessionId}) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final snapshot = await store.readSnapshot([syncSessionKey]);
      final current = _object(snapshot.values[syncSessionKey]);
      if (current == null ||
          current['owner'] != userId ||
          (expectedSessionId != null &&
              current['session'] != expectedSessionId)) {
        return;
      }
      try {
        await store.writeBatch({
          syncSessionKey: null,
        }, expectedVersions: snapshot.versions);
        return;
      } on KeyValueConflict {
        // A stale logout must never invalidate the next account.
      }
    }
    throw const KeyValueConflict();
  }

  /// Invalidates the ended session and fences its subsequent namespace purge.
  /// A newer login of the same account must keep both its generation and data.
  Future<Map<String, int>?> invalidateForPurge(
    String userId, {
    String? expectedSessionId,
  }) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final snapshot = await store.readSnapshot([syncSessionKey]);
      final current = _object(snapshot.values[syncSessionKey]);
      if (current?['owner'] != userId) return snapshot.versions;
      if (expectedSessionId != null &&
          current?['session'] != expectedSessionId) {
        return null;
      }
      try {
        final committed = await store.writeBatch({
          syncSessionKey: null,
        }, expectedVersions: snapshot.versions);
        return committed.versions;
      } on KeyValueConflict {
        // Re-read identity; never apply old logout intent to a new session.
      }
    }
    throw const KeyValueConflict();
  }

  Future<SyncExecutionClaim?> tryClaim(
    String userId, {
    String? expectedSessionId,
  }) async {
    final key = syncClaimKey(userId);
    final snapshot = await store.readSnapshot([syncSessionKey, key]);
    final session = _object(snapshot.values[syncSessionKey]);
    if (!_matchesSession(session, userId, expectedSessionId)) {
      return null;
    }
    final activeSession = session!;
    final prior = _object(snapshot.values[key]);
    if (prior != null && prior['generation'] == activeSession['generation']) {
      final expiresAt = DateTime.tryParse(
        prior['expires_at']?.toString() ?? '',
      );
      if (expiresAt == null) throw const FormatException('Invalid sync claim');
      if (clock.now().toUtc().isBefore(expiresAt)) return null;
    }
    final claim = SyncExecutionClaim._(
      store,
      userId,
      activeSession['session'] as String,
      activeSession['generation'] as String,
      uuidV4(),
      snapshot.versions[syncSessionKey]!,
      clock.now().toUtc().add(leaseDuration),
    );
    try {
      final commit = await store.writeBatch({
        key: claim._encoded,
      }, expectedVersions: snapshot.versions);
      claim._version = commit.versions[key]!;
      return claim;
    } on KeyValueConflict {
      return null;
    }
  }
}

class SyncExecutionClaim {
  SyncExecutionClaim._(
    this._store,
    this.userId,
    this.sessionId,
    this.generation,
    this._token,
    this._sessionVersion,
    this._expiresAt,
  );

  final AtomicKeyValueStore _store;
  final String userId;
  final String sessionId;
  final String generation;
  final String _token;
  final int _sessionVersion;
  int _version = 0;
  DateTime _expiresAt;
  bool _released = false;
  String get _key => syncClaimKey(userId);
  Map<String, int> get guards => {
    syncSessionKey: _sessionVersion,
    _key: _version,
  };
  String get _encoded => jsonEncode({
    'generation': generation,
    'token': _token,
    'expires_at': _expiresAt.toIso8601String(),
  });

  Future<bool> isCurrent() async {
    if (_released || !clock.now().toUtc().isBefore(_expiresAt)) return false;
    final snapshot = await _store.readSnapshot(guards.keys);
    return guards.entries.every(
      (entry) => snapshot.versions[entry.key] == entry.value,
    );
  }

  Future<bool> renew() async {
    if (!await isCurrent()) return false;
    final previousExpiry = _expiresAt;
    _expiresAt = clock.now().toUtc().add(SyncExecutionGuard.leaseDuration);
    try {
      final commit = await _store.writeBatch({
        _key: _encoded,
      }, expectedVersions: guards);
      _version = commit.versions[_key]!;
      return true;
    } on KeyValueConflict {
      _expiresAt = previousExpiry;
      return false;
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _store.writeBatch({_key: null}, expectedVersions: guards);
    } on KeyValueConflict {
      // A late worker cannot erase a newer owner's claim.
    }
  }
}
