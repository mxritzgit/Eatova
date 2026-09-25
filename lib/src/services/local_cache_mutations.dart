part of 'local_cache.dart';

/// One acknowledged local database commit. The queue is the committed queue,
/// not a copy of a HomeStore that may have missed another worker's changes.
class LocalMutationReceipt {
  const LocalMutationReceipt(
    this.operations,
    this.snapshot, {
    this.unreadableKeys = const {},
  });
  final List<SyncOp> operations;
  final KeyValueSnapshot snapshot;
  final Set<String> unreadableKeys;
}

/// Server facts applied with removal of exactly one durable operation.
class LocalSyncResult {
  const LocalSyncResult({
    this.stats,
    this.plan,
    this.meal,
    this.recipe,
    this.currentRecipe,
    this.recipeRevision,
    this.recipeDeleted = false,
    this.recipeOutcome,
    this.historyDeleted = false,
    this.entityDeleted = false,
    this.convertedMealDeleted = false,
    this.recipeBaseRevision,
    this.recipeBaseSlug,
    this.deletedRecipeSlug,
    this.trainingHead,
    this.trainingPlan,
    this.trainingHeadConflict = false,
  });
  final LifetimeStats? stats;
  final PlannedMeal? plan;
  final LoggedMeal? meal;
  final FitnessRecipe? recipe;
  final FitnessRecipe? currentRecipe;
  final int? recipeRevision;
  final bool recipeDeleted;
  final String? recipeOutcome;
  final bool historyDeleted;
  final bool entityDeleted;
  final bool convertedMealDeleted;
  final int? recipeBaseRevision;
  final String? recipeBaseSlug;
  final String? deletedRecipeSlug;
  final TrainingPlanHead? trainingHead;
  final TrainingPlan? trainingPlan;
  final bool trainingHeadConflict;
}

/// Keep a bounded optimistic count while a later counting intent is pending.
/// A remote snapshot may already include an ACK-failed intent, so adding the
/// queue length would double count it. The pending count bounds a stale cache.
LifetimeStats reconcileLifetimeStatsWithPending(
  LifetimeStats remote,
  LifetimeStats local,
  Iterable<SyncOp> pending,
) {
  final operations = pending.toList();
  var pendingMeals = 0;
  var pendingWeights = 0;
  for (final op in operations) {
    if (op.blockedReason == SyncBlockedReason.rejected) continue;
    switch (op.kind) {
      case SyncOpKind.mealInsert || SyncOpKind.mealPlanConvert:
        pendingMeals++;
      case SyncOpKind.weightInsert:
        pendingWeights++;
      case SyncOpKind.statsIncrement:
        pendingMeals += math.max(0, op.statsMeals);
        pendingWeights += math.max(0, op.statsWeightLogs);
      default:
        break;
    }
  }
  var reconciled = remote.copyWith(
    mealsLogged: math.min(
      math.max(remote.mealsLogged, local.mealsLogged),
      remote.mealsLogged + pendingMeals,
    ),
    weightLogs: math.min(
      math.max(remote.weightLogs, local.weightLogs),
      remote.weightLogs + pendingWeights,
    ),
  );
  for (final op in operations) {
    if (op.blockedReason == SyncBlockedReason.rejected) continue;
    if (op.trackDay) {
      final meal = op.meal;
      if (meal != null) {
        reconciled = reconciled.recordTrackedDay(meal.loggedAt);
      }
    } else if (op.kind == SyncOpKind.trackingDay) {
      final day = DateTime.tryParse(op.entityId);
      if (day != null) reconciled = reconciled.recordTrackedDay(day);
    }
  }
  return reconciled;
}

extension LocalCacheMutations on LocalCache {
  AtomicKeyValueStore? get atomicStore =>
      _store is AtomicKeyValueStore ? _store : null;
  String get userId => _userId;
  String get _recipeVersionsKey => 'eatova.v1.recipe_versions.$_userId';
  String get _trainingHeadsKey => 'eatova.v1.training_heads.$_userId';

  Set<String> get _mutationKeys => {
    _outboxKey,
    _pendingStatsKey,
    _profileKey,
    _loggedMealsKey,
    _favoritesKey,
    _weightLogKey,
    _userRecipesKey,
    _mealPlansKey,
    _statsKey,
    _trainingPlansKey,
    _trainingSelectionKey,
    _trainingSessionKey,
    _trainingHistoryKey,
    _trainingHistoryDeletionsKey,
    _recipeVersionsKey,
    _trainingHeadsKey,
    _dailyActivityKey,
    _notificationsKey,
    _healthConnectKey,
  };

  /// Strict, consistent snapshot. Corruption is not interpreted as emptiness.
  Future<LocalMutationReceipt> readMutationSnapshot({
    bool allowPartial = false,
  }) async {
    final store = atomicStore;
    if (_closed || store == null) throw StateError('Local storage unavailable');
    final snapshot = await _readSnapshot(
      store,
      _mutationKeys,
      tolerateUnreadable: allowPartial ? _mutationKeys : const {},
    );
    final unreadable = _mutationKeys.difference(snapshot.values.keys.toSet());
    List<SyncOp> operations = const [];
    if (!unreadable.contains(_outboxKey)) {
      try {
        operations = _operations(snapshot.values);
      } catch (_) {
        if (!allowPartial) rethrow;
        unreadable.add(_outboxKey);
      }
    }
    return LocalMutationReceipt(
      operations,
      snapshot,
      unreadableKeys: unreadable,
    );
  }

