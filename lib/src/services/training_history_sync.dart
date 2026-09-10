import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/training_history.dart';
import 'uuid.dart';

/// Each request pins both its bearer and ownership filter to this account.
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
    // The account limit is explicit; paginate below PostgREST's row ceiling.
    for (var offset = 0; offset < limit; offset += 500) {
      final rows = await _client
          .from('training_history')
          .select('id,finished_at,session')
          .eq('user_id', _userId)
          .order('finished_at', ascending: false)
          .order('id')
          .range(offset, offset + 499)
          .setHeader('Authorization', authorization);
      result.addAll(rows.map(TrainingHistoryEntry.fromRow));
      if (rows.length < 500) break;
    }
    return List.unmodifiable(result);
  }

  Future<void> insert(TrainingHistoryEntry entry) async {
    final validated = TrainingHistoryEntry.fromRow(entry.toRow());
    final authorization = await _authorization();
    await _client
        .from('training_history')
        .upsert(
          {'user_id': _userId, ...validated.toRow()},
          onConflict: 'user_id,id',
          ignoreDuplicates: true,
        )
        .setHeader('Authorization', authorization);
  }

  Future<void> delete(String id) async {
    if (!isUuidShape(id)) {
      throw const FormatException('Invalid training history ID');
    }
    final authorization = await _authorization();
    await _client
        .from('training_history')
        .delete()
        .eq('user_id', _userId)
        .eq('id', id)
        .setHeader('Authorization', authorization);
  }
}
