import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/lifetime_stats.dart';
import '../models/planned_meal.dart';
import '../models/recipe_mutation_result.dart';
import '../models/training_plan.dart';
import '../models/training_plan_head.dart';
import 'meal_plans_sync.dart';
import 'sync_outbox.dart';
import 'sync_operation_payload.dart';
import 'user_rpc.dart';
import 'uuid.dart';

export '../models/recipe_mutation_result.dart';
export '../models/training_plan_head.dart';

enum SyncCapacityKind { recipeHistory, operationReceipts, trainingHeads }

class SyncCapacityException implements Exception {
  const SyncCapacityException(this.kind);
  final SyncCapacityKind kind;
  @override
  String toString() => 'Sync storage capacity reached';
}

/// Capacity failures require a visible retained/blocked state, not timed retries.
Never rethrowSyncFailure(PostgrestException error) {
  if (error.code == 'PT507') {
    throw SyncCapacityException(switch (error.message) {
      'EX_RECIPE_HISTORY_CAPACITY' => SyncCapacityKind.recipeHistory,
      'EX_TRAINING_HEAD_CAPACITY' => SyncCapacityKind.trainingHeads,
      _ => SyncCapacityKind.operationReceipts,
    });
  }
  throw error;
}

/// The same account-pinned transport serves foreground and background replay.
/// There is deliberately no fallback to unversioned table writes.
class SyncOperationSync {
  SyncOperationSync(this._client, this._userId);
  final SupabaseClient _client;
  final String _userId;

  Future<TrainingPlanHead?> loadTrainingPlanHead(String sourceId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,94}$').hasMatch(sourceId)) {
      throw const FormatException('Invalid training source');
    }
    final response = await userRpc(
      _client,
      _userId,
      'load_training_plan_head',
      params: {'p_source_id': sourceId},
    );
    if (response == null) return null;
    if (response is! Map) throw const FormatException('Invalid training head');
    final head = TrainingPlanHead.fromJson(response);
    if (head.sourceId != sourceId || !head.deleted && head.plan == null) {
      throw const FormatException('Mismatched training head');
    }
    return head;
  }

  /// Resolves a view whose operation was acknowledged by another engine.
  /// A missing receipt is unresolved; this read never resubmits a mutation.
  Future<SyncOperationReceipt?> loadReceipt(String operationId) async {
    if (!isUuidShape(operationId)) {
      throw const FormatException('Invalid sync operation identity');
    }
    final response = await userRpc(
      _client,
      _userId,
      'load_sync_operation_receipt',
      params: {'p_operation_id': operationId},
    );
    if (response == null) return null;
    if (response is! Map) throw const FormatException('Invalid sync receipt');
    final receipt = SyncOperationReceipt.fromJson(
      response.cast<String, dynamic>(),
    );
    if (receipt.operationId != operationId) {
      throw const FormatException('Mismatched sync receipt');
    }
    _validateReceiptState(receipt);
    return receipt;
  }

  Future<SyncOperationReceipt> apply(SyncOp operation) async {
    if (!isUuidShape(operation.operationId)) {
      throw const FormatException('Invalid sync operation identity');
    }
    final dynamic response;
    try {
      response = await userRpc(
        _client,
        _userId,
        'apply_sync_operation',
        params: {
          'p_operation_id': operation.operationId,
          'p_kind': operation.kind.name,
          'p_entity_id': operation.entityId,
          'p_payload':
              operation.wirePayload ?? encodeSyncOperationPayload(operation),
          if (operation.kind == SyncOpKind.trainingPlanUpsert ||
              operation.kind == SyncOpKind.trainingPlanDelete)
            'p_training_protocol': 2,
        },
      );
    } on PostgrestException catch (error) {
      rethrowSyncFailure(error);
    }
    if (response is! Map) throw const FormatException('Invalid sync receipt');
    final receipt = SyncOperationReceipt.fromJson(
      response.cast<String, dynamic>(),
    );
    if (receipt.operationId != operation.operationId ||
        receipt.kind != operation.kind ||
        receipt.entityId != operation.entityId) {
      throw const FormatException('Mismatched sync receipt');
    }
    _validateReceiptState(receipt);
    if ((operation.kind == SyncOpKind.trainingPlanUpsert ||
            operation.kind == SyncOpKind.trainingPlanDelete) &&
        receipt.trainingMutation?.incarnation !=
            operation.trainingIncarnation) {
      throw const FormatException('Mismatched training mutation');
    }
    return receipt;
  }

  void _validateReceiptState(SyncOperationReceipt receipt) {
    if (receipt.trainingHead != null &&
            receipt.trainingHead!.planId != receipt.entityId ||
        receipt.trainingPlan != null &&
            receipt.trainingPlan!.id != receipt.entityId ||
        receipt.trainingHead != null &&
            receipt.trainingPlan != null &&
            (receipt.trainingHead!.deleted ||
                receipt.trainingHead!.incarnation !=
                    receipt.trainingPlan!.incarnation)) {
      throw const FormatException('Invalid training receipt identity');
    }
    final recipe = receipt.recipeMutation;
    if ((receipt.kind == SyncOpKind.recipeUpsert ||
            receipt.kind == SyncOpKind.recipeDelete) &&
        (recipe == null ||
            recipe.currentRecipe?.slug != null &&
                recipe.currentRecipe!.slug != receipt.entityId)) {
      throw const FormatException('Invalid canonical recipe identity');
    }
    if (recipe?.savedRecipe case final saved?) {
      final expected = recipe!.outcome == RecipeMutationOutcome.conflictSaved
          ? 'user_conflict_${receipt.operationId}'
          : receipt.entityId;
      if (saved.slug != expected) {
        throw const FormatException('Invalid saved recipe identity');
      }
    }
    if (receipt.currentRecipeState != null &&
            receipt.currentRecipeState!.slug != receipt.entityId ||
        receipt.currentSavedRecipeState != null &&
            receipt.currentSavedRecipeState!.slug !=
                recipe?.savedRecipe?.slug) {
      throw const FormatException('Invalid current recipe identity');
    }
    if (receipt.plannedMeal != null &&
            receipt.plannedMeal!.id != receipt.entityId ||
        receipt.mealPlanConversion != null &&
            receipt.mealPlanConversion!.plan.id != receipt.entityId) {
      throw const FormatException('Invalid planned meal receipt identity');
    }
  }
}