  Future<KeyValueSnapshot> _readSnapshot(
    AtomicKeyValueStore store,
    Set<String> keys, {
    Set<String> tolerateUnreadable = const {},
  }) async {
    try {
      return await store.readSnapshot(keys);
    } catch (_) {
      if (tolerateUnreadable.isEmpty) rethrow;
      // Probe only after a strict read failed. The final read remains one
      // consistent snapshot of every readable slot, including the outbox.
      final readable = <String>{...keys};
      for (final key in keys.intersection(tolerateUnreadable)) {
        try {
          await store.readSnapshot([key]);
        } catch (_) {
          readable.remove(key);
        }
      }
      return store.readSnapshot(readable);
    }
  }

  Set<String> _keysForOperation(SyncOp op) => switch (op.kind) {
    SyncOpKind.profileUpsert => {_profileKey},
    SyncOpKind.mealInsert ||
    SyncOpKind.mealUpsert ||
    SyncOpKind.mealDelete => {_loggedMealsKey, _statsKey},
    SyncOpKind.favoriteUpsert || SyncOpKind.favoriteDelete => {_favoritesKey},
    SyncOpKind.recipeUpsert ||
    SyncOpKind.recipeDelete => {_userRecipesKey, _recipeVersionsKey},
    SyncOpKind.weightInsert => {_weightLogKey, _statsKey},
    SyncOpKind.mealPlanUpsert || SyncOpKind.shoppingCheck => {_mealPlansKey},
    SyncOpKind.mealPlanConvert => {_mealPlansKey, _loggedMealsKey, _statsKey},
    SyncOpKind.trainingPlanUpsert || SyncOpKind.trainingPlanDelete => {
      _trainingPlansKey,
      _trainingHeadsKey,
      _trainingSelectionKey,
      _trainingSessionKey,
    },
    SyncOpKind.trainingHistoryInsert || SyncOpKind.trainingHistoryDelete => {
      _trainingHistoryKey,
      _trainingHistoryDeletionsKey,
      _trainingSessionKey,
    },
    SyncOpKind.trackingDay || SyncOpKind.statsIncrement => {_statsKey},
  };

  /// Migrates old outbox identities and legacy counter bundles before sending.
  Future<List<SyncOp>> readSyncOperations({
    Map<String, int> guards = const {},
  }) async =>
      (await _atomicMutation((state, queue) {}, guards: guards)).operations;

  Future<LocalMutationReceipt> commitSyncOperations(
    List<SyncOp> intents, {
    Map<String, int> guards = const {},
    String? retireTrainingSessionId,
    String? replacingTrainingAdoption,
    String? expectedTrainingDraftOperationId,
    TrainingPlanHead? resolvedTrainingHead,
  }) => _atomicMutation(
    (state, queue) {
      if (replacingTrainingAdoption != null) {
        final reviewed = trainingAdoptionReviewOps(
          queue,
          replacingTrainingAdoption,
        );
        final old = reviewed.first;
        final next = intents.single;
        if (reviewed.last.operationId !=
                (expectedTrainingDraftOperationId ??
                    replacingTrainingAdoption) ||
            next.entityId != old.entityId ||
            next.trainingPlan?.coachSourceId !=
                old.trainingPlan?.coachSourceId) {
          throw StateError('Training adoption changed');
        }
        final known = _localTrainingHead(state, old.entityId);
        if (known != null &&
            (resolvedTrainingHead == null ||
                known.incarnation > resolvedTrainingHead.incarnation ||
                (known.incarnation == resolvedTrainingHead.incarnation &&
                    known.deleted &&
                    !resolvedTrainingHead.deleted))) {
          throw StateError('Training source changed');
        }
        if (resolvedTrainingHead != null) {
          _recordTrainingHead(state, resolvedTrainingHead);
        }
        final replaced = reviewed.map((op) => op.operationId).toSet();
        queue.removeWhere((op) => replaced.contains(op.operationId));
      }
      for (var op in intents) {
        if (queue.any((old) => old.operationId == op.operationId)) continue;
        if (op.kind == SyncOpKind.trainingPlanDelete &&
            queue.any(
              (old) =>
                  old.entityKey == op.entityKey &&
                  old.blockedReason == SyncBlockedReason.trainingHeadConflict,
            )) {
          throw StateError('Training adoption must be reviewed');
        }
        if (queue.length >= kOutboxMaxOps) {
          throw StateError('Pending changes must sync before saving more');
        }
        if (op.trainingAdoption && replacingTrainingAdoption == null) {
          final head = _localTrainingHead(state, op.entityId);
          if (head != null) {
            op = op.withTrainingIncarnation(
              head.incarnation + (head.deleted ? 1 : 0),
            );
          }
        }
        if (op.kind == SyncOpKind.recipeUpsert ||
            op.kind == SyncOpKind.recipeDelete) {
          final previous = queue
              .where((old) => old.entityKey == op.entityKey)
              .lastOrNull;
          if (previous != null) op = op.withPredecessor(previous.operationId);
        }
        if (op.kind == SyncOpKind.mealDelete ||
            op.kind == SyncOpKind.mealUpsert) {
          final conversion = queue
              .where(
                (pending) =>
                    pending.kind == SyncOpKind.mealPlanConvert &&
                    pending.meal?.id == op.entityId,
              )
              .lastOrNull;
          if (conversion != null) {
            op = op.withPredecessor(conversion.operationId);
          }
        }
        final projected = trainingProjectionOps([...queue, op]).last;
        _projectOperation(state, projected);
        queue.add(op);
      }
      if (retireTrainingSessionId != null) {
        final raw = state[_trainingSessionKey]?['snapshot'];
        final current = raw is Map ? TrainingSessionSnapshot.fromJson(raw) : null;
        if (current?.sessionId == retireTrainingSessionId &&
            current?.pendingCompletionAt == null) {
          state[_trainingSessionKey] = {'snapshot': null};
        }
      }
    },
    guards: guards,
    keys: {
      for (final op in intents) ..._keysForOperation(op),
      if (retireTrainingSessionId != null) _trainingSessionKey,
      if (replacingTrainingAdoption != null) _trainingHeadsKey,
    },
    tolerateUnreadable:
        intents.every((op) => op.kind == SyncOpKind.trainingPlanDelete)
        ? {_trainingPlansKey}
        : const {},
  );

