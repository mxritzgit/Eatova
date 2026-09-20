import 'eatova_sync.dart';
import 'local_cache.dart';
import 'sync_outbox.dart';
import 'sync_operation_sync.dart';
import 'sync_error_messages.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// A timed-out request remains pending: its server outcome is unknown.
const kSyncOperationTimeout = Duration(seconds: 20);

SyncBlockedReason? blockedReasonForSyncError(
  Object error, {
  int attempts = 0,
  SyncOpKind? kind,
}) {
  if (error is SyncCapacityException) return SyncBlockedReason.capacity;
  if (error is PostgrestException &&
      {'PGRST202', 'PGRST204', '42883', '42703'}.contains(error.code)) {
    return SyncBlockedReason.backendUnavailable;
  }
  if (error is FormatException ||
      classifyOutboxFailure(error, attempts, kind: kind) ==
          OutboxVerdict.drop) {
    return SyncBlockedReason.rejected;
  }
  return null;
}

/// Shared foreground/headless transport. Receipt parsing validates op identity;
/// callers acknowledge it only within their still-current database claim.
Future<LocalSyncResult> dispatchSyncOp(EatovaSync sync, SyncOp op) async {
  final receipt = await sync.operations
      .apply(op)
      .timeout(kSyncOperationTimeout);
  final recipe = receipt.recipeMutation;
  final conversion = receipt.mealPlanConversion;
  return LocalSyncResult(
    stats: receipt.lifetimeStats ?? conversion?.stats,
    plan: receipt.plannedMeal,
    meal: receipt.convertedMealDeleted ? null : conversion?.meal,
    convertedMealDeleted: receipt.convertedMealDeleted,
    recipe: receipt.currentSavedRecipeState?.recipe,
    currentRecipe: receipt.currentRecipeState?.recipe,
    recipeRevision: receipt.currentRecipeState?.revision,
    recipeDeleted: receipt.currentRecipeState?.deleted ?? false,
    recipeBaseRevision:
        recipe?.savedRecipe?.serverRevision ?? recipe?.currentRevision,
    recipeBaseSlug: recipe?.savedRecipe?.slug,
    deletedRecipeSlug: receipt.currentSavedRecipeState?.deleted == true
        ? receipt.currentSavedRecipeState!.slug
        : null,
    recipeOutcome: recipe?.outcome.name,
    historyDeleted:
        receipt.entityDeleted &&
        (op.kind == SyncOpKind.trainingHistoryInsert ||
            op.kind == SyncOpKind.trainingHistoryDelete),
    entityDeleted: receipt.entityDeleted,
    trainingHead: receipt.trainingHead,
    trainingPlan: receipt.trainingPlan,
    trainingHeadConflict:
        receipt.trainingMutation?.outcome ==
        TrainingMutationOutcome.headConflict,
  );
}
