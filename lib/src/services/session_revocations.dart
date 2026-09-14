import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'local_cache.dart';

/// A token-free journal for sessions whose local removal was requested.
/// Disk entries retire only after both session locations prove them absent;
/// the process keeps specific session IDs to reject late SDK events.
class SessionRevocations {
  SessionRevocations(this.key, this.store);

  final String key;
  final Future<KeyValueStore> Function() store;
  final Set<String> _blocked = {};

  // Only the secure slot, legacy slot and current login can need disk entries.
  // An oversized/corrupt journal fails closed instead of discarding revocations.
  static const _maxStoredEntries = 8;
  static final _entry = RegExp(r'^[su]:[a-f0-9]{64}$');

  Future<Set<String>> _read() async {
    final raw = await (await store()).getString(key);
    if (raw == null) return {};
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('Invalid session logout journal');
    }
    if (decoded is! List ||
        decoded.length > _maxStoredEntries ||
        decoded.any(
          (value) =>
              value is! String ||
              (value != 'unknown' && !_entry.hasMatch(value)),
        )) {
      throw const FormatException('Invalid session logout journal');
    }
    final entries = decoded.cast<String>().toSet();
    _blocked.addAll(entries);
    return entries;
  }

  Future<bool> permits(String session) async {
    await _read();
    return !_blocked.contains('unknown') &&
        !_identities(session).any(_blocked.contains);
  }

  Future<void> revoke(Iterable<String> sessions) async {
    final identities = sessions.map((session) => _identities(session).first);
    // Synchronous memory denial also survives a failing journal write.
    _blocked.addAll(identities);
    final entries = await _read()
      ..addAll(identities);
    if (entries.length > _maxStoredEntries) {
      throw StateError('Session logout journal capacity exceeded');
    }
    await _write(entries);
  }

  /// Call only inside the owner's serialized storage queue, after reading
  /// BOTH locations successfully. Never prune from a guessed empty read.
  Future<void> retireAbsent(
    Iterable<String> storedSessions, {
    bool currentSessionGuarded = false,
  }) async {
    final retained = storedSessions.expand(_identities).toSet();
    final entries = await _read();
    if (storedSessions.isNotEmpty) retained.add('unknown');
    final next = entries.intersection(retained);
    if (next.length != entries.length) await _write(next);
    // Broad legacy/unknown identities must not disable later real logins.
    // Once both slots are proved empty, the SDK-current-token predicate
    // rejects late writes; only then can the broad in-process guard retire.
    if (storedSessions.isEmpty && currentSessionGuarded) {
      _blocked.removeWhere(
        (identity) => identity == 'unknown' || identity.startsWith('u:'),
      );
    }
  }

  Future<void> _write(Set<String> entries) async {
    final target = await store();
    final value = jsonEncode(entries.toList()..sort());
    await target.setString(key, value);
    if (await target.getString(key) != value) {
      throw StateError('Session logout journal was not acknowledged');
    }
  }

  static bool sameSession(String first, String second) {
    final left = _identities(first).first;
    final right = _identities(second).first;
    if (left.startsWith('s:') && right.startsWith('s:')) return left == right;
    try {
      final a = jsonDecode(first);
      final b = jsonDecode(second);
      return a is Map &&
          b is Map &&
          a['access_token'] is String &&
          a['access_token'] == b['access_token'];
    } on FormatException {
      return false;
    }
  }

  static List<String> _identities(String session) {
    try {
      final data = jsonDecode(session);
      if (data is! Map) return ['unknown'];
      final user = data['user'];
      final uid = user is Map ? user['id'] : null;
      if (uid is! String || uid.isEmpty) return ['unknown'];
      final userIdentity = 'u:${_digest(uid)}';
      final access = data['access_token'];
      if (access is String) {
        final parts = access.split('.');
        if (parts.length == 3) {
          final payload = jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
          );
          final sid = payload is Map ? payload['session_id'] : null;
          if (sid is String && sid.trim().isNotEmpty && sid.length <= 256) {
            return [
              's:${_digest(jsonEncode([uid, sid]))}',
              userIdentity,
            ];
          }
        }
      }
      // No token hash: token rotation must not escape the fallback denial.
      return [userIdentity];
    } on FormatException {
      return ['unknown'];
    }
  }

  static String _digest(String value) => SHA256Digest()
      .process(Uint8List.fromList(utf8.encode(value)))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