  /// Explicitly discards a rejected draft without issuing a server deletion.
  Future<LocalMutationReceipt> discardTrainingAdoption(
    String operationId, {
    TrainingPlanHead? verifiedHead,
    Map<String, int> guards = const {},
  }) => _atomicMutation(
    (state, queue) {
      final index = queue.indexWhere((op) => op.operationId == operationId);
      if (index < 0) throw StateError('Training adoption changed');
      final rejected = queue[index];
      if (!rejected.trainingAdoption ||
          rejected.blockedReason != SyncBlockedReason.trainingHeadConflict) {
        throw StateError('Training adoption is not rejected');
      }
      if (verifiedHead != null &&
          (verifiedHead.planId != rejected.entityId ||
              verifiedHead.sourceId != rejected.trainingPlan?.coachSourceId)) {
        throw const FormatException('Mismatched training source');
      }
      final discarded = {
        operationId,
        ...queue
            .skip(index + 1)
            .where(
              (op) =>
                  op.entityKey == rejected.entityKey &&
                  op.trainingIncarnation == rejected.trainingIncarnation &&
                  !op.deliveryStarted &&
                  op.wirePayload == null,
            )
            .map((op) => op.operationId),
      };
      queue.removeWhere((op) => discarded.contains(op.operationId));
      final current = _rows(
        state,
        _trainingPlansKey,
        'items',
      ).where((row) => row['id'] == rejected.entityId).firstOrNull;
      final currentGeneration = current == null
          ? -1
          : TrainingPlan.fromRow(current).incarnation;
      if (currentGeneration <= rejected.trainingIncarnation) {
        final known = _localTrainingHead(state, rejected.entityId);
        final restore =
            verifiedHead != null &&
                !verifiedHead.deleted &&
                (known == null ||
                    verifiedHead.incarnation > known.incarnation ||
                    (verifiedHead.incarnation == known.incarnation &&
                        !known.deleted))
            ? verifiedHead.plan
            : null;
        _put(
          state,
          _trainingPlansKey,
          'items',
          'id',
          rejected.entityId,
          restore?.toRow(),
        );
      }
      if (verifiedHead != null) _recordTrainingHead(state, verifiedHead);
      for (final pending in queue) {
        if (pending.entityKey == rejected.entityKey) {
          _projectOperation(state, pending, countStats: false);
        }
      }
      final remaining = _rows(state, _trainingPlansKey, 'items');
      if (state[_trainingSelectionKey]?['id'] == rejected.entityId &&
          !remaining.any((row) => row['id'] == rejected.entityId)) {
        state[_trainingSelectionKey] = {'id': remaining.firstOrNull?['id']};
      }
      final rawSession = state[_trainingSessionKey]?['snapshot'];
      if (rawSession is Map) {
        final checkpoint = TrainingSessionSnapshot.fromJson(rawSession);
        if (checkpoint.pendingCompletionAt == null &&
            checkpoint.plan.id == rejected.entityId &&
            checkpoint.plan.incarnation <= rejected.trainingIncarnation) {
          state[_trainingSessionKey] = {'snapshot': null};
        }
      }
    },
    guards: guards,
    keys: {
      _trainingHeadsKey,
      _trainingPlansKey,
      _trainingSelectionKey,
      _trainingSessionKey,
    },
  );

  /// Locks the exact wire request before HTTP; retries may not change it.
  Future<SyncOp?> startSyncOperation(
    String operationId, {
    Map<String, int> guards = const {},
  }) async {
    SyncOp? started;
    await _atomicMutation((state, queue) {
      started = null;
      final at = queue.indexWhere((op) => op.operationId == operationId);
      if (at < 0) return;
      final op = queue[at];
      if (op.blockedReason != null) return;
      if (queue.take(at).any((older) => older.entityKey == op.entityKey)) {
        return;
      }
      if (op.predecessorId != null) return;
      try {
        started = op.wirePayload != null
            ? op.markDeliveryStarted()
            : op.freezeWirePayload(encodeSyncOperationPayload(op));
        queue[at] = started!;
      } on FormatException {
        queue[at] = op.withBlockedReason(SyncBlockedReason.rejected);
      }
    }, guards: guards);
    return started;
  }

  Future<LocalMutationReceipt> recordSyncFailure(
    String operationId, {
    required bool countAttempt,
    Map<String, int> guards = const {},
    SyncBlockedReason? blockedReason,
  }) => _atomicMutation((state, queue) {
    final at = queue.indexWhere((op) => op.operationId == operationId);
    if (at >= 0 && countAttempt) queue[at] = queue[at].incrementAttempt();
    if (at >= 0 && blockedReason != null) {
      queue[at] = queue[at].withBlockedReason(blockedReason);
    }
  }, guards: guards);

  Future<void> retryBlockedSyncOperations() async {
    await _atomicMutation((state, queue) {
      for (var i = 0; i < queue.length; i++) {
        if (queue[i].blockedReason == SyncBlockedReason.trainingHeadConflict) {
          continue;
        }
        queue[i] = queue[i].withBlockedReason(null);
      }
    });
  }

