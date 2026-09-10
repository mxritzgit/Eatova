part of 'home_store.dart';

// Workouts have no independent IDs. Preserve an unchanged workout across
// reordering, but invalidate changed/removed sources. Duplicate removal is
// ambiguous, so a reduced count conservatively retires the checkpoint.
bool _trainingSessionMatchesPlan(
  TrainingSessionSnapshot snapshot,
  TrainingPlan? plan,
) {
  if (plan == null || plan.id != snapshot.plan.id) return false;
  final source = jsonEncode(snapshot.workout.toJson());
  int matches(TrainingPlan value) => value.workouts
      .where((workout) => jsonEncode(workout.toJson()) == source)
      .length;
  final identities = jsonEncode(
    snapshot.workout.exercises.map((e) => e.id).toList(),
  );
  return matches(plan) >= matches(snapshot.plan) &&
      plan.workouts.any((workout) =>
          jsonEncode(workout.toJson()) == source &&
          jsonEncode(workout.exercises.map((e) => e.id).toList()) == identities);
}

mixin _HomeStoreTrainingPart on _HomeStoreBase, _HomeStoreSyncPart {
  Future<void> _trainingSessionTail = Future<void>.value();
  int _trainingSessionWorkCount = 0;
  final Set<SyncOp> _trainingSourceChanges = {};

  Future<T> _serializeTrainingSession<T>(Future<T> Function() action) {
    _trainingSessionWorkCount++;
    final result = _trainingSessionTail.then((_) => action()).whenComplete(() {
      _trainingSessionWorkCount--;
    });
    _trainingSessionTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  bool _sourceChangeInvalidates(SyncOp op, TrainingSessionSnapshot snapshot) =>
      snapshot.pendingCompletionAt == null &&
      (op.kind == SyncOpKind.trainingPlanUpsert ||
          op.kind == SyncOpKind.trainingPlanDelete) &&
      op.entityId == snapshot.plan.id &&
      ((identical(snapshot, _trainingSession) &&
              (_trainingSessionRetired || !_trainingSourceAllows(snapshot))) ||
          op.isDelete ||
          !_trainingSessionMatchesPlan(snapshot, op.trainingPlan));

  bool _sourceDeliveryInvalidates(TrainingSessionSnapshot snapshot) {
    if (_inFlightOps.values.any(
      (op) => _sourceChangeInvalidates(op, snapshot),
    )) {
      return true;
    }
    // The final queued change is the intended source state; an earlier delete
    // followed by an acknowledged re-adoption must not invalidate that plan.
    final pending = _outbox
        .where(
          (op) =>
              op.entityId == snapshot.plan.id &&
              (op.kind == SyncOpKind.trainingPlanUpsert ||
                  op.kind == SyncOpKind.trainingPlanDelete),
        )
        .lastOrNull;
    return pending != null && _sourceChangeInvalidates(pending, snapshot);
  }

  Future<void> _repairTrainingSessionRead() async {
    if (!_trainingSessionHydrationFailed) return;
    final cache = _cache;
    if (cache == null) throw StateError('Training storage unavailable');
    TrainingSessionSnapshot? recovered;
    try {
      recovered = await cache.readTrainingSession(requireReadable: true);
    } catch (_) {
      throw StateError('Training storage unavailable');
    }
    _ensureTrainingSessionActive();
    _mutate(() {
      _trainingSession = recovered;
      _protectedTrainingRecoveryId = recovered?.sessionId;
      _trainingSessionRetired =
          recovered != null &&
          !_trainingSourceAllows(recovered) &&
          (_trainingPlansAuthoritative ||
              _trainingSourceIdsKnown.contains(recovered.plan.id));
      _trainingSessionHydrationFailed = false;
      _trainingSessionVersion++;
    });
  }

  /// Resolve storage before deciding whether to resume or start a workout.
  Future<TrainingSessionSnapshot?> prepareTrainingSessionRecovery() =>
      _serializeTrainingSession(() async {
        _ensureTrainingSessionActive();
        if (sync != null && !_outboxInitialHydrationComplete) {
          throw StateError('Training storage is still loading');
        }
        await _repairTrainingHistoryDeletions();
        await _repairTrainingSessionRead();
        _ensureTrainingSessionActive();
        final recovery = trainingSession;
        _protectedTrainingRecoveryId = recovery?.sessionId;
        return recovery;
      });

  /// A retired route may leave without writing over a replacement checkpoint.
  bool isTrainingSessionRetired({
    required int generation,
    required String sourcePlanId,
  }) {
    _ensureTrainingSessionActive();
    return generation < (_trainingSourceGenerations[sourcePlanId] ?? 0);
  }

  Future<void> saveTrainingSession(
    TrainingSessionSnapshot? snapshot, {
    int? generation,
    String? sourcePlanId,
  }) async {
    _ensureTrainingSessionActive();
    final expectedGeneration = generation ?? _trainingSessionGeneration;
    final validated = snapshot == null
        ? null
        : TrainingSessionSnapshot.fromJson(snapshot.toJson());
    return _serializeTrainingSession(() async {
      _ensureTrainingSessionActive();
      if (validated != null) {
        await _repairTrainingHistoryDeletions();
        if (_trainingHistoryDeletedIds.contains(validated.sessionId)) {
          throw const TrainingCompletionDeleted();
        }
      }
      await _repairTrainingSessionRead();
      if (_trainingSession?.pendingCompletionAt != null &&
          !_trainingHistoryDeletedIds.contains(_trainingSession!.sessionId) &&
          !trainingHistory.any((entry) => entry.id == _trainingSession!.sessionId) &&
          jsonEncode(validated?.toJson()) != jsonEncode(_trainingSession?.toJson())) {
        throw StateError('Pending training completion must be retried');
      }
      final active = trainingSession;
      if (validated != null && active != null &&
          active.sessionId == _protectedTrainingRecoveryId &&
          validated.sessionId != active.sessionId) {
        throw StateError('Existing training recovery must be resolved');
      }
      final sourceId =
          sourcePlanId ?? validated?.plan.id ?? _trainingSession?.plan.id;
      if ((sourcePlanId != null &&
              ((validated != null && validated.plan.id != sourcePlanId) ||
                  (active != null && active.plan.id != sourcePlanId))) ||
          expectedGeneration < (_trainingSourceGenerations[sourceId] ?? 0) ||
          (validated != null &&
              (!_trainingSourceAllows(validated) ||
                  _trainingSourceChanges.any(
                    (op) => _sourceChangeInvalidates(op, validated),
                  ) ||
                  _sourceDeliveryInvalidates(validated)))) {
        throw StateError('Training session source changed');
      }
      final cache = _cache;
      if (cache == null || !await cache.writeTrainingSession(validated)) {
        throw StateError('Training session could not be saved');
      }
      _ensureTrainingSessionActive();
      _mutate(() {
        _trainingSession = validated;
        if (validated == null) _protectedTrainingRecoveryId = null;
        _trainingSessionRetired = false;
        _trainingSessionVersion++;
      });
    });
  }

  Future<void> _discardInvalidTrainingRecovery() =>
      _serializeTrainingSession(() async {
        if (_disposed || _trainingSessionEnded || _trainingHistoryDeletionReadFailed) return;
        final snapshot = _trainingSession;
        if (snapshot == null || trainingSession != null) return;
        _mutate(() {
          _trainingSessionRetired = true;
          _trainingSessionVersion++;
          _retireTrainingSource(snapshot.plan.id);
        });
        final cleared = await _cache?.writeTrainingSession(null);
        if (cleared == true && !_disposed && !_trainingSessionEnded) {
          _mutate(() {
            _trainingSession = null;
            _trainingSessionRetired = false;
            _trainingSessionVersion++;
          });
        }
      });

  void _retireTrainingSource(String id) {
    _trainingSourceGenerations[id] = ++_trainingSessionGeneration;
  }

  /// Saves only after an explicit confirmation. Stable IDs make adoption
  /// idempotent; edits replace the same plan without creating another row.
  Future<SyncDelivery> saveTrainingPlan(TrainingPlan plan) {
    _ensureTrainingSessionActive();
    final validated = TrainingPlan.fromRow(plan.toRow());
    _ensureTrainingPlanCapacity(validated.id);
    final op = SyncOp.trainingPlanUpsert(validated);
    return _saveTrainingMutation(
      op,
      () => sync!.trainingPlans.upsert(validated),
      () {
        _trainingPlans = [
          validated,
          ...trainingPlans.where((entry) => entry.id != validated.id),
        ];
        _selectedTrainingPlanId = validated.id;
        _trainingSelectionVersion++;
      },
    );
  }

  void _ensureTrainingPlanCapacity(String id) {
    final reservedIds = {
      ...trainingPlans.map((entry) => entry.id),
      ..._outbox
          .where((op) => op.kind == SyncOpKind.trainingPlanUpsert)
          .map((op) => op.entityId),
    };
    if (!reservedIds.contains(id) &&
        reservedIds.length >= TrainingPlansSync.plansLimit) {
      throw StateError('Training plan limit reached');
    }
  }

  Future<SyncDelivery> deleteTrainingPlan(String id) {
    _ensureTrainingSessionActive();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('Invalid training plan ID');
    }
    final op = SyncOp.trainingPlanDelete(id);
    return _saveTrainingMutation(op, () => sync!.trainingPlans.delete(id), () {
      _trainingPlans = trainingPlans.where((entry) => entry.id != id).toList();
      if (_selectedTrainingPlanId == id) {
        _selectedTrainingPlanId = trainingPlans.firstOrNull?.id;
        _trainingSelectionVersion++;
      }
    });
  }

  final Map<String, int> _trainingMutationVersions = {};
  final Map<String, int> _trainingConfirmedVersions = {};

  Future<SyncDelivery> _saveTrainingMutation(
    SyncOp op,
    Future<void> Function() send,
    VoidCallback publish,
  ) {
    _trainingSourceChanges.add(op);
    final snapshot = _trainingSession;
    if (!_trainingSessionHydrationFailed &&
        _trainingSessionWorkCount == 0 &&
        (snapshot == null || !_sourceChangeInvalidates(op, snapshot))) {
      return _deliverTrainingMutation(op, send, publish).whenComplete(() {
        _trainingSourceChanges.remove(op);
      });
    }
    return _serializeTrainingSession<({Future<SyncDelivery> delivery})>(
      () async {
        _ensureTrainingSessionActive();
        await _repairTrainingSessionRead();
        final snapshot = _trainingSession;
        if (snapshot == null || !_sourceChangeInvalidates(op, snapshot)) {
          // Unrelated mutations retain the existing concurrent delivery rules.
          return (delivery: _deliverTrainingMutation(op, send, publish));
        }
        final cache = _cache;
        if (cache == null || !await cache.suspendTrainingSession(snapshot)) {
          throw StateError('Training session could not be saved');
        }
        _ensureTrainingSessionActive();
        final wasRetired = _trainingSessionRetired;
        _mutate(() {
          _trainingSession = null;
          _trainingSessionRetired = false;
          _trainingSessionVersion++;
          _retireTrainingSource(op.entityId);
        });
        SyncDelivery delivery;
        try {
          delivery = await _deliverTrainingMutation(op, send, publish);
        } catch (_) {
          // A timed-out live request can still delete the source. Only an
          // explicit failure with no pending delivery permits rollback.
          if (!wasRetired &&
              !_disposed &&
              !_trainingSessionEnded &&
              !_inFlightOps.containsKey(op.entityKey) &&
              !_outbox.any((entry) => identical(entry, op)) &&
              await cache.writeTrainingSession(snapshot)) {
            _ensureTrainingSessionActive();
            _mutate(() {
              _trainingSession = snapshot;
              _trainingSessionVersion++;
            });
          }
          rethrow;
        }
        // Suspension already durably removed recovery. A failed cleanup must
        // not report an acknowledged source deletion as failed or restore it.
        await cache.writeTrainingSession(null);
        _ensureTrainingSessionActive();
        return (delivery: Future.value(delivery));
      },
    ).then((result) => result.delivery).whenComplete(() {
      _trainingSourceChanges.remove(op);
    });
  }

  Future<SyncDelivery> _deliverTrainingMutation(
    SyncOp op,
    Future<void> Function() send,
    VoidCallback publish,
  ) async {
    if (op.kind == SyncOpKind.trainingPlanUpsert) {
      _ensureTrainingPlanCapacity(op.entityId);
    }
    final version = (_trainingMutationVersions[op.entityId] ?? 0) + 1;
    _trainingMutationVersions[op.entityId] = version;
    _unconfirmedTrainingOps.add(op);
    try {
      final delivery = await _trainingDelivery(
        _syncOrQueue(
          op.isDelete ? 'Training-plan-delete' : 'Training-plan',
          send,
          () => op,
          onDelivered: () {
            if (_unconfirmedTrainingOps.contains(op)) {
              _deliveredTrainingOps.add(op);
            }
          },
          aufruferMeldetAusgang: true,
        ),
        op,
      );
      _compactConfirmedTrainingUpserts(op);
      // Failed newer intent must not suppress a real earlier success; only a
      // newer CONFIRMED change may supersede this result.
      if ((_trainingConfirmedVersions[op.entityId] ?? 0) < version) {
        _trainingConfirmedVersions[op.entityId] = version;
        final previous = trainingPlans
            .where((plan) => plan.id == op.entityId)
            .firstOrNull;
        if (op.isDelete ||
            (_trainingSession?.plan.id != op.entityId &&
                previous != null &&
                jsonEncode(previous.toJson()) !=
                    jsonEncode(op.trainingPlan?.toJson()))) {
          _retireTrainingSource(op.entityId);
        }
        _mutate(() {
          _trainingSourceIdsKnown.add(op.entityId);
          publish();
        });
        _cacheTrainingPlans();
        unawaited(
          _cache?.writeTrainingSelection(_selectedTrainingPlanId) ??
              Future<void>.value(),
        );
      }
      return delivery;
    } catch (_) {
      // Retirement can reject the UI result while persistence is still pending.
      // Keep cap protection until receipts prove whether this exact op survived.
      await _settleTrainingOutboxReceipts(op);
      final acknowledged =
          _deliveredTrainingOps.contains(op) ||
          _durableOutboxSnapshot.any((entry) => identical(entry, op));
      if (!_disposed && !acknowledged) {
        final remaining = _outbox
            .where((entry) => !identical(entry, op))
            .toList();
        if (remaining.length != _outbox.length) {
          _outbox = remaining;
          // Logout may still be draining other writes in this account's cache.
          if (!(_cache?.isClosed ?? true)) _persistOutbox();
        }
      }
      rethrow;
    } finally {
      _unconfirmedTrainingOps.remove(op);
      _deliveredTrainingOps.remove(op);
      _trainingOutboxReceipts.remove(op);
      _settleTrainingOutboxCapacity();
    }
  }

  void _compactConfirmedTrainingUpserts(SyncOp op) {
    if (op.kind != SyncOpKind.trainingPlanUpsert ||
        _outboxReplayInFlight ||
        _inFlightOps.containsKey(op.entityKey)) {
      return;
    }
    final current = _outbox.indexWhere((entry) => identical(entry, op));
    final superseded = <SyncOp>{};
    for (var index = current - 1; index >= 0; index--) {
      final previous = _outbox[index];
      if (previous.entityKey != op.entityKey) continue;
      if (!previous.isUpsert || _unconfirmedTrainingOps.contains(previous)) {
        break;
      }
      superseded.add(previous);
    }
    if (superseded.isEmpty) return;
    // Keep the acknowledged predecessor until its replacement is durable.
    // A failed compaction write leaves both full upserts on disk, in order.
    _outbox = _outbox.where((entry) => !superseded.contains(entry)).toList();
    _persistOutbox();
  }

  void selectTrainingPlan(String id) {
    _ensureTrainingSessionActive();
    if (!trainingPlans.any((plan) => plan.id == id) ||
        _selectedTrainingPlanId == id) {
      return;
    }
    _mutate(() {
      _selectedTrainingPlanId = id;
      _trainingSelectionVersion++;
    });
    unawaited(_cache?.writeTrainingSelection(id) ?? Future<void>.value());
  }

  void _ensureTrainingSessionActive() {
    if (_disposed || _trainingSessionEnded || (_cache?.isClosed ?? false)) {
      throw StateError('Training session ended');
    }
    final currentUser = sync?.client.auth.currentUser;
    if (currentUser != null && currentUser.id != sync?.userId) {
      throw StateError('Training session ended');
    }
  }

  Future<SyncDelivery> _trainingDelivery(
    Future<SyncDelivery> pending,
    SyncOp op,
  ) async {
    final result = await pending;
    _ensureTrainingSessionActive();
    if (result == SyncDelivery.delivered ||
        _deliveredTrainingOps.contains(op)) {
      return SyncDelivery.delivered;
    }
    // Unlike a mirror write, this is the only durable copy while offline.
    // Never overwrite an outbox whose previous contents remain unreadable.
    final cache = _cache;
    if (!_outbox.any((entry) => identical(entry, op)) ||
        cache == null ||
        _outboxHydrationFailed) {
      throw StateError('Training change could not be saved');
    }
    await _writeOutboxWithReceipt(_outbox);
    await _settleTrainingOutboxReceipts(op);
    _ensureTrainingSessionActive();
    if (_deliveredTrainingOps.contains(op)) return SyncDelivery.delivered;
    if (!_outbox.any((entry) => identical(entry, op)) ||
        !_durableOutboxSnapshot.any((entry) => identical(entry, op))) {
      throw StateError('Training change could not be saved');
    }
    return result;
  }
}
