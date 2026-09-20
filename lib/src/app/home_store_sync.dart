part of 'home_store.dart';

/// Legacy compatibility thresholds. Confirmed operations are never dropped.
const Duration kOutboxMinAgeBeforeDrop = Duration(hours: 24);
const Duration kOutboxDeleteMinAge = Duration(days: 7);
const int kOutboxRepairMaxAttempts = 3;
const Duration kOutboxRepairMinSpacing = Duration(seconds: 30);
const Duration kSignOutDeliveryBudget = Duration(seconds: 25);

/// Maximum UI wait for network delivery after an acknowledged local commit.
const Duration kSyncDeliveryWindow = Duration(seconds: 3);

/// Maximum wait for a network hydration mirror before account cleanup.
const Duration kCacheSnapshotWaitBudget = Duration(seconds: 3);
mixin _HomeStoreSyncPart on _HomeStoreBase {
  List<SyncOp> _outbox = [];
  bool _outboxInitialHydrationComplete = false;
  bool _outboxHydrationFailed = false;
  Timer? _outboxRetryTimer;
  Timer? _statsSaveDebounce;
  int _outboxRetryAttempt = 0;
  int _pendingMealsDelta = 0;
  int _pendingWeightLogsDelta = 0;
  String? _pendingStatsRequestId;
  final Map<String, SyncOp> _inFlightOps = {};
  Future<void> _localMutationTail = Future<void>.value();
  Future<void>? _outboxReplayFuture;
  Future<void>? _cacheSnapshotInFlight;
  Object? _lastSyncError;
  bool _syncHintShown = false;
  Map<String, int> _cacheObservedVersions = const {};
  int _localCommitGeneration = 0;
  Map<String, TrainingPlanHead> _trainingHeads = {};
  List<SyncOp>? _trainingAdoptionsSource;
  List<SyncOp> _trainingAdoptionsView = const [];
  Future<void> _hydrateFromCache();
  void _notifyRecipeSaveAcknowledged(SyncOp operation, LocalSyncResult result);

  void _observeLocalCommit(LocalMutationReceipt receipt) {
    _adoptTrainingHeads(receipt);
    _cacheObservedVersions = {
      ..._cacheObservedVersions,
      ...receipt.snapshot.versions,
    };
    _localCommitGeneration++;
  }

  void _adoptTrainingHeads(LocalMutationReceipt receipt) {
    final key = 'eatova.v1.training_heads.${_cache?.userId}';
    if (!receipt.snapshot.values.containsKey(key)) return;
    final raw = receipt.snapshot.values[key];
    final json = raw == null
        ? const <String, dynamic>{}
        : jsonDecode(raw) as Map;
    _trainingHeads = {
      for (final entry in json.entries)
        entry.key as String: TrainingPlanHead.fromJson({
          ...(entry.value as Map),
          'plan_id': entry.key,
        }),
    };
  }

  List<SyncOp> get pendingTrainingAdoptions {
    if (!identical(_trainingAdoptionsSource, _outbox)) {
      _trainingAdoptionsSource = _outbox;
      _trainingAdoptionsView = List.unmodifiable(
        _outbox.where(
          (op) =>
              op.trainingAdoption &&
              op.blockedReason == SyncBlockedReason.trainingHeadConflict,
        ),
      );
    }
    return _trainingAdoptionsView;
  }

  SyncOp trainingAdoptionDraft(String blockedOperationId) =>
      trainingAdoptionReviewOps(
        _outbox,
        blockedOperationId,
        requireResolvable: false,
      ).last;

  @override
  bool _trainingSourceBlocked(TrainingSessionSnapshot snapshot) {
    final head = _trainingHeads[snapshot.plan.id];
    return (head != null &&
            (head.incarnation > snapshot.plan.incarnation ||
                (head.incarnation == snapshot.plan.incarnation &&
                    head.deleted))) ||
        _outbox.any(
          (op) =>
              op.entityId == snapshot.plan.id &&
              op.trainingIncarnation == snapshot.plan.incarnation &&
              op.blockedReason == SyncBlockedReason.trainingHeadConflict,
        );
  }

  bool _trainingIntentApplies(SyncOp operation) {
    if (operation.blockedReason == SyncBlockedReason.trainingHeadConflict ||
        trainingProjectionOps(_outbox).any(
          (op) =>
              op.operationId == operation.operationId &&
              op.blockedReason == SyncBlockedReason.trainingHeadConflict,
        )) {
      return true;
    }
    final head = _trainingHeads[operation.entityId];
    final current = trainingPlans
        .where((plan) => plan.id == operation.entityId)
        .firstOrNull;
    final incarnation = operation.trainingIncarnation;
    return (current == null || incarnation >= current.incarnation) &&
        (head == null ||
            incarnation > head.incarnation ||
            (incarnation == head.incarnation &&
                (operation.isDelete || !head.deleted)));
  }

  List<SyncOp> get pendingOutbox => List.unmodifiable(_outbox);
  bool get debugOutboxRetryTimerIsActive =>
      _outboxRetryTimer?.isActive ?? false;
  int get debugOutboxRetryStage => _outboxRetryAttempt;
  Set<String> get debugOrphanedEntities => const {};

  bool get syncStatusReadable =>
      _cache != null &&
      _outboxInitialHydrationComplete &&
      !_outboxHydrationFailed;

  SyncBlockedReason? get syncBlockedReason => _outbox
      .map((op) => op.blockedReason)
      .whereType<SyncBlockedReason>()
      .firstOrNull;

  Future<void> syncPendingWrites({bool retryBlocked = false}) async {
    if (_outboxHydrationFailed) await _repairOutboxHydration();
    if (retryBlocked) {
      await _outboxReplayFuture;
      await _cache?.retryBlockedSyncOperations();
    }
    await _replayOutbox();
  }

  Future<void> _replayOutbox({bool vomTimer = false}) {
    final running = _outboxReplayFuture;
    if (running != null) return running;
    late final Future<void> future;
    future = _runDurableReplay(vomTimer: vomTimer).whenComplete(() {
      if (identical(_outboxReplayFuture, future)) _outboxReplayFuture = null;
    });
    _outboxReplayFuture = future;
    return future;
  }

  Future<void> _retryTick() => _replayOutbox(vomTimer: true);
  Future<void> _flushStatsDelta() => _replayOutbox();

  Future<void> _repairOutboxHydration() async {
    final cache = _cache;
    if (cache == null || _disposed) return;
    try {
      final pending = await cache.readSyncOperations();
      if (_disposed) return;
      _outbox = pending;
      _outboxHydrationFailed = false;
      _mutate(_applyPendingOpsToState);
    } catch (error, stack) {
      _outboxHydrationFailed = true;
      unawaited(
        CrashReporter.captureSyncFailure(
          error,
          stack,
          context: 'sync-state-recovery',
        ),
      );
    }
  }

  Future<void> signOutCleanup() => _retainOwnedCache(() async {
    _trainingSessionEnded = true;
    await _localMutationTail;
    _endNotificationSession();
    await notificationService.cancelAll();
    _resetHealthConnection();
    // Confirmed pending changes are retained in their encrypted namespace.
    await _clearCache(preserveOutbox: true);
    IntentionalSignOut.refresh();
  });

  void flushPendingWrites() {
    unawaited(_cache?.flush() ?? Future<void>.value());
    unawaited(syncPendingWrites());
  }

  void _reportSyncError(
    String operation,
    Object error,
    StackTrace stack, {
    String? message,
    bool netzfehlerMelden = false,
  }) {
    dev.log('$operation failed', error: error, name: 'eatova_sync');
    unawaited(
      netzfehlerMelden
          ? CrashReporter.capture(error, stack, context: operation)
          : CrashReporter.captureSyncFailure(error, stack, context: operation),
    );
    if (_disposed) return;
    _emitSnack(
      message ?? directSyncErrorMessage(error, _l10n),
      icon: Icons.error_outline_rounded,
      tone: SnackTone.error,
      duration: kSnackError,
    );
  }

  void _ensureMutationActive() {
    if (_disposed || _trainingSessionEnded || (_cache?.isClosed ?? false)) {
      throw StateError('Account session ended');
    }
    final owner = sync?.client.auth.currentUser;
    if (owner != null && owner.id != sync?.userId) {
      throw StateError('Account session ended');
    }
    if (_boundSyncSessionId != null &&
        _boundSyncSessionId !=
            syncSessionIdFromAccessToken(
              sync?.client.auth.currentSession?.accessToken ?? '',
            )) {
      throw StateError('Account session ended');
    }
  }

  Future<SyncDelivery> _commitSyncIntents(
    List<SyncOp> intents, {
    VoidCallback? publish,
    bool notifyQueued = true,
    String? retireTrainingSessionId,
    String? replacingTrainingAdoption,
    String? expectedTrainingDraftOperationId,
    TrainingPlanHead? resolvedTrainingHead,
  }) async {
    final commit = _localMutationTail.then((_) async {
      _ensureMutationActive();
      if (sync != null) {
        if (_outboxHydrationFailed) await _repairOutboxHydration();
        final cache = _cache;
        if (!_outboxInitialHydrationComplete ||
            _outboxHydrationFailed ||
            cache == null) {
          throw StateError('Local storage is not ready');
        }
        final guards = await _localSessionGuards(cache);
        final receipt = await cache.commitSyncOperations(
          intents,
          guards: guards,
          retireTrainingSessionId: retireTrainingSessionId,
          replacingTrainingAdoption: replacingTrainingAdoption,
          expectedTrainingDraftOperationId: expectedTrainingDraftOperationId,
          resolvedTrainingHead: resolvedTrainingHead,
        );
        _ensureMutationActive();
        _observeLocalCommit(receipt);
        _outbox = receipt.operations;
      }
      if (publish != null) _mutate(publish);
    });
    _localMutationTail = commit.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    await commit;
    if (sync == null) return SyncDelivery.delivered;
    // Publication follows COMMIT. Delivery is independent of UI durability.
    await _replayOutbox().timeout(kSyncDeliveryWindow, onTimeout: () {});
    _ensureMutationActive();
    final pending = _outbox.map((op) => op.operationId).toSet();
    final delivery = intents.any((op) => pending.contains(op.operationId))
        ? (_lastSyncError == null
              ? SyncDelivery.queuedRetry
              : queuedDelivery(_lastSyncError!))
        : SyncDelivery.delivered;
    if (notifyQueued && delivery != SyncDelivery.delivered && !_syncHintShown) {
      _syncHintShown = true;
      final message = switch (syncBlockedReason) {
        SyncBlockedReason.capacity => _l10n.settingsSyncCapacity,
        SyncBlockedReason.backendUnavailable => _l10n.settingsSyncUnavailable,
        SyncBlockedReason.rejected => _l10n.settingsSyncRejected,
        SyncBlockedReason.trainingHeadConflict => _l10n.syncTrainingReviewRequired,
        null => queuedSyncHint(_lastSyncError, _l10n),
      };
      _emitSnack(
        message,
        icon: Icons.sync_problem_rounded,
        tone: SnackTone.neutral,
      );
    }
    return delivery;
  }

  Future<Map<String, int>> _localSessionGuards(LocalCache cache) async {
    final service = sync;
    final store = cache.atomicStore;
    final token = service?.client.auth.currentSession?.accessToken;
    if (service == null || store == null) {
      throw StateError('Local storage unavailable');
    }
    if (token == null && debugCache != null) return const {};
    final sessionId = syncSessionIdFromAccessToken(token ?? '');
    if (sessionId == null || sessionId != _boundSyncSessionId) {
      throw StateError('Account session unavailable');
    }
    bool current() =>
        !_disposed &&
        !_trainingSessionEnded &&
        service.client.auth.currentUser?.id == service.userId &&
        syncSessionIdFromAccessToken(
              service.client.auth.currentSession?.accessToken ?? '',
            ) ==
            sessionId;
    await SyncExecutionGuard(
      store,
    ).activate(service.userId, sessionId, isCurrentSession: current);
    final snapshot = await store.readSnapshot([syncSessionKey]);
    if (!current()) throw StateError('Account session ended');
    final state = jsonDecode(snapshot.values[syncSessionKey] ?? '{}') as Map;
    if (state['owner'] != service.userId || state['session'] != sessionId) {
      throw StateError('Account session ended');
    }
    return {syncSessionKey: snapshot.versions[syncSessionKey]!};
  }

  void _scheduleOutboxRetry() {
    if (_disposed || sync == null) return;
    if (!_outbox.any((op) => op.blockedReason == null) &&
        _pendingMealsDelta == 0 &&
        _pendingWeightLogsDelta == 0) {
      return;
    }
    if (_outboxRetryTimer?.isActive ?? false) return;
    final delay = Duration(seconds: 30 * (1 << _outboxRetryAttempt));
    _outboxRetryTimer = Timer(delay, () {
      _outboxRetryTimer = null;
      unawaited(_retryTick());
    });
  }

  void _bumpRetryStage() {
    if (_outboxRetryAttempt < 3) _outboxRetryAttempt++;
  }

  Future<void> _runDurableReplay({required bool vomTimer}) async {
    final s = sync, cache = _cache;
    if (_disposed ||
        _trainingSessionEnded ||
        s == null ||
        cache == null ||
        !_outboxInitialHydrationComplete) {
      return;
    }
    final blocked = <String>{};
    var succeeded = false;
    final attempted = <String>{};
    SyncExecutionClaim? claim;
    try {
      final atomic = cache.atomicStore;
      if (atomic == null) return;
      final token = s.client.auth.currentSession?.accessToken;
      if (token != null) {
        final sessionId = syncSessionIdFromAccessToken(token);
        if (sessionId == null || sessionId != _boundSyncSessionId) return;
        final guard = SyncExecutionGuard(atomic);
        await guard.activate(
          s.userId,
          sessionId,
          isCurrentSession: () =>
              !_disposed &&
              !_trainingSessionEnded &&
              s.client.auth.currentUser?.id == s.userId &&
              syncSessionIdFromAccessToken(
                    s.client.auth.currentSession?.accessToken ?? '',
                  ) ==
                  sessionId,
        );
        if (_disposed || _trainingSessionEnded) return;
        claim = await guard.tryClaim(s.userId, expectedSessionId: sessionId);
        if (claim == null) return;
      } else if (debugCache == null) {
        return;
      }
      _outbox = await cache.readSyncOperations(
        guards: claim?.guards ?? const {},
      );
      while (attempted.length < 20) {
        if (_disposed || _trainingSessionEnded) return;
        if (claim != null && !await claim.renew()) return;
        _outbox = await cache.readSyncOperations(
          guards: claim?.guards ?? const {},
        );
        final candidate = _outbox
            .where(
              (op) =>
                  !attempted.contains(op.operationId) &&
                  !blocked.contains(op.entityKey) &&
                  op.blockedReason == null,
            )
            .firstOrNull;
        if (candidate == null) break;
        attempted.add(candidate.operationId);
        final op = await cache.startSyncOperation(
          candidate.operationId,
          guards: claim?.guards ?? const {},
        );
        if (op == null) continue;
        if (_disposed ||
            _trainingSessionEnded ||
            (claim != null && !await claim.isCurrent())) {
          return;
        }
        _inFlightOps[op.entityKey] = op;
        try {
          final result = await dispatchSyncOp(s, op);
          if (_disposed || _trainingSessionEnded) return;
          _ensureMutationActive();
          final committed = await cache.acknowledgeSyncOperation(
            op.operationId,
            result,
            guards: claim?.guards ?? const {},
          );
          if (_disposed || _trainingSessionEnded) return;
          _outbox = committed.operations;
          _observeLocalCommit(committed);
          _adoptSyncResult(op, result);
          _notifyRecipeSaveAcknowledged(op, result);
          _lastSyncError = null;
          succeeded = true;
        } catch (error, stack) {
          _lastSyncError = error;
          if (_disposed || _trainingSessionEnded) return;
          _ensureMutationActive();
          blocked.add(op.entityKey);
          // Rejected or unsupported requests remain durable. No retry budget
          // or capacity policy may erase an acknowledged user mutation.
          final receipt = await cache.recordSyncFailure(
            op.operationId,
            countAttempt: !isNetworkSyncError(error),
            blockedReason: blockedReasonForSyncError(
              error,
              attempts: op.attempts,
              kind: op.kind,
            ),
            guards: claim?.guards ?? const {},
          );
          _mutate(() => _outbox = receipt.operations);
          unawaited(
            CrashReporter.captureSyncFailure(
              error,
              stack,
              context: 'outbox-replay-${op.kind.name}',
            ),
          );
        } finally {
          _inFlightOps.remove(op.entityKey);
        }
      }
    } catch (error, stack) {
      _lastSyncError = error;
      unawaited(
        CrashReporter.captureSyncFailure(
          error,
          stack,
          context: 'outbox-local-transaction',
        ),
      );
    } finally {
      try {
        await claim?.release();
      } catch (error, stack) {
        // Lease cleanup cannot undo an already committed server/local ACK.
        // Its bounded expiry permits a later dispatcher to acquire it again.
        unawaited(
          CrashReporter.captureSyncFailure(
            error,
            stack,
            context: 'outbox-claim-release',
          ),
        );
      }
    }
    if (_disposed || _trainingSessionEnded) return;
    if (succeeded) {
      _outboxRetryAttempt = 0;
      if (_outbox.isEmpty) _syncHintShown = false;
    } else if (vomTimer) {
      _bumpRetryStage();
    }
    if (_outbox.isNotEmpty) _scheduleOutboxRetry();
  }

  void _adoptSyncResult(SyncOp op, LocalSyncResult result) {
    final newer = _outbox.any((entry) => entry.entityKey == op.entityKey);
    _mutate(() {
      if (result.trainingPlan case final remote?) {
        final current = trainingPlans
            .where((plan) => plan.id == remote.id)
            .firstOrNull;
        final head = _trainingHeads[remote.id];
        if (!result.trainingHeadConflict &&
            (current == null || remote.incarnation >= current.incarnation) &&
            (head == null || remote.incarnation >= head.incarnation)) {
          _trainingPlans = [
            remote,
            ...trainingPlans.where((plan) => plan.id != remote.id),
          ];
        }
      }
      if (result.stats != null) lifetimeStats = result.stats!;
      if (result.plan != null && !newer) {
        _putPlannedMeal(result.plan!);
        if (result.meal != null) {
          loggedMeals = [
            result.meal!,
            ...loggedMeals.where((m) => m.id != result.meal!.id),
          ];
        }
      }
      if (result.recipeRevision != null) {
        if (result.deletedRecipeSlug != null) {
          _userRecipes = _userRecipes
              .where((recipe) => recipe.slug != result.deletedRecipeSlug)
              .toList();
        }
        if (!newer ||
            (result.recipe != null && result.recipe!.slug != op.entityId)) {
          _userRecipes = [
            if (result.currentRecipe != null) result.currentRecipe!,
            ..._userRecipes.where((recipe) => recipe.slug != op.entityId),
          ];
        }
        final saved = result.recipe;
        if (saved != null && (!newer || saved.slug != op.entityId)) {
          _userRecipes = [
            saved,
            ..._userRecipes.where((recipe) => recipe.slug != saved.slug),
          ];
        }
      }
      if (result.convertedMealDeleted) {
        loggedMeals = loggedMeals
            .where((meal) => meal.id != op.entityId)
            .toList();
      }
      if (result.historyDeleted) {
        _trainingHistoryDeletedIds.add(op.entityId);
        _trainingHistory = _trainingHistoryState
            .where((entry) => entry.id != op.entityId)
            .toList();
      }
      if (result.entityDeleted) {
        switch (op.kind) {
          case SyncOpKind.mealInsert:
          case SyncOpKind.mealUpsert:
          case SyncOpKind.mealDelete:
            loggedMeals = loggedMeals
                .where((meal) => meal.id != op.entityId)
                .toList();
          case SyncOpKind.trainingPlanUpsert:
          case SyncOpKind.trainingPlanDelete:
            if (!result.trainingHeadConflict &&
                result.trainingPlan == null &&
                (_trainingHeads[op.entityId]?.incarnation ?? 0) <=
                    op.trainingIncarnation) {
              _trainingPlans = trainingPlans
                  .where(
                    (plan) =>
                        plan.id != op.entityId ||
                        plan.incarnation > op.trainingIncarnation,
                  )
                  .toList();
            }
          case SyncOpKind.mealPlanUpsert:
          case SyncOpKind.mealPlanConvert:
            _plannedMeals = _plannedMeals
                .where((plan) => plan.id != op.entityId)
                .toList();
            _mealPlansVersion++;
          default:
            break;
        }
      }
      _applyPendingOpsToState();
      dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
      macroProgress = macroProgressForFoodDate(clock.now());
      _invalidateTrendWindow();
    });
  }

  void _applyPendingOpsToState() {
    if (_outbox.isEmpty) return;
    var mealsTouched = false;
    for (final op in trainingProjectionOps(recipeProjectionOps(_outbox))) {
      switch (op.kind) {
        case SyncOpKind.mealPlanUpsert:
          final plan = op.plannedMeal;
          if (plan != null) _putPlannedMeal(plan);
        case SyncOpKind.shoppingCheck:
          final check = op.shoppingCheckValue;
          if (check != null) {
            _shoppingChecks = {..._shoppingChecks, check.id: check.checked};
            _mealPlansVersion++;
          }
        case SyncOpKind.mealPlanConvert:
          final plan = op.plannedMeal;
          final meal = op.meal;
          if (plan == null || meal == null) break;
          _putPlannedMeal(plan);
          loggedMeals = [meal, ...loggedMeals.where((m) => m.id != meal.id)];
          if (op.trackDay) {
            lifetimeStats = lifetimeStats.recordTrackedDay(meal.loggedAt);
          }
          mealsTouched = true;
        case SyncOpKind.mealInsert:
        case SyncOpKind.mealUpsert:
          final meal = op.meal;
          if (meal == null) break;
          if (op.trackDay) {
            lifetimeStats = lifetimeStats.recordTrackedDay(meal.loggedAt);
          }
          final index = loggedMeals.indexWhere((m) => m.id == meal.id);
          if (index >= 0) {
            final next = [...loggedMeals];
            next[index] = meal;
            loggedMeals = next;
          } else {
            loggedMeals = [meal, ...loggedMeals];
          }
          mealsTouched = true;
        case SyncOpKind.mealDelete:
          loggedMeals = loggedMeals.where((m) => m.id != op.entityId).toList();
        case SyncOpKind.weightInsert:
          final kg = op.weightKg;
          final ts = op.recordedAt;
          if (kg == null || ts == null) break;
          if (weightLog.entries.any((e) => e.timestamp.isAtSameMomentAs(ts))) {
            break;
          }
          final entries = [
            ...weightLog.entries,
            WeightLogEntry(timestamp: ts, weightKg: kg),
          ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
          weightLog = WeightLog(entries: entries);
        case SyncOpKind.favoriteUpsert:
          final fav = op.favorite;
          if (fav == null) break;
          favorites = [fav, ...favorites.where((f) => f.id != fav.id)];
        case SyncOpKind.favoriteDelete:
          favorites = favorites.where((f) => f.id != op.entityId).toList();
        case SyncOpKind.recipeUpsert:
          final recipe = op.recipe;
          if (recipe == null) break;
          _userRecipes = [
            recipe,
            ..._userRecipes.where((r) => r.slug != recipe.slug),
          ];
        case SyncOpKind.recipeDelete:
          _userRecipes = _userRecipes
              .where((r) => r.slug != op.entityId)
              .toList();
        case SyncOpKind.trainingHistoryInsert:
          final entry = op.trainingHistory;
          if (entry != null) {
            _trainingHistory = [
              entry,
              ..._trainingHistoryState.where((item) => item.id != entry.id),
            ];
          }
        case SyncOpKind.trainingHistoryDelete:
          _trainingHistory = _trainingHistoryState
              .where((entry) => entry.id != op.entityId)
              .toList();
        case SyncOpKind.trainingPlanUpsert:
          final plan = op.trainingPlan;
          if (plan == null || !_trainingIntentApplies(op)) break;
          _trainingSourceIdsKnown.add(op.entityId);
          _trainingPlans = [
            plan,
            ...trainingPlans.where((entry) => entry.id != plan.id),
          ];
        case SyncOpKind.trainingPlanDelete:
          if (!_trainingIntentApplies(op)) break;
          _trainingSourceIdsKnown.add(op.entityId);
          _trainingPlans = trainingPlans
              .where((entry) => entry.id != op.entityId)
              .toList();
        case SyncOpKind.profileUpsert:
          // Gap D, boot half: the server load sets `profile` to the old server
          // row, and the undelivered change goes back on top. The following
          // `_writeCacheSnapshot` persists exactly that state.
          final pendingProfile = op.profile;
          if (pendingProfile == null) break;
          profile = pendingProfile;
          // A profile op only ever comes from a real, hydrated profile, so it
          // IS a real source. Without this the A1 guard would stay closed and
          // `_writeCacheSnapshot` would drop the change again.
          _hydratedFromRealSource = true;
        case SyncOpKind.trackingDay:
          // Lets the optimistic streak survive a cold start: the server row
          // comes WITHOUT the day (the RPC never landed), so it goes back on
          // top. recordTrackedDay is idempotent per day.
          final tag = DateTime.tryParse(op.entityId);
          if (tag == null) break;
          lifetimeStats = lifetimeStats.recordTrackedDay(tag);
        case SyncOpKind.statsIncrement:
          // No state effect: the lifetime counters follow the server row. This
          // entry only matters during replay.
          break;
      }
    }
    if (mealsTouched) {
      // Restore server ordering (logged_at descending) after the merge.
      loggedMeals = [...loggedMeals]
        ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    }
  }

  void _showUndoSnackBar(String label, VoidCallback onUndo) {
    if (_disposed) return;
    _emitSnack(
      label,
      icon: Icons.delete_outline_rounded,
      tone: SnackTone.error,
      action: SnackBarAction(label: _l10n.commonUndo, onPressed: onUndo),
    );
  }

  Future<bool> deleteAccount({
    Future<void> Function()? deleteRemote,
    bool Function()? isCurrentSession,
  }) => _retainOwnedCache(() async {
    try {
      _ensureMutationActive();
      if (isCurrentSession != null && !isCurrentSession()) {
        throw StateError('Account session ended');
      }
      if (deleteRemote != null) {
        await deleteRemote();
      } else {
        await sync?.deleteAccount();
      }
    } catch (e, st) {
      // The server-side reauth rejection (EX_REAUTH_REQUIRED) needs its own
      // sentence: retrying later does not help, a new mail code is required.
      _reportSyncError(
        'Konto-Löschung',
        e,
        st,
        message: deleteAccountErrorMessage(e, _l10n),
        netzfehlerMelden: true,
      );
      return false;
    }
    if (isCurrentSession != null && !isCurrentSession()) return true;
    Future<void> cleanup(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        // Remote deletion is final. Local failure must not prevent sign-out.
        unawaited(
          CrashReporter.captureSyncFailure(
            error,
            stack,
            context: 'account-delete-local-cleanup',
          ),
        );
      }
    }

    // D9: scheduled reminders live in the OS, not in our cache — without this
    // they keep firing after the deletion.
    if (!_disposed && !_trainingSessionEnded) {
      try {
        _ensureMutationActive();
      } catch (_) {
        await cleanup(_clearCache);
        return true;
      }
      _endNotificationSession();
      await cleanup(notificationService.cancelAll);
      if (isCurrentSession != null && !isCurrentSession()) return true;
      // Another login may have arrived during the OS operation.
      try {
        _ensureMutationActive();
        _resetHealthConnection();
      } catch (_) {
        // Only the bound cache may still be cleared.
      }
    }
    // No preserveOutbox: the account is gone, so there is no delivery target.
    await cleanup(_clearCache);
    return true;
  });

  void _resetHealthConnection() {
    _healthGeneration++;
    _healthSessionEnded = true;
    health.reset();
    healthAuthState = health.authState;
    dailySteps = 0;
  }

  Future<void> _clearCache({bool preserveOutbox = false}) async {
    _trainingSessionEnded = true;
    // F1-02: a snapshot still writing (logout right after boot) must finish
    // BEFORE the purge, or its remaining slots land on cleared keys — the
    // encrypting store serialises per key, not across keys. Bounded: past the
    // budget the closed flag set by clear() turns the rest into no-ops.
    final laufend = _cacheSnapshotInFlight;
    if (laufend != null) {
      await laufend.timeout(kCacheSnapshotWaitBudget, onTimeout: () {});
    }
    final cache = _cache ?? debugCache ?? await _resolveCacheForOwner();
    final atomic = cache?.atomicStore;
    Map<String, int> guards = const {};
    if (atomic != null && sync != null) {
      final fence = await SyncExecutionGuard(atomic).invalidateForPurge(
        sync!.userId,
        expectedSessionId: _boundSyncSessionId,
      );
      if (fence == null) return;
      guards = fence;
    }
    try {
      await cache?.clear(preserveOutbox: preserveOutbox, guards: guards);
    } on KeyValueConflict {
      return;
    }
    // Own-recipe photos are files in the app directory, not in the LocalCache,
    // so they need their own call — same M-1 reasoning as the recipe row, and
    // therefore also under `preserveOutbox: true` (the outbox carries rows, not
    // bytes). Accepted consequence: a replayed recipe upsert keeps its
    // `local:` marker without bytes and falls back to the placeholder.
    await RecipeImageStore.instance.clear(
      expectedUserId: sync?.userId,
      expectedSessionId: _boundSyncSessionId,
    );
  }

  Future<LocalCache?> _resolveCacheForOwner() async {
    // Cleanup can finish after an account switch on the shared auth client.
    final userId = sync?.userId;
    if (userId == null || userId.isEmpty) return null;
    return LocalCache.create(userId);
  }

  Future<bool> _writeCacheSnapshot(Map<String, int> expectedVersions) async {
    final laufend = _cacheSnapshotInFlight;
    if (laufend != null) await laufend;
    final eigener = _writeCacheSnapshotNow(expectedVersions);
    _cacheSnapshotInFlight = eigener;
    try {
      return await eigener;
    } finally {
      if (identical(_cacheSnapshotInFlight, eigener)) {
        _cacheSnapshotInFlight = null;
      }
    }
  }

  Future<bool> _writeCacheSnapshotNow(Map<String, int> expectedVersions) async {
    final cache = _cache;
    if (cache == null || _disposed || _trainingSessionEnded) return false;
    try {
      if (expectedVersions.isEmpty) return false;
      final receipt = await cache.commitStoreSnapshot(
        expectedVersions: expectedVersions,
        profile: _hydratedFromRealSource ? profile : null,
        stats: lifetimeStats,
        meals: loggedMeals,
        favorites: favorites,
        weightLog: weightLog,
        recipes: _userRecipes,
        trainingPlans: _trainingPlansKnown ? trainingPlans : null,
        trainingHistory:
            _trainingHistoryKnown && !_trainingHistoryDeletionReadFailed
            ? trainingHistory
            : null,
      );
      _observeLocalCommit(receipt);
    } on KeyValueConflict {
      // The snapshot predates another committed foreground/background change.
      // Adopt that database state instead of publishing stale RAM back to it.
      await _hydrateFromCache();
      return true;
    } catch (error, stack) {
      unawaited(
        CrashReporter.captureSyncFailure(
          error,
          stack,
          context: 'local-hydration-commit',
        ),
      );
    }
    return false;
  }

  Future<bool> _cacheMealPlans(Map<String, int> expectedVersions) async {
    if (_disposed || _trainingSessionEnded) return false;
    try {
      if (expectedVersions.isEmpty) return false;
      final receipt = await _cache?.commitStoreSnapshot(
        expectedVersions: expectedVersions,
        mealPlans: _plannedMeals,
        shoppingChecks: _shoppingChecks,
      );
      if (receipt != null) _observeLocalCommit(receipt);
    } on KeyValueConflict {
      await _hydrateFromCache();
      return true;
    } catch (error, stack) {
      unawaited(
        CrashReporter.captureSyncFailure(
          error,
          stack,
          context: 'local-plan-hydration',
        ),
      );
    }
    return false;
  }

  void _ensureTrainingHistoryOwner() {
    final owner = sync?.client.auth.currentUser;
    if (_disposed ||
        _trainingSessionEnded ||
        (_cache?.isClosed ?? false) ||
        (owner != null && owner.id != sync?.userId)) {
      throw StateError('Training storage unavailable');
    }
  }

  Future<void> _repairTrainingHistoryDeletions() async {
    _ensureTrainingHistoryOwner();
    if (_trainingHistoryDeletionsHydrated &&
        !_trainingHistoryDeletionReadFailed) {
      return;
    }
    final cache = _cache;
    if (cache == null) throw StateError('Training storage unavailable');
    Set<String> ids;
    try {
      ids = await cache.readTrainingHistoryDeletions();
    } catch (_) {
      _ensureTrainingHistoryOwner();
      _mutate(() => _trainingHistoryDeletionReadFailed = true);
      throw StateError('Training storage unavailable');
    }
    _ensureTrainingHistoryOwner();
    _mutate(() {
      if (_trainingHistoryDeletionReadFailed) {
        _protectedTrainingRecoveryId = _trainingSession?.sessionId;
      }
      _trainingHistoryDeletedIds.addAll(ids);
      _trainingHistoryDeletionReadFailed = false;
      _trainingHistoryDeletionsHydrated = true;
      _trainingHistory = _trainingHistoryState;
    });
  }
}