  /// Acknowledgment, successor rebase and resulting entities are one commit.
  Future<LocalMutationReceipt> acknowledgeSyncOperation(
    String operationId,
    LocalSyncResult result, {
    Map<String, int> guards = const {},
  }) => _atomicMutation(
    (state, queue) {
      final at = queue.indexWhere((op) => op.operationId == operationId);
      if (at < 0) return;
      final delivered = queue[at];
      if (result.trainingHead != null) {
        _recordTrainingHead(state, result.trainingHead!);
      }
      if (result.trainingHeadConflict) {
        queue[at] = delivered.withBlockedReason(
          SyncBlockedReason.trainingHeadConflict,
        );
        for (final pending in trainingProjectionOps(queue)) {
          if (pending.entityKey == delivered.entityKey) {
            _projectOperation(state, pending, countStats: false);
          }
        }
        return;
      }
      queue.removeAt(at);
      final hasNewer = queue.any((op) => op.entityKey == delivered.entityKey);
      if (result.stats != null) {
        state[_statsKey] = LocalCache._statsToJson(
          reconcileLifetimeStatsWithPending(
            result.stats!,
            LifetimeStats.fromRow(state[_statsKey] ?? {}),
            queue,
          ),
        );
      }
      if (result.plan != null && !hasNewer) {
        _put(
          state,
          _mealPlansKey,
          'plans',
          'id',
          result.plan!.id,
          result.plan!.toJson(),
        );
        if (result.meal != null) {
          _put(
            state,
            _loggedMealsKey,
            'items',
            'id',
            result.meal!.id,
            loggedMealToJson(result.meal!),
          );
        }
      }
      if (result.convertedMealDeleted) {
        _put(state, _loggedMealsKey, 'items', 'id', delivered.entityId, null);
      }
      if (result.historyDeleted) {
        _deleteHistory(state, delivered.entityId);
      }
      if (delivered.kind == SyncOpKind.trainingPlanUpsert ||
          delivered.kind == SyncOpKind.trainingPlanDelete) {
        _applyTrainingReceipt(state, delivered, result);
      }
      if (result.entityDeleted) {
        switch (delivered.kind) {
          case SyncOpKind.mealInsert:
          case SyncOpKind.mealUpsert:
          case SyncOpKind.mealDelete:
            _put(
              state,
              _loggedMealsKey,
              'items',
              'id',
              delivered.entityId,
              null,
            );
          case SyncOpKind.trainingPlanUpsert:
          case SyncOpKind.trainingPlanDelete:
            break;
          case SyncOpKind.mealPlanUpsert:
          case SyncOpKind.mealPlanConvert:
            _put(state, _mealPlansKey, 'plans', 'id', delivered.entityId, null);
          default:
            break;
        }
      }
      if (result.recipeRevision == null) {
        for (var i = 0; i < queue.length; i++) {
          if (queue[i].predecessorId != operationId) continue;
          final released = queue[i].withoutPredecessor();
          queue[i] =
              result.entityDeleted &&
                  delivered.kind != SyncOpKind.trainingPlanUpsert &&
                  delivered.kind != SyncOpKind.trainingPlanDelete
              ? released.withBlockedReason(SyncBlockedReason.rejected)
              : released;
        }
      }
      if (result.recipeRevision != null) {
        if (result.deletedRecipeSlug != null) {
          _put(
            state,
            _userRecipesKey,
            'items',
            'slug',
            result.deletedRecipeSlug!,
            null,
          );
        }
        final versions = _object(state, _recipeVersionsKey);
        final old = versions[delivered.entityId];
        final known = old is Map ? old['revision'] as int? ?? 0 : 0;
        if (result.recipeRevision! >= known) {
          versions[delivered.entityId] = {
            'revision': result.recipeRevision,
            'deleted': result.recipeDeleted,
          };
          state[_recipeVersionsKey] = versions;
        }
        if (!hasNewer ||
            (result.recipe != null &&
                result.recipe!.slug != delivered.entityId)) {
          _put(
            state,
            _userRecipesKey,
            'items',
            'slug',
            delivered.entityId,
            result.currentRecipe?.toRow(),
          );
        }
        final saved = result.recipe;
        if (saved != null && (saved.slug != delivered.entityId || !hasNewer)) {
          _put(
            state,
            _userRecipesKey,
            'items',
            'slug',
            saved.slug,
            saved.toRow(),
          );
        }
        for (var i = 0; i < queue.length; i++) {
          final next = queue[i];
          if (next.predecessorId != operationId) continue;
          final successor = next.rebaseRecipe(
            revision:
                result.recipeBaseRevision ??
                saved?.serverRevision ??
                result.recipeRevision!,
            slug: result.recipeBaseSlug ?? saved?.slug,
          );
          queue[i] = successor;
        }
        for (final pending in recipeProjectionOps(queue)) {
          if (pending.kind == SyncOpKind.recipeUpsert ||
              pending.kind == SyncOpKind.recipeDelete) {
            _projectOperation(state, pending, countStats: false);
          }
        }
      }
      if (delivered.kind == SyncOpKind.trainingPlanUpsert ||
          delivered.kind == SyncOpKind.trainingPlanDelete) {
        for (final pending in trainingProjectionOps(queue)) {
          if (pending.entityKey == delivered.entityKey) {
            _projectOperation(state, pending, countStats: false);
          }
        }
      }
    },
    guards: guards,
    keysForQueue: (queue) => {
      for (final op in queue.where((op) => op.operationId == operationId))
        ..._keysForOperation(op),
      if (result.stats != null) _statsKey,
      if (result.plan != null) _mealPlansKey,
      if (result.meal != null || result.convertedMealDeleted) _loggedMealsKey,
      if (result.trainingHead != null) _trainingHeadsKey,
    },
  );

  Future<void> commitTrainingSelection(
    String? id, {
    Map<String, int> guards = const {},
  }) async {
    await _atomicMutation(
      (state, queue) {
        state[_trainingSelectionKey] = {'id': id};
      },
      keys: {_trainingSelectionKey},
      guards: guards,
    );
  }

