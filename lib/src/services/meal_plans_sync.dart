import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/logged_meal.dart';
import '../models/lifetime_stats.dart';
import '../models/planned_meal.dart';
import 'meals_sync.dart';
import 'user_rpc.dart';

class MealPlansSync {
  MealPlansSync(this._client, this._userId);
  final SupabaseClient _client;
  final String _userId;

  Future<({List<PlannedMeal> plans, List<ShoppingCheck> checks})> load() async {
    final value = await userRpc(_client, _userId, 'load_meal_plan');
    final json = (value as Map).cast<String, dynamic>();
    return (
      plans: (json['plans'] as List)
          .map(
            (row) => PlannedMeal.fromJson((row as Map).cast<String, dynamic>()),
          )
          .toList(),
      checks: (json['checks'] as List)
          .map(
            (row) =>
                ShoppingCheck.fromJson((row as Map).cast<String, dynamic>()),
          )
          .toList(),
    );
  }
}

class MealPlanConversion {
  const MealPlanConversion({
    required this.plan,
    required this.meal,
    required this.stats,
    required this.created,
  });
  final PlannedMeal plan;
  final LoggedMeal? meal;
  final LifetimeStats stats;
  final bool created;
  factory MealPlanConversion.fromJson(Map<String, dynamic> json) {
    final plan = PlannedMeal.fromJson(
      (json['plan'] as Map).cast<String, dynamic>(),
    );
    final raw = json['meal'];
    final meal = raw == null
        ? null
        : LoggedMeal(
            id: raw['id'] as String,
            loggedAt: DateTime.parse(raw['logged_at'] as String).toLocal(),
            localDay: raw['local_day'] as String?,
            forcedSlot: raw['forced_slot'] == null
                ? null
                : MealSlot.values.byName(raw['forced_slot'] as String),
            result: mealResultFromJson(
              (raw['payload'] as Map).cast<String, dynamic>(),
            ),
          );
    final created = json['created'];
    if (!plan.isEaten ||
        (meal != null && meal.id != plan.id) ||
        created is! bool) {
      throw const FormatException('Invalid conversion receipt');
    }
    return MealPlanConversion(
      plan: plan,
      meal: meal,
      stats: LifetimeStats.fromRow(
        (json['stats'] as Map).cast<String, dynamic>(),
      ),
      created: created,
    );
  }
}
