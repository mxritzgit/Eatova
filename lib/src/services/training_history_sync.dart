import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/training_history.dart';

/// Loads the training history. Each request pins both its bearer and
/// ownership filter to this account; completions and deletions are durable
/// sync operations (`SyncOperationSync`).
class TrainingHistorySync {
  TrainingHistorySync(this._client, this._userId);
  final SupabaseClient _client;
  final String _userId;
  static const limit = 2000;

  Future<String> _authorization() async {
    var session = _client.auth.currentSession;
    if (session != null && session.user.id != _userId) {
      throw const AuthException('Session changed');
    }
    if (session != null && session.isExpired) {
      await _client.auth.refreshSession();
      session = _client.auth.currentSession;
    }
    if (session != null && session.user.id != _userId) {
      throw const AuthException('Session changed');
    }
    return 'Bearer ${session?.accessToken ?? ''}';
  }

  /// Rows fetched per `id=in.(...)` request; keeps the URL a few KB long.
  static const fetchBatch = 100;

  /// Above this many unknown rows one paged full load is cheaper in requests.
  static const maxIncrementalFetch = 300;

  /// Loads the account's history. With [known] rows (this account's own
  /// cache) only a manifest of `id,finished_at` is paged; full rows are
  /// fetched just for ids the cache lacks, and cached ids missing from the
  /// manifest drop out (deleted on another device).
  ///
  /// Reuse is safe because a row never changes after its insert: the client
  /// may only SELECT the table, `record_training_history` inserts an identity
  /// once and deletion moves it to a permanent receipt. A differing
  /// `finished_at` still refetches the row. The manifest is a fresh server
  /// statement, so no cursor or device clock is persisted.
  Future<List<TrainingHistoryEntry>> load({
    Iterable<TrainingHistoryEntry> known = const [],
  }) async {
    final authorization = await _authorization();
    if (known.isEmpty) return _loadAll(authorization);
    final cached = {for (final entry in known) entry.id: entry};
    final manifest = await _page(authorization, 'id,finished_at', (row) {
      final id = row['id'], at = row['finished_at'];
      if (id is! String || at is! String) {
        throw const FormatException('Invalid training history manifest');
      }
      return (id: id, finishedAt: DateTime.parse(at));
    });
    bool reusable(({String id, DateTime finishedAt}) row) =>
        cached[row.id]?.finishedAt.isAtSameMomentAs(row.finishedAt) ?? false;
    final missing = [
      for (final row in manifest)
        if (!reusable(row)) row.id,
    ];
    if (missing.length > maxIncrementalFetch) return _loadAll(authorization);
    final fetched = <String, TrainingHistoryEntry>{};
    for (var start = 0; start < missing.length; start += fetchBatch) {
      final ids = missing.sublist(
        start,
        (start + fetchBatch).clamp(0, missing.length),
      );
      final rows = await _client
          .from('training_history')
          .select('id,finished_at,session')
          .eq('user_id', _userId)
          .inFilter('id', ids)
          .setHeader('Authorization', authorization);
      for (final entry in rows.map(TrainingHistoryEntry.fromRow)) {
        fetched[entry.id] = entry;
      }
    }
    // A row deleted between manifest and fetch is simply absent.
    return List.unmodifiable([
      for (final row in manifest)
        if (fetched[row.id] ?? cached[row.id] case final entry?) entry,
    ]);
  }

  Future<List<TrainingHistoryEntry>> _loadAll(String authorization) => _page(
    authorization,
    'id,finished_at,session',
    TrainingHistoryEntry.fromRow,
  );

  Future<List<T>> _page<T>(
    String authorization,
    String columns,
    T Function(Map<String, dynamic> row) parse,
  ) async {
    final result = <T>[];
    ({String id, String at})? cursor;
    // A changing first page must not shift unread rows past an offset.
    while (result.length < limit) {
      var query = _client
          .from('training_history')
          .select(columns)
          .eq('user_id', _userId);
      if (cursor != null) {
        query = query.or(
          'finished_at.lt.${cursor.at},'
          'and(finished_at.eq.${cursor.at},id.lt.${cursor.id})',
        );
      }
      final rows = await query
          .order('finished_at', ascending: false)
          .order('id', ascending: false)
          .limit(500)
          .setHeader('Authorization', authorization);
      result.addAll(rows.map(parse));
      if (rows.length < 500) break;
      final last = rows.last;
      cursor = (
        id: last['id'] as String,
        at: DateTime.parse(
          last['finished_at'] as String,
        ).toUtc().toIso8601String(),
      );
    }
    return List.unmodifiable(result);
  }
}