  /// A checkpoint is valid only for the exact source/session snapshot read
  /// here. A concurrent retirement, even followed by re-adoption, invalidates
  /// this save instead of rebasing the old route onto the replacement source.
  Future<LocalMutationReceipt> commitTrainingCheckpoint(
    TrainingSessionSnapshot? checkpoint, {
    required TrainingSessionSnapshot? expectedSnapshot,
    Map<String, int> guards = const {},
  }) => _atomicMutation(
    (state, queue) {
      final raw = state[_trainingSessionKey]?['snapshot'];
      final current = raw is Map && state[_trainingSessionKey]?['source_change_pending'] != true
          ? TrainingSessionSnapshot.fromJson(raw) : null;
      if (jsonEncode(current?.toJson()) !=
          jsonEncode(expectedSnapshot?.toJson())) {
        throw StateError('Training recovery changed');
      }
      final deleted =
          state[_trainingHistoryDeletionsKey]?['ids'] as List? ?? [];
      final history = state[_trainingHistoryKey]?['items'] as List? ?? [];
      bool completed(String id) =>
          deleted.contains(id) ||
          history.any((entry) => entry is Map && entry['id'] == id);
      if (current?.pendingCompletionAt != null &&
          !completed(current!.sessionId) &&
          jsonEncode(current.toJson()) != jsonEncode(checkpoint?.toJson())) {
        throw StateError('Pending training completion must be retried');
      }
      if (checkpoint != null) {
        if (completed(checkpoint.sessionId)) {
          throw StateError('Training completion retired');
        }
        if (current?.pendingCompletionAt == null) {
          final head = _localTrainingHead(state, checkpoint.plan.id);
          final blocked = queue.any(
            (op) =>
                op.entityId == checkpoint.plan.id &&
                op.trainingIncarnation == checkpoint.plan.incarnation &&
                op.blockedReason == SyncBlockedReason.trainingHeadConflict,
          );
          if (blocked ||
              (head != null &&
                  (head.incarnation > checkpoint.plan.incarnation ||
                      (head.incarnation == checkpoint.plan.incarnation &&
                          head.deleted)))) {
            throw StateError('Training session source changed');
          }
          final pending = queue
              .where(
                (op) =>
                    op.entityId == checkpoint.plan.id &&
                    op.trainingIncarnation >= checkpoint.plan.incarnation &&
                    (op.kind == SyncOpKind.trainingPlanUpsert ||
                        op.kind == SyncOpKind.trainingPlanDelete),
              )
              .lastOrNull;
          final library = state[_trainingPlansKey];
          final rows = library?['items'] as List?;
          final row = rows
              ?.where(
                (entry) => entry is Map && entry['id'] == checkpoint.plan.id,
              )
              .firstOrNull;
          final plan = row is Map
              ? TrainingPlan.fromRow(row.cast<String, dynamic>())
              : null;
          // Legacy best-effort mirrors may lag an already durable full
          // recovery. Its unchanged source remains valid until retirement.
          final preservesRecovery =
              current != null &&
              current.sessionId == checkpoint.sessionId &&
              trainingSessionMatchesPlan(checkpoint, current.plan);
          if ((pending != null &&
                  (pending.isDelete ||
                      !trainingSessionMatchesPlan(
                        checkpoint,
                        pending.trainingPlan,
                      ))) ||
              (library != null &&
                  !trainingSessionMatchesPlan(checkpoint, plan) &&
                  !preservesRecovery)) {
            throw StateError('Training session source changed');
          }
        }
      }
      state[_trainingSessionKey] = {'snapshot': checkpoint?.toJson()};
    },
    keys: {
      _trainingSessionKey,
      _trainingPlansKey,
      _trainingHeadsKey,
      _trainingHistoryKey,
      _trainingHistoryDeletionsKey,
    },
    tolerateUnreadable: {_trainingPlansKey},
    guards: guards,
    retryConflicts: false,
  );

  /// Network hydration updates mirrors without separating them from the
  /// currently durable queue. Newer local intents always overlay the snapshot.
  Future<LocalMutationReceipt> commitStoreSnapshot({
    required Map<String, int> expectedVersions,
    UserProfile? profile,
    LifetimeStats? stats,
    List<LoggedMeal>? meals,
    List<FavoriteMeal>? favorites,
    WeightLog? weightLog,
    List<FitnessRecipe>? recipes,
    List<TrainingPlan>? trainingPlans,
    List<TrainingHistoryEntry>? trainingHistory,
    List<PlannedMeal>? mealPlans,
    Map<String, bool>? shoppingChecks,
  }) => _atomicMutation(
    (state, queue) {
      if (profile != null) state[_profileKey] = userProfileToJson(profile);
      if (stats != null) {
        state[_statsKey] = LocalCache._statsToJson(
          reconcileLifetimeStatsWithPending(
            stats,
            LifetimeStats.fromRow(state[_statsKey] ?? {}),
            queue,
          ),
        );
      }
      if (meals != null) {
        state[_loggedMealsKey] = {
          'items': meals.map(loggedMealToJson).toList(),
        };
      }
      if (favorites != null) {
        state[_favoritesKey] = {
          'items': favorites.map(favoriteMealToJson).toList(),
        };
      }
      if (weightLog != null) {
        state[_weightLogKey] = LocalCache._weightLogToJson(weightLog);
      }
      if (recipes != null) {
        state[_userRecipesKey] = LocalCache._userRecipesToJson(recipes);
      }
      if (trainingPlans != null) {
        state[_trainingPlansKey] = LocalCache._trainingPlansToJson(
          trainingPlans.where((plan) {
            final head = _localTrainingHead(state, plan.id);
            return head == null ||
                plan.incarnation > head.incarnation ||
                (plan.incarnation == head.incarnation && !head.deleted);
          }).toList(),
        );
        for (final plan in trainingPlans) {
          if (plan.coachSourceId != null) {
            _recordTrainingHead(
              state,
              TrainingPlanHead(
                sourceId: plan.coachSourceId!,
                planId: plan.id,
                incarnation: plan.incarnation,
                deleted: false,
                plan: plan,
              ),
            );
          }
        }
      }
      if (trainingHistory != null) {
        state[_trainingHistoryKey] = {
          'items': trainingHistory.map((e) => e.toRow()).toList(),
        };
      }
      if (mealPlans != null) {
        state[_mealPlansKey] = {
          ...?state[_mealPlansKey],
          'plans': mealPlans.map((plan) => plan.toJson()).toList(),
        };
      }
      if (shoppingChecks != null) {
        state[_mealPlansKey] = {
          ...?state[_mealPlansKey],
          'checks': shoppingChecks.entries
              .map((e) => ShoppingCheck(id: e.key, checked: e.value).toJson())
              .toList(),
        };
      }
      for (final op in trainingProjectionOps(recipeProjectionOps(queue))) {
        _projectOperation(
          state,
          op,
          countStats: false,
          updateDependents: false,
        );
      }
    },
    guards: expectedVersions,
    keys: {
      if (profile != null) _profileKey,
      if (stats != null) _statsKey,
      if (meals != null) _loggedMealsKey,
      if (favorites != null) _favoritesKey,
      if (weightLog != null) _weightLogKey,
      if (recipes != null) _userRecipesKey,
      if (trainingPlans != null) _trainingPlansKey,
      if (trainingPlans != null) _trainingHeadsKey,
      if (trainingHistory != null) _trainingHistoryKey,
      if (mealPlans != null || shoppingChecks != null) _mealPlansKey,
    },
  );

