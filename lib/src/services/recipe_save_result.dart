import 'package:flutter/foundation.dart';

import '../models/fitness_recipe.dart';
import 'sync_error_messages.dart';

/// Current presentation of one committed edit, including a later sync result.
class RecipeSaveState {
  const RecipeSaveState({
    required this.recipe,
    required this.pending,
    this.targetSlug,
    this.resolving = false,
    this.conflictSaved = false,
  });

  final FitnessRecipe? recipe;

  /// Exact resolved identity, retained even when its current state is deleted.
  final String? targetSlug;
  final bool pending;
  final bool resolving;
  final bool conflictSaved;
  bool get canEdit => recipe != null && !resolving;
}

/// Owned by the open detail route; disposing it unregisters all store listeners.
class RecipeSaveHandle extends ValueNotifier<RecipeSaveState> {
  RecipeSaveHandle({
    required this.operationId,
    required RecipeSaveState initial,
    VoidCallback? onDispose,
    Future<void> Function()? refresh,
  }) : _onDispose = onDispose,
       _refresh = refresh,
       super(initial);

  final String operationId;
  final VoidCallback? _onDispose;
  final Future<void> Function()? _refresh;
  bool _disposed = false;
  bool get isDisposed => _disposed;

  void publish(RecipeSaveState state) {
    if (!_disposed) value = state;
  }

  Future<void> refresh() async {
    if (!_disposed) await _refresh?.call();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _onDispose?.call();
    super.dispose();
  }
}

class RecipeSaveResult {
  const RecipeSaveResult({required this.delivery, required this.handle});

  factory RecipeSaveResult.detached(
    FitnessRecipe recipe,
    SyncDelivery delivery,
  ) => RecipeSaveResult(
    delivery: delivery,
    handle: RecipeSaveHandle(
      operationId: '',
      initial: RecipeSaveState(
        recipe: recipe,
        pending: delivery != SyncDelivery.delivered,
      ),
    ),
  );

  final SyncDelivery delivery;
  final RecipeSaveHandle handle;
}
