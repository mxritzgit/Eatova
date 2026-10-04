import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/training_plan.dart';

/// Loads explicitly accepted training plans. Writes are durable sync
/// operations (`SyncOperationSync`); there is no direct table write.
class TrainingPlansSync {
  TrainingPlansSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  // Matches the database's per-account limit, so the library is complete.
  static const int plansLimit = 200;

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

  Future<List<TrainingPlan>> load() async {
    final authorization = await _authorization();
    final rows = await _client
        .from('training_plans')
        .select('id,plan,exercise_ids,source_id,incarnation')
        .eq('user_id', _userId)
        .order('updated_at', ascending: false)
        .order('id')
        .limit(plansLimit)
        .setHeader('Authorization', authorization);
    return List.unmodifiable(rows.map(TrainingPlan.fromRow));
  }
}