  Future<LocalMutationReceipt> _atomicMutation(
    void Function(Map<String, Map<String, dynamic>?> state, List<SyncOp> queue)
    change, {
    Map<String, int> guards = const {},
    Set<String> keys = const {},
    Set<String> Function(List<SyncOp>)? keysForQueue,
    Set<String> tolerateUnreadable = const {},
    bool retryConflicts = true,
  }) {
    final store = atomicStore;
    if (_closed || store == null) {
      return Future.error(StateError('Atomic local storage unavailable'));
    }
    return _trackWrite(() async {
      for (var attempt = 0; attempt < 12; attempt++) {
        if (_closed) throw StateError('Account storage closed');
        final base = await store.readSnapshot({_outboxKey, _pendingStatsKey});
        final initialQueue = _operations(base.values);
        final selectedKeys = {
          _outboxKey,
          _pendingStatsKey,
          ...keys,
          ...?keysForQueue?.call(initialQueue),
          ...guards.keys,
        };
        final snapshot = await _readSnapshot(
          store,
          selectedKeys,
          tolerateUnreadable: tolerateUnreadable,
        );
        if (base.versions.entries.any(
          (entry) => snapshot.versions[entry.key] != entry.value,
        )) {
          continue;
        }
        for (final guard in guards.entries) {
          if (snapshot.versions[guard.key] != guard.value) {
            throw const KeyValueConflict();
          }
        }
        final state = <String, Map<String, dynamic>?>{
          for (final key in selectedKeys.where(snapshot.values.containsKey))
            if (_mutationKeys.contains(key)) key: _decodeMutationSlot(key, snapshot.values[key]),
        };
        final queue = _operations(snapshot.values);
        final pending = state[_pendingStatsKey];
        final meals = pending?['meals'] as int? ?? 0;
        final weights = pending?['weight_logs'] as int? ?? 0;
        if (meals > 0 || weights > 0) {
          final requestId = pending?['request_id'] as String? ?? uuidV4();
          if (!queue.any(
            (op) =>
                op.kind == SyncOpKind.statsIncrement &&
                op.entityId == requestId,
          )) {
            queue.add(
              SyncOp.statsIncrement(
                requestId: requestId,
                meals: meals,
                weightLogs: weights,
              ),
            );
          }
          state[_pendingStatsKey] = {'meals': 0, 'weight_logs': 0};
        }
        change(state, queue);
        state[_outboxKey] = {'items': queue.map((op) => op.toJson()).toList()};
        final changes = <String, String?>{};
        for (final entry in state.entries) {
          if (!selectedKeys.contains(entry.key) ||
              !snapshot.values.containsKey(entry.key)) {
            continue;
          }
          final value = entry.value == null ? null : jsonEncode(entry.value);
          if (value != snapshot.values[entry.key]) changes[entry.key] = value;
        }
        if (_closed) throw StateError('Account storage closed');
        try {
          final receipt = await store.writeBatch(
            changes,
            expectedVersions: {...snapshot.versions, ...guards},
          );
          for (final key in changes.keys) {
            _pendingWrites.remove(key);
          }
          return LocalMutationReceipt(
            List.unmodifiable(queue),
            KeyValueSnapshot(
              {...snapshot.values, ...changes},
              {...snapshot.versions, ...receipt.versions},
            ),
          );
        } on KeyValueConflict {
          if (!retryConflicts || attempt == 11) rethrow;
        }
      }
      throw const KeyValueConflict();
    }());
  }

