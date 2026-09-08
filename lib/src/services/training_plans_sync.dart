import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/training_plan.dart';

/// Account-scoped persistence for explicitly accepted training plans.
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
        .select('id,plan')
        .eq('user_id', _userId)
        .order('updated_at', ascending: false)
        .order('id')
        .limit(plansLimit)
        .setHeader('Authorization', authorization);
    return List.unmodifiable(rows.map(TrainingPlan.fromRow));
  }

  Future<void> upsert(TrainingPlan plan) async {
    // Keep the same validation contract as persisted rows and retry payloads.
    final validated = TrainingPlan.fromRow(plan.toRow());
    final authorization = await _authorization();
    await _client
        .from('training_plans')
        .upsert({
          'user_id': _userId,
          ...validated.toRow(),
        }, onConflict: 'user_id,id')
        .setHeader('Authorization', authorization);
  }

  Future<void> delete(String id) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('Invalid training plan ID');
    }
    final authorization = await _authorization();
    await _client
        .from('training_plans')
        .delete()
        .eq('id', id)
        .eq('user_id', _userId)
        .setHeader('Authorization', authorization);
  }
}
