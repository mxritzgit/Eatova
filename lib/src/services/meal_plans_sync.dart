import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/logged_meal.dart';
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

  Future<void> save(PlannedMeal plan) async {
    final validated = PlannedMeal.fromJson(plan.toJson());
    await userRpc(
      _client,
      _userId,
      'save_planned_meal',
      params: {'p_plan': validated.toJson()},
    );
  }

  Future<void> check(ShoppingCheck check) async {
    final validated = ShoppingCheck.fromJson(check.toJson());
    await userRpc(
      _client,
      _userId,
      'save_shopping_check',
      params: {'p_id': validated.id, 'p_checked': validated.checked},
    );
  }

  Future<void> convert(
    PlannedMeal plan,
    LoggedMeal meal, {
    required bool trackDay,
  }) async {
    PlannedMeal.fromJson(plan.toJson());
    if (!plan.isEaten || meal.id != plan.id || meal.slot != plan.slot) {
      throw const FormatException('Invalid meal conversion');
    }
    await userRpc(
      _client,
      _userId,
      'eat_planned_meal',
      params: {
        'p_plan': plan.toJson(),
        'p_meal': {
          'id': meal.id,
          'logged_at': meal.loggedAt.toUtc().toIso8601String(),
          'local_day': meal.effectiveLocalDay,
          'forced_slot': meal.slot.name,
          'meal_name': meal.result.mealName,
          'calories_kcal': meal.result.caloriesKcal,
          'estimated_g': meal.result.estimatedGrams,
          'protein_g': _macro(meal.result.protein),
          'carbs_g': _macro(meal.result.carbs),
          'fat_g': _macro(meal.result.fat),
          'source_label': meal.result.sourceLabel,
          'payload': mealResultToJson(meal.result),
        },
        'p_track_day': trackDay,
      },
    );
  }

  static double? _macro(String value) => double.tryParse(
    RegExp(
          r'\d+(?:[.,]\d+)?',
        ).firstMatch(value)?.group(0)?.replaceAll(',', '.') ??
        '',
  );
}