  static Map<String, dynamic>? _decode(String? value) {
    if (value == null) return null;
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid local mutation state');
    }
    return decoded;
  }

  Map<String, dynamic>? _decodeMutationSlot(String key, String? value) {
    try {
      final decoded = _decode(value);
      if (key == _trainingSessionKey && decoded?['snapshot'] != null) {
        final snapshot = decoded!['snapshot'];
        if (snapshot is! Map) throw const FormatException('Invalid checkpoint');
        TrainingSessionSnapshot.fromJson(snapshot);
      }
      return decoded;
    } on FormatException {
      // Irreparable plaintext is not a resumable session. Decryption/read
      // failures already aborted readSnapshot and never reach this repair.
      if (key == _trainingSessionKey) return {'snapshot': null};
      rethrow;
    }
  }

  List<SyncOp> _operations(Map<String, String?> values) {
    final json = _decode(values[_outboxKey]);
    if (json == null) return [];
    final raw = json['items'];
    if (raw is! List) throw const FormatException('Invalid pending operations');
    return raw.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid pending operation');
      }
      final op = SyncOp.tryFromJson(item);
      if (op == null) throw const FormatException('Unknown pending operation');
      return op;
    }).toList();
  }

  Map<String, dynamic> _object(
    Map<String, Map<String, dynamic>?> state,
    String key,
  ) => {...?state[key]};

  List<Map<String, dynamic>> _rows(
    Map<String, Map<String, dynamic>?> state,
    String key,
    String field,
  ) {
    final raw = state[key]?[field];
    if (raw == null) return [];
    if (raw is! List) throw const FormatException('Invalid local collection');
    return raw.map((row) => (row as Map).cast<String, dynamic>()).toList();
  }

  void _put(
    Map<String, Map<String, dynamic>?> state,
    String key,
    String field,
    String idKey,
    String id,
    Map<String, dynamic>? value,
  ) {
    state[key] = {
      ...?state[key],
      field: [
        if (value != null) value,
        ..._rows(state, key, field).where((row) => row[idKey] != id),
      ],
    };
  }

  void _deleteHistory(Map<String, Map<String, dynamic>?> state, String id) {
    final ids = ((state[_trainingHistoryDeletionsKey]?['ids'] as List?) ?? [])
        .cast<String>()
        .toSet();
    ids.add(id);
    state[_trainingHistoryDeletionsKey] = {'ids': ids.toList()};
    _put(state, _trainingHistoryKey, 'items', 'id', id, null);
    final recovery = state[_trainingSessionKey]?['snapshot'];
    if (recovery is Map && recovery['session_id'] == id) {
      state[_trainingSessionKey] = {'snapshot': null};
    }
  }

  TrainingPlanHead? _localTrainingHead(
    Map<String, Map<String, dynamic>?> state,
    String id,
  ) {
    final raw = state[_trainingHeadsKey]?[id];
    if (raw is Map) {
      return TrainingPlanHead.fromJson({...raw, 'plan_id': id});
    }
    final row = _rows(
      state,
      _trainingPlansKey,
      'items',
    ).where((row) => row['id'] == id).firstOrNull;
    if (row == null) return null;
    final plan = TrainingPlan.fromRow(row);
    if (plan.coachSourceId == null) return null;
    return TrainingPlanHead(
      sourceId: plan.coachSourceId!,
      planId: id,
      incarnation: plan.incarnation,
      deleted: false,
      plan: plan,
    );
  }

  void _recordTrainingHead(
    Map<String, Map<String, dynamic>?> state,
    TrainingPlanHead head,
  ) {
    TrainingPlanHead.fromJson(head.toJson());
    final known = _localTrainingHead(state, head.planId);
    if (known != null &&
        (known.incarnation > head.incarnation ||
            (known.incarnation == head.incarnation &&
                known.deleted &&
                !head.deleted))) {
      return;
    }
    state[_trainingHeadsKey] = {
      ...?state[_trainingHeadsKey],
      head.planId: {
        'source_id': head.sourceId,
        'incarnation': head.incarnation,
        'deleted': head.deleted,
      },
    };
  }

  void _applyTrainingReceipt(
    Map<String, Map<String, dynamic>?> state,
    SyncOp operation,
    LocalSyncResult result,
  ) {
    final row = _rows(
      state,
      _trainingPlansKey,
      'items',
    ).where((row) => row['id'] == operation.entityId).firstOrNull;
    final current = row == null ? null : TrainingPlan.fromRow(row);
    final head = _localTrainingHead(state, operation.entityId);
    final remote = result.trainingPlan;
    if (remote != null &&
        (head == null || remote.incarnation >= head.incarnation) &&
        (current == null || remote.incarnation >= current.incarnation)) {
      _put(state, _trainingPlansKey, 'items', 'id', remote.id, remote.toRow());
    } else if (result.entityDeleted &&
        (current == null ||
            current.incarnation <= operation.trainingIncarnation) &&
        (head == null || head.incarnation <= operation.trainingIncarnation)) {
      _put(state, _trainingPlansKey, 'items', 'id', operation.entityId, null);
    }
  }

  void _projectOperation(
    Map<String, Map<String, dynamic>?> state,
    SyncOp op, {
    bool countStats = true,
    bool updateDependents = true,
  }) {
    switch (op.kind) {
      case SyncOpKind.profileUpsert:
        final profile = op.profile;
        if (profile == null) throw const FormatException('Invalid profile');
        state[_profileKey] = userProfileToJson(profile);
      case SyncOpKind.mealInsert:
      case SyncOpKind.mealUpsert:
      case SyncOpKind.mealPlanConvert:
        final meal = op.meal;
        if (meal == null) throw const FormatException('Invalid meal');
        final exists = _rows(
          state,
          _loggedMealsKey,
          'items',
        ).any((row) => row['id'] == meal.id);
        _put(
          state,
          _loggedMealsKey,
          'items',
          'id',
          meal.id,
          loggedMealToJson(meal),
        );
        if (op.kind == SyncOpKind.mealPlanConvert) {
          final plan = op.plannedMeal;
          if (plan == null) throw const FormatException('Invalid meal plan');
          _put(state, _mealPlansKey, 'plans', 'id', plan.id, plan.toJson());
        }
        if (countStats && !exists && op.kind != SyncOpKind.mealUpsert) {
          var stats = LifetimeStats.fromRow(state[_statsKey] ?? {});
          stats = stats.incrementMeals();
          if (op.trackDay) stats = stats.recordTrackedDay(meal.loggedAt);
          state[_statsKey] = LocalCache._statsToJson(stats);
        }
      case SyncOpKind.mealDelete:
        _put(state, _loggedMealsKey, 'items', 'id', op.entityId, null);
      case SyncOpKind.favoriteUpsert:
        final favorite = op.favorite;
        if (favorite == null) throw const FormatException('Invalid favorite');
        _put(
          state,
          _favoritesKey,
          'items',
          'id',
          favorite.id,
          favoriteMealToJson(favorite),
        );
      case SyncOpKind.favoriteDelete:
        _put(state, _favoritesKey, 'items', 'id', op.entityId, null);
      case SyncOpKind.recipeUpsert:
        final recipe = op.recipe;
        if (recipe == null) throw const FormatException('Invalid recipe');
        _put(
          state,
          _userRecipesKey,
          'items',
          'slug',
          recipe.slug,
          recipe.toRow(),
        );
      case SyncOpKind.recipeDelete:
        _put(state, _userRecipesKey, 'items', 'slug', op.entityId, null);
      case SyncOpKind.weightInsert:
        final kg = op.weightKg, ts = op.recordedAt;
        if (kg == null || ts == null) {
          throw const FormatException('Invalid weight');
        }
        final rows = _rows(state, _weightLogKey, 'items');
        if (!rows.any((row) => row['id'] == op.entityId)) {
          rows.add({'id': op.entityId, 't': ts.toIso8601String(), 'kg': kg});
          rows.sort((a, b) => DateTime.parse(a['t'] as String)
              .compareTo(DateTime.parse(b['t'] as String)));
          if (rows.length > WeightLog.maxEntries) {
            rows.removeRange(0, rows.length - WeightLog.maxEntries);
          }
          state[_weightLogKey] = {'items': rows};
          if (countStats) {
            state[_statsKey] = LocalCache._statsToJson(
              LifetimeStats.fromRow(
                state[_statsKey] ?? {},
              ).incrementWeightLogs(),
            );
          }
        }
      case SyncOpKind.mealPlanUpsert:
        final plan = op.plannedMeal;
        if (plan == null) throw const FormatException('Invalid meal plan');
        _put(state, _mealPlansKey, 'plans', 'id', plan.id, plan.toJson());
      case SyncOpKind.shoppingCheck:
        final check = op.shoppingCheckValue;
        if (check == null) {
          throw const FormatException('Invalid shopping check');
        }
        _put(state, _mealPlansKey, 'checks', 'id', check.id, check.toJson());
      case SyncOpKind.trainingPlanUpsert:
      case SyncOpKind.trainingPlanDelete:
        final plan = op.trainingPlan;
        if (!op.isDelete && plan == null) {
          throw const FormatException('Invalid training plan');
        }
        final head = _localTrainingHead(state, op.entityId);
        final incarnation = op.trainingIncarnation;
        final conflictDraft =
            op.blockedReason == SyncBlockedReason.trainingHeadConflict;
        if (!conflictDraft &&
            head != null &&
            (incarnation < head.incarnation ||
                (!op.isDelete &&
                    incarnation == head.incarnation &&
                    head.deleted))) {
          break;
        }
        final sourceId =
            plan?.coachSourceId ??
            head?.sourceId ??
            (RegExp(r'^coach_[A-Za-z0-9_-]{1,94}$').hasMatch(op.entityId)
                ? op.entityId.substring(6)
                : null);
        if (!conflictDraft && sourceId != null) {
          _recordTrainingHead(
            state,
            TrainingPlanHead(
              sourceId: sourceId,
              planId: op.entityId,
              incarnation: incarnation,
              deleted: op.isDelete,
              plan: plan,
            ),
          );
        }
        _put(
          state,
          _trainingPlansKey,
          'items',
          'id',
          op.entityId,
          plan?.toRow(),
        );
        if (!op.isDelete && updateDependents) {
          state[_trainingSelectionKey] = {'id': op.entityId};
        } else if (op.isDelete &&
            state[_trainingSelectionKey]?['id'] == op.entityId) {
          state[_trainingSelectionKey] = {
            'id': _rows(state, _trainingPlansKey, 'items').firstOrNull?['id'],
          };
        }
        final recovery = state[_trainingSessionKey]?['snapshot'];
        if (recovery is Map) {
          final snapshot = TrainingSessionSnapshot.fromJson(recovery);
          if (snapshot.pendingCompletionAt == null &&
              snapshot.plan.id == op.entityId &&
              snapshot.plan.incarnation <= incarnation &&
              (op.isDelete || !trainingSessionMatchesPlan(snapshot, plan))) {
            state[_trainingSessionKey] = {'snapshot': null};
          }
        }
      case SyncOpKind.trainingHistoryInsert:
        final entry = op.trainingHistory;
        if (entry == null) {
          throw const FormatException('Invalid training history');
        }
        final deleted =
            state[_trainingHistoryDeletionsKey]?['ids'] as List? ?? [];
        if (deleted.contains(entry.id)) {
          if (updateDependents) throw StateError('Training completion deleted');
          break;
        }
        _put(
          state,
          _trainingHistoryKey,
          'items',
          'id',
          entry.id,
          entry.toRow(),
        );
        state[_trainingSessionKey] = {'snapshot': null};
      case SyncOpKind.trainingHistoryDelete:
        _deleteHistory(state, op.entityId);
      case SyncOpKind.trackingDay:
        state[_statsKey] = LocalCache._statsToJson(
          LifetimeStats.fromRow(
            state[_statsKey] ?? {},
          ).recordTrackedDay(DateTime.parse(op.entityId)),
        );
      case SyncOpKind.statsIncrement:
        break;
    }
  }
}
