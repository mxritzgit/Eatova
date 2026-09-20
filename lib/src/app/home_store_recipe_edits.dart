part of 'home_store.dart';

class _RecipeEditStateChanged implements Exception {}

class _RecipeEditWatch {
  _RecipeEditWatch(this.operation);
  SyncOp operation;
  late final RecipeSaveHandle handle;
  late final VoidCallback listener;
  bool committed = false;
  bool acknowledged = false;
  bool refreshing = false;
  bool resolvedExternally = false;
  String? resolvedSlug;
  List<FitnessRecipe>? observedRecipes;
}

/// Only an open detail route owns a watch. Other mutations create no observers.
mixin _HomeStoreRecipeEditsPart
    on _HomeStoreBase, _HomeStoreSyncPart, _HomeStoreMealsPart {
  final _recipeEditWatches = <String, _RecipeEditWatch>{};

  @visibleForTesting
  int get activeRecipeEditWatches => _recipeEditWatches.length;

  Future<RecipeSaveResult> editUserRecipe(FitnessRecipe recipe) async {
    _RecipeEditWatch? watch;
    try {
      final delivery = await _saveRecipeDraft(
        recipe,
        requireExisting: true,
        observeOperation: (operation) => watch = _watchRecipeEdit(operation),
      );
      final active = watch!;
      active.committed = true;
      if (sync == null) {
        active.acknowledged = true;
        active.resolvedSlug = recipe.slug;
      }
      _refreshRecipeEditFromStore(active);
      return RecipeSaveResult(delivery: delivery, handle: active.handle);
    } catch (_) {
      watch?.handle.dispose();
      rethrow;
    }
  }

  _RecipeEditWatch _watchRecipeEdit(SyncOp operation) {
    final watch = _RecipeEditWatch(operation);
    watch.listener = () => _refreshRecipeEditFromStore(watch);
    watch.handle = RecipeSaveHandle(
      operationId: operation.operationId,
      initial: RecipeSaveState(recipe: operation.recipe, pending: true),
      refresh: () => _resolveRecipeEditReceipt(watch),
      onDispose: () {
        _recipeEditWatches.remove(operation.operationId);
        removeListener(watch.listener);
      },
    );
    _recipeEditWatches[operation.operationId] = watch;
    addListener(watch.listener);
    return watch;
  }

  FitnessRecipe? _recipeForEdit(String slug) =>
      _userRecipes.where((recipe) => recipe.slug == slug).firstOrNull;

  FitnessRecipe? _pendingRecipeForEdit(SyncOp operation) {
    final latest = _outbox
        .where((op) => op.entityKey == operation.entityKey)
        .lastOrNull;
    if (latest?.kind == SyncOpKind.recipeDelete) return null;
    return _recipeForEdit(operation.entityId) ??
        latest?.recipe ??
        operation.recipe;
  }

  void _refreshRecipeEditFromStore(_RecipeEditWatch watch) {
    if (_disposed || watch.handle.isDisposed) return;
    final pending = _outbox
        .where(
          (operation) => operation.operationId == watch.operation.operationId,
        )
        .firstOrNull;
    if (pending != null && !watch.acknowledged) {
      watch.committed = true;
      watch.operation = pending;
      watch.observedRecipes = _userRecipes;
      watch.handle.publish(
        RecipeSaveState(
          recipe: _pendingRecipeForEdit(pending),
          targetSlug: pending.entityId,
          pending: true,
          conflictSaved: watch.handle.value.conflictSaved,
        ),
      );
      return;
    }
    if (!watch.committed) return;
    if (watch.acknowledged) {
      if (identical(watch.observedRecipes, _userRecipes)) return;
      if (watch.resolvedExternally) {
        watch.observedRecipes = _userRecipes;
        unawaited(_resolveRecipeEditReceipt(watch));
        return;
      }
      watch.observedRecipes = _userRecipes;
      final current = _recipeForEdit(watch.resolvedSlug!);
      final shown = watch.handle.value.recipe;
      // A server receipt can be newer than the store's still-hydrating mirror.
      if (current != null &&
          shown != null &&
          (current.serverRevision ?? 0) < (shown.serverRevision ?? 0)) {
        return;
      }
      watch.handle.publish(
        RecipeSaveState(
          recipe: current,
          targetSlug: watch.resolvedSlug,
          pending: false,
          conflictSaved: watch.handle.value.conflictSaved,
        ),
      );
      return;
    }
    watch.handle.publish(
      RecipeSaveState(
        recipe: watch.handle.value.recipe,
        targetSlug: watch.handle.value.targetSlug,
        pending: true,
        resolving: true,
        conflictSaved: watch.handle.value.conflictSaved,
      ),
    );
    // Foreground ACK notifies just after store publication. Give that exact
    // receipt priority; a headless ACK instead needs the owner-scoped read.
    scheduleMicrotask(() {
      if (!watch.acknowledged && !watch.handle.isDisposed) {
        unawaited(_resolveRecipeEditReceipt(watch));
      }
    });
  }

  @override
  void _notifyRecipeSaveAcknowledged(SyncOp operation, LocalSyncResult result) {
    final watch = _recipeEditWatches[operation.operationId];
    if (watch == null || watch.handle.isDisposed) return;
    watch.operation = operation;
    watch.committed = true;
    watch.acknowledged = true;
    watch.resolvedSlug =
        result.recipeBaseSlug ?? result.recipe?.slug ?? operation.entityId;
    watch.observedRecipes = _userRecipes;
    watch.handle.publish(
      RecipeSaveState(
        recipe: _recipeForEdit(watch.resolvedSlug!),
        targetSlug: watch.resolvedSlug,
        pending: false,
        conflictSaved: result.recipeOutcome == 'conflictSaved',
      ),
    );
  }

  Future<void> _resolveRecipeEditReceipt(
    _RecipeEditWatch watch, {
    bool retryStateChange = true,
  }) async {
    if (_disposed ||
        watch.handle.isDisposed ||
        watch.refreshing ||
        !watch.committed ||
        sync == null) {
      return;
    }
    watch.refreshing = true;
    var changed = false;
    try {
      _ensureMutationActive();
      final cache = _cache!;
      final beforeGeneration = _localCommitGeneration;
      final before = await cache.readMutationSnapshot();
      _ensureMutationActive();
      if (watch.handle.isDisposed) return;
      final stillPending = before.operations
          .where((op) => op.operationId == watch.operation.operationId)
          .firstOrNull;
      if (stillPending != null) {
        watch.operation = stillPending;
        _publishRecipeEditSnapshot(before, beforeGeneration);
        _refreshRecipeEditFromStore(watch);
        return;
      }
      watch.handle.publish(
        RecipeSaveState(
          recipe: watch.handle.value.recipe,
          targetSlug: watch.handle.value.targetSlug,
          pending: true,
          resolving: true,
          conflictSaved: watch.handle.value.conflictSaved,
        ),
      );
      final receipt = await sync!.operations
          .loadReceipt(watch.operation.operationId)
          .timeout(kSyncOperationTimeout);
      _ensureMutationActive();
      if (watch.handle.isDisposed || receipt == null) return;
      if (receipt.kind != SyncOpKind.recipeUpsert ||
          receipt.recipeMutation == null) {
        throw const FormatException('Unexpected recipe edit receipt');
      }
      final saved = receipt.currentSavedRecipeState;
      final target = saved?.slug ?? receipt.recipeMutation!.savedRecipe?.slug;
      if (target == null || saved == null) {
        throw const FormatException('Missing current saved recipe');
      }
      // A headless worker may have ACKed while this store's mirror slept.
      // Read queue and recipes together; never publish over a local commit.
      final generation = _localCommitGeneration;
      final durable = await cache.readMutationSnapshot();
      _ensureMutationActive();
      if (watch.handle.isDisposed) return;
      // Fence the whole HTTP read, including commits from a headless worker.
      // A fresh queue alone cannot detect a successor that has already ACKed.
      if (beforeGeneration != _localCommitGeneration ||
          ['user_recipes', 'outbox', 'recipe_versions'].any((slot) {
            final key = 'eatova.v1.$slot.${cache.userId}';
            return before.snapshot.versions[key] !=
                durable.snapshot.versions[key];
          })) {
        throw _RecipeEditStateChanged();
      }
      // A later local intent remains the displayed truth over an older receipt.
      final newer = durable.operations
          .where(
            (op) =>
                op.entityId == target &&
                (op.kind == SyncOpKind.recipeUpsert ||
                    op.kind == SyncOpKind.recipeDelete),
          )
          .lastOrNull;
      final current = newer == null
          ? saved.recipe
          : newer.kind == SyncOpKind.recipeDelete
          ? null
          : newer.recipe;
      watch.acknowledged = true;
      watch.resolvedSlug = target;
      watch.resolvedExternally = true;
      _publishRecipeEditSnapshot(durable, generation);
      watch.observedRecipes = _userRecipes;
      watch.handle.publish(
        RecipeSaveState(
          recipe: current,
          targetSlug: target,
          pending: newer != null,
          conflictSaved:
              receipt.recipeMutation!.outcome.name == 'conflictSaved',
        ),
      );
    } on _RecipeEditStateChanged {
      changed = true;
    } catch (_) {
      // Keep the durable draft until its exact result can be read; guessing an
      // original slug here could edit/delete the wrong side of a conflict.
    } finally {
      watch.refreshing = false;
    }
    if (changed && retryStateChange && !watch.handle.isDisposed) {
      await _resolveRecipeEditReceipt(watch, retryStateChange: false);
    }
  }

  void _publishRecipeEditSnapshot(
    LocalMutationReceipt durable,
    int generation,
  ) {
    if (generation != _localCommitGeneration) {
      throw _RecipeEditStateChanged();
    }
    final recipeKey = 'eatova.v1.user_recipes.${_cache!.userId}';
    final outboxKey = 'eatova.v1.outbox.${_cache!.userId}';
    final encoded = durable.snapshot.values[recipeKey];
    final rows = encoded == null
        ? const []
        : (jsonDecode(encoded) as Map<String, dynamic>)['items'] as List;
    final recipes = rows
        .map(
          (row) => FitnessRecipe.fromRow((row as Map).cast<String, dynamic>()),
        )
        .toList();
    _mutate(() {
      _outbox = durable.operations;
      _userRecipes = recipes;
      _cacheObservedVersions = {
        ..._cacheObservedVersions,
        for (final key in [recipeKey, outboxKey])
          key: durable.snapshot.versions[key]!,
      };
    });
  }

  void _disposeRecipeSaveHandles() {
    for (final watch in _recipeEditWatches.values.toList(growable: false)) {
      watch.handle.dispose();
    }
  }
}
