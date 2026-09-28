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

  Future<List<TrainingHistoryEntry>> load() async {
    final authorization = await _authorization();
    final result = <TrainingHistoryEntry>[];
    TrainingHistoryEntry? cursor;
    // A changing first page must not shift unread rows past an offset.
    while (result.length < limit) {
      var query = _client
          .from('training_history')
          .select('id,finished_at,session')
          .eq('user_id', _userId);
      if (cursor != null) {
        final at = cursor.finishedAt.toIso8601String();
        query = query.or(
          'finished_at.lt.$at,and(finished_at.eq.$at,id.lt.${cursor.id})',
        );
      }
      final rows = await query
          .order('finished_at', ascending: false)
          .order('id', ascending: false)
          .limit(500)
          .setHeader('Authorization', authorization);
      result.addAll(rows.map(TrainingHistoryEntry.fromRow));
      if (rows.length < 500) break;
      cursor = result.last;
    }
    return List.unmodifiable(result);
  }
}