class SyncOperationReceipt {
  const SyncOperationReceipt({
    required this.operationId,
    required this.kind,
    required this.entityId,
    this.lifetimeStats,
    this.mealPlanConversion,
    this.recipeMutation,
    this.plannedMeal,
    this.currentRecipeState,
    this.currentSavedRecipeState,
    this.entityDeleted = false,
    this.convertedMealDeleted = false,
    this.trainingHead,
    this.trainingPlan,
    this.trainingMutation,
  });
  final String operationId;
  final SyncOpKind kind;
  final String entityId;
  final LifetimeStats? lifetimeStats;
  final MealPlanConversion? mealPlanConversion;
  final RecipeMutationResult? recipeMutation;
  final PlannedMeal? plannedMeal;
  final RecipeRemoteState? currentRecipeState;
  final RecipeRemoteState? currentSavedRecipeState;
  final bool entityDeleted;
  final bool convertedMealDeleted;
  final TrainingPlanHead? trainingHead;
  final TrainingPlan? trainingPlan;
  final TrainingMutationResult? trainingMutation;

  factory SyncOperationReceipt.fromJson(Map<String, dynamic> json) {
    final id = json['operation_id'];
    final entity = json['entity_id'];
    final result = json['result'];
    final state = json['current_state'];
    if (id is! String ||
        !isUuidShape(id) ||
        entity is! String ||
        entity.isEmpty ||
        result is! Map ||
        state is! Map) {
      throw const FormatException('Invalid sync operation receipt');
    }
    Map<String, dynamic>? value(Map source, String key) {
      final item = source[key];
      if (item == null) return null;
      if (item is! Map) throw const FormatException('Invalid sync result');
      return item.cast<String, dynamic>();
    }

    final stats = value(state, 'lifetime_stats');
    final conversion = value(result, 'meal_plan_conversion');
    final recipe = value(result, 'recipe_mutation');
    final plan = value(state, 'planned_meal');
    final currentRecipe = value(state, 'recipe');
    final savedRecipe = value(state, 'saved_recipe');
    final trainingHead = value(state, 'training_head');
    final trainingPlan = value(state, 'training_plan');
    final trainingMutation = value(result, 'training_mutation');
    final deleted = state['entity_deleted'];
    final mealDeleted = state['meal_deleted'];
    if (deleted != null && deleted is! bool ||
        mealDeleted != null && mealDeleted is! bool) {
      throw const FormatException('Invalid deletion receipt');
    }
    final kinds = SyncOpKind.values.where((kind) => kind.name == json['kind']);
    if (kinds.isEmpty) throw const FormatException('Invalid sync receipt kind');
    final kind = kinds.first;
    if (trainingMutation != null &&
        (!state.containsKey('training_head') ||
            !state.containsKey('training_plan') ||
            deleted == false && trainingPlan == null)) {
      throw const FormatException('Incomplete training projection');
    }
    final requiredResultPresent = switch (kind) {
      SyncOpKind.recipeUpsert || SyncOpKind.recipeDelete =>
        recipe != null &&
            currentRecipe != null &&
            (recipe['saved_recipe'] == null || savedRecipe != null),
      SyncOpKind.mealInsert => stats != null || deleted == true,
      SyncOpKind.weightInsert ||
      SyncOpKind.statsIncrement ||
      SyncOpKind.trackingDay => stats != null,
      SyncOpKind.mealPlanConvert =>
        (conversion != null || deleted == true) &&
            mealDeleted is bool &&
            plan != null,
      SyncOpKind.mealPlanUpsert => plan != null,
      SyncOpKind.mealUpsert ||
      SyncOpKind.mealDelete ||
      SyncOpKind.trainingPlanUpsert ||
      SyncOpKind.trainingPlanDelete ||
      SyncOpKind.trainingHistoryInsert ||
      SyncOpKind.trainingHistoryDelete => deleted is bool,
      _ => true,
    };
    if (!requiredResultPresent) {
      throw const FormatException('Incomplete sync receipt');
    }
    return SyncOperationReceipt(
      operationId: id,
      kind: kind,
      entityId: entity,
      lifetimeStats: stats == null ? null : LifetimeStats.fromRow(stats),
      mealPlanConversion: conversion == null
          ? null
          : MealPlanConversion.fromJson(conversion),
      recipeMutation: recipe == null
          ? null
          : RecipeMutationResult.fromJson(recipe),
      plannedMeal: plan == null ? null : PlannedMeal.fromJson(plan),
      currentRecipeState: currentRecipe == null
          ? null
          : RecipeRemoteState.fromJson(currentRecipe),
      currentSavedRecipeState: savedRecipe == null
          ? null
          : RecipeRemoteState.fromJson(savedRecipe),
      entityDeleted: deleted == true,
      convertedMealDeleted: mealDeleted == true,
      trainingHead: trainingHead == null
          ? null
          : TrainingPlanHead.fromJson(trainingHead),
      trainingPlan: trainingPlan == null
          ? null
          : TrainingPlan.fromRow(trainingPlan),
      trainingMutation: trainingMutation == null
          ? null
          : TrainingMutationResult.fromJson(trainingMutation),
    );
  }
}
