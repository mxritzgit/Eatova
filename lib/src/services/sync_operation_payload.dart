import '../models/logged_meal.dart';
import 'meals_sync.dart';
import 'sync_outbox.dart';

/// Encoded once in the durable start transaction; retries reuse its exact map.
Map<String, dynamic> encodeSyncOperationPayload(SyncOp op) {
  Never corrupt() =>
      throw const FormatException('Invalid sync operation payload');
  switch (op.kind) {
    case SyncOpKind.recipeUpsert:
      final recipe = op.recipe ?? corrupt();
      if (recipe.slug != op.entityId) corrupt();
      return {
        'recipe': recipe.toRow(),
        'expected_revision': op.expectedRevision,
      };
    case SyncOpKind.recipeDelete:
      return {'expected_revision': op.expectedRevision};
    case SyncOpKind.mealInsert:
    case SyncOpKind.mealUpsert:
      final meal = op.meal ?? corrupt();
      if (meal.id != op.entityId) corrupt();
      return {
        'row': _mealRow(meal),
        if (op.kind == SyncOpKind.mealInsert) 'track_day': op.trackDay,
      };
    case SyncOpKind.weightInsert:
      final weight = op.weightKg ?? corrupt();
      final recorded = op.recordedAt ?? corrupt();
      return {
        'row': {
          'id': op.entityId,
          'weight_kg': weight,
          'recorded_at': recorded.toUtc().toIso8601String(),
        },
      };
    case SyncOpKind.favoriteUpsert:
      final favorite = op.favorite ?? corrupt();
      if (favorite.id != op.entityId) corrupt();
      final meal = favorite.result;
      return {
        'row': {
          'favorite_key': favorite.id,
          'meal_name': meal.mealName,
          'calories_kcal': meal.caloriesKcal,
          'estimated_g': meal.estimatedGrams,
          'barcode': meal.barcode,
          'brand': meal.brand,
          'source_label': meal.sourceLabel,
          'payload': mealResultToJson(meal),
          'added_at': favorite.addedAt.toUtc().toIso8601String(),
          'pinned': favorite.pinned,
        },
      };
    case SyncOpKind.profileUpsert:
      return {'row': userProfileToJson(op.profile ?? corrupt())};
    case SyncOpKind.trainingPlanUpsert:
      return {
        'row': (op.trainingPlan ?? corrupt()).toRow(),
        if (op.trainingAdoption) 'adoption': true,
      };
    case SyncOpKind.trainingPlanDelete:
      return {
        if (op.trainingIncarnation != 0) 'incarnation': op.trainingIncarnation,
      };
    case SyncOpKind.trainingHistoryInsert:
      return {'row': (op.trainingHistory ?? corrupt()).toRow()};
    case SyncOpKind.mealPlanUpsert:
      return {'plan': (op.plannedMeal ?? corrupt()).toJson()};
    case SyncOpKind.mealPlanConvert:
      final plan = op.plannedMeal ?? corrupt();
      final meal = op.meal ?? corrupt();
      if (meal.id != plan.id || !plan.isEaten || meal.slot != plan.slot) {
        corrupt();
      }
      return {
        'plan': plan.toJson(),
        'meal': _mealRow(meal),
        'track_day': op.trackDay,
      };
    case SyncOpKind.shoppingCheck:
      return {'checked': (op.shoppingCheckValue ?? corrupt()).checked};
    case SyncOpKind.statsIncrement:
      if (op.statsMeals <= 0 && op.statsWeightLogs <= 0) corrupt();
      return {'meals': op.statsMeals, 'weight_logs': op.statsWeightLogs};
    case SyncOpKind.mealDelete:
    case SyncOpKind.favoriteDelete:
    case SyncOpKind.trainingHistoryDelete:
    case SyncOpKind.trackingDay:
      return const {};
  }
}

Map<String, dynamic> _mealRow(LoggedMeal meal) => {
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
  'barcode': meal.result.barcode,
  'brand': meal.result.brand,
  'source_label': meal.result.sourceLabel,
  'payload': mealResultToJson(meal.result),
};

num? _macro(String text) => num.tryParse(
  RegExp(r'\d+(?:[.,]\d+)?').firstMatch(text)?.group(0)?.replaceAll(',', '.') ??
      '',
);
