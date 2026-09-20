part of 'home_store.dart';

mixin _HomeStoreTrainingPart on _HomeStoreBase, _HomeStoreSyncPart {
  Future<void> _trainingSessionTail = Future<void>.value();
  final Set<SyncOp> _trainingSourceChanges = {};

  Future<T> _serializeTrainingSession<T>(Future<T> Function() action) {
    final result = _trainingSessionTail.then((_) => action());
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
      op.trainingIncarnation >= snapshot.plan.incarnation &&
      ((identical(snapshot, _trainingSession) &&
              (_trainingSessionRetired || !_trainingSourceAllows(snapshot))) ||
          op.isDelete ||
          !trainingSessionMatchesPlan(snapshot, op.trainingPlan));

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
          !trainingHistory.any(
            (entry) => entry.id == _trainingSession!.sessionId,
          ) &&
          jsonEncode(validated?.toJson()) !=
              jsonEncode(_trainingSession?.toJson())) {
        throw StateError('Pending training completion must be retried');
      }
      final active = trainingSession;
      if (validated != null &&
          active != null &&
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
      if (cache == null) {
        throw StateError('Training session could not be saved');
      }
      final receipt = await cache.commitTrainingCheckpoint(
        validated,
        expectedSnapshot: _trainingSession,
        guards: sync == null ? const {} : await _localSessionGuards(cache),
      );
      _ensureTrainingSessionActive();
      _observeLocalCommit(receipt);
      _mutate(() {
        _trainingSession = validated;
        if (validated == null) _protectedTrainingRecoveryId = null;
        _trainingSessionRetired = false;
        _trainingSessionVersion++;
      });
    });
  }

  Future<void> _discardInvalidTrainingRecovery() => _serializeTrainingSession(
    () async {
      if (_disposed ||
          _trainingSessionEnded ||
          _trainingHistoryDeletionReadFailed) {
        return;
      }
      final snapshot = _trainingSession;
      if (snapshot == null || trainingSession != null) return;
      _mutate(() {
        _trainingSessionRetired = true;
        _trainingSessionVersion++;
        _retireTrainingSource(snapshot.plan.id);
      });
      LocalMutationReceipt? cleared;
      try {
        final cache = _cache;
        if (cache != null) {
          cleared = await cache.commitTrainingCheckpoint(
            null,
            expectedSnapshot: snapshot,
            guards: sync == null ? const {} : await _localSessionGuards(cache),
          );
        }
      } catch (_) {
        return;
      }
      if (cleared != null && !_disposed && !_trainingSessionEnded) {
        _observeLocalCommit(cleared);
        _mutate(() {
          _trainingSession = null;
          _trainingSessionRetired = false;
          _trainingSessionVersion++;
        });
      }
    },
  );

  void _retireTrainingSource(String id) {
    _trainingSourceGenerations[id] = ++_trainingSessionGeneration;
  }

  /// Saves only after an explicit confirmation. Stable IDs make adoption
  /// idempotent; edits replace the same plan without creating another row.
  Future<SyncDelivery> saveTrainingPlan(TrainingPlan plan) =>
      _persistTrainingPlan(plan);

  Future<SyncDelivery> adoptTrainingPlan(TrainingPlan plan) {
    final source = plan.coachSourceId;
    if (source == null || trainingPlanIdForMessage(source) != plan.id) {
      throw const FormatException('Invalid coach training source');
    }
    return _persistTrainingPlan(
      TrainingPlan(
        id: plan.id,
        proposal: plan.proposal,
        sourceId: source,
        incarnation: plan.incarnation,
      ),
      adoption: true,
    );
  }

  Future<TrainingPlanHead?> loadTrainingPlanHead(String sourceId) async {
    _ensureMutationActive();
    final service = sync;
    if (service == null) throw StateError('Training source unavailable');
    final head = await service.operations
        .loadTrainingPlanHead(sourceId)
        .timeout(kSyncOperationTimeout);
    _ensureMutationActive();
    return head;
  }

  Future<SyncDelivery> resolveTrainingAdoption(
    String operationId, {
    required TrainingPlanHead? expectedHead,
    required TrainingPlan reviewedDraft,
    String? expectedDraftOperationId,
  }) {
    _ensureMutationActive();
    if (expectedHead != null &&
        (expectedHead.planId != reviewedDraft.id ||
            expectedHead.sourceId != reviewedDraft.coachSourceId)) {
      throw const FormatException('Mismatched training source');
    }
    final incarnation = expectedHead == null
        ? 0
        : expectedHead.incarnation + (expectedHead.deleted ? 1 : 0);
    return _persistTrainingPlan(
      reviewedDraft.copyWith(incarnation: incarnation),
      adoption: true,
      replacingTrainingAdoption: operationId,
      expectedTrainingDraftOperationId: expectedDraftOperationId,
      resolvedTrainingHead: expectedHead,
    );
  }

  Future<SyncDelivery> _persistTrainingPlan(
    TrainingPlan plan, {
    bool adoption = false,
    String? replacingTrainingAdoption,
    String? expectedTrainingDraftOperationId,
    TrainingPlanHead? resolvedTrainingHead,
  }) {
    _ensureTrainingSessionActive();
    final validated = TrainingPlan.fromRow(plan.toRow());
    _ensureTrainingPlanCapacity(validated.id);
    final op = SyncOp.trainingPlanUpsert(validated, adoption: adoption);
    return _saveTrainingMutation(
      op,
      () => sync!.trainingPlans.upsert(validated),
      () {
        final effective =
            _outbox
                .where((entry) => entry.operationId == op.operationId)
                .firstOrNull ??
            op;
        if (!_trainingIntentApplies(effective)) return;
        final committed = effective.trainingPlan ?? validated;
        _trainingPlans = [
          committed,
          ...trainingPlans.where((entry) => entry.id != validated.id),
        ];
        _selectedTrainingPlanId = validated.id;
        _trainingSelectionVersion++;
      },
      replacingTrainingAdoption: replacingTrainingAdoption,
      expectedTrainingDraftOperationId: expectedTrainingDraftOperationId,
      resolvedTrainingHead: resolvedTrainingHead,
    );
  }

  Future<void> discardTrainingAdoption(
    String operationId, {
    TrainingPlanHead? verifiedHead,
  }) => _serializeTrainingSession(() async {
    _ensureMutationActive();
    final cache = _cache;
    if (cache == null) throw StateError('Training storage unavailable');
    final discarded = _outbox
        .where((op) => op.operationId == operationId)
        .firstOrNull;
    final receipt = await cache.discardTrainingAdoption(
      operationId,
      verifiedHead: verifiedHead,
      guards: await _localSessionGuards(cache),
    );
    _ensureMutationActive();
    _observeLocalCommit(receipt);
    Map<String, dynamic>? slot(String name) {
      final raw = receipt.snapshot.values['eatova.v1.$name.${cache.userId}'];
      return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    }

    _mutate(() {
      _outbox = receipt.operations;
      _trainingPlans = ((slot('training_plans')?['items'] as List?) ?? const [])
          .map((row) => TrainingPlan.fromRow(row as Map))
          .toList();
      _selectedTrainingPlanId = slot('training_selection')?['id'] as String?;
      final raw = slot('training_session')?['snapshot'];
      _trainingSession = raw is Map
          ? TrainingSessionSnapshot.fromJson(raw)
          : null;
      if (discarded != null &&
          (_trainingSession == null ||
              _trainingSession!.plan.incarnation <=
                  discarded.trainingIncarnation)) {
        _retireTrainingSource(discarded.entityId);
      }
      _trainingSessionVersion++;
      _trainingSelectionVersion++;
    });
  });

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
    if (pendingTrainingAdoptions.any((op) => op.entityId == id)) {
      throw StateError('Training adoption must be reviewed');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('Invalid training plan ID');
    }
    final incarnation =
        trainingPlans.where((plan) => plan.id == id).firstOrNull?.incarnation ??
        _trainingHeads[id]?.incarnation ??
        0;
    final op = SyncOp.trainingPlanDelete(id, incarnation: incarnation);
    return _saveTrainingMutation(op, () => sync!.trainingPlans.delete(id), () {
      if (!_trainingIntentApplies(op)) return;
      _trainingPlans = trainingPlans.where((entry) => entry.id != id).toList();
      if (_selectedTrainingPlanId == id) {
        _selectedTrainingPlanId = trainingPlans.firstOrNull?.id;
        _trainingSelectionVersion++;
      }
    });
  }

  Future<SyncDelivery> _saveTrainingMutation(
    SyncOp op,
    Future<void> Function() send,
    VoidCallback publish, {
    String? replacingTrainingAdoption,
    String? expectedTrainingDraftOperationId,
    TrainingPlanHead? resolvedTrainingHead,
  }) {
    _trainingSourceChanges.add(op);
    return _serializeTrainingSession(() async {
      _ensureTrainingSessionActive();
      await _repairTrainingSessionRead();
      if (op.kind == SyncOpKind.trainingPlanUpsert) {
        _ensureTrainingPlanCapacity(op.entityId);
      }
      return _commitSyncIntents(
        [op],
        notifyQueued: false,
        replacingTrainingAdoption: replacingTrainingAdoption,
        expectedTrainingDraftOperationId: expectedTrainingDraftOperationId,
        resolvedTrainingHead: resolvedTrainingHead,
        retireTrainingSessionId:
            _trainingSession != null &&
                _sourceChangeInvalidates(op, _trainingSession!)
            ? _trainingSession!.sessionId
            : null,
        publish: () {
          final effective =
              _outbox
                  .where((entry) => entry.operationId == op.operationId)
                  .firstOrNull ??
              op;
          if (!_trainingIntentApplies(effective)) return;
          final snapshot = _trainingSession;
          if (snapshot != null &&
              _sourceChangeInvalidates(effective, snapshot)) {
            _trainingSession = null;
            _trainingSessionRetired = true;
            _trainingSessionVersion++;
          }
          _retireTrainingSource(op.entityId);
          _trainingSourceIdsKnown.add(op.entityId);
          publish();
        },
      );
    }).whenComplete(() => _trainingSourceChanges.remove(op));
  }

  Future<void> selectTrainingPlan(String id) async {
    _ensureTrainingSessionActive();
    if (!trainingPlans.any((plan) => plan.id == id) ||
        _selectedTrainingPlanId == id) {
      return;
    }
    final cache = _cache;
    if (sync != null && cache == null) {
      throw StateError('Local storage is not ready');
    }
    if (cache != null) {
      await cache.commitTrainingSelection(
        id,
        guards: sync == null ? const {} : await _localSessionGuards(cache),
      );
      _localCommitGeneration++;
    }
    _ensureTrainingSessionActive();
    _mutate(() {
      _selectedTrainingPlanId = id;
      _trainingSelectionVersion++;
    });
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
}
