part of 'home_store.dart';

mixin _HomeStoreTrainingHistoryPart
    on _HomeStoreBase, _HomeStoreSyncPart, _HomeStoreTrainingPart {
  /// Saves the player's finished workout with its frozen plan copy, also when
  /// that plan was edited or deleted while the player was open: the route's
  /// [generation] and the source no longer gate completion. A pending
  /// completion must match, and an unresolved recovery of another session
  /// blocks. Only the finished session's own checkpoint ends.
  Future<SyncDelivery> completeTrainingSession(
    TrainingHistoryEntry entry, {
    required int generation,
  }) => _serializeTrainingSession(() async {
    _ensureTrainingSessionActive();
    await _repairTrainingHistoryDeletions();
    if (_trainingHistoryDeletedIds.contains(entry.id)) {
      throw const TrainingCompletionDeleted();
    }
    if (trainingHistory.any((item) => item.id == entry.id)) {
      return _historyInsertDelivery(entry.id);
    }
    await _repairTrainingSessionRead();
    final pending =
        _trainingSession?.pendingCompletionAt != null &&
            !_trainingHistoryDeletedIds.contains(_trainingSession!.sessionId) &&
            !trainingHistory.any(
              (item) => item.id == _trainingSession!.sessionId,
            )
        ? _trainingSession
        : null;
    if (pending != null &&
        jsonEncode(TrainingHistoryEntry.fromRecovery(pending).toRow()) !=
            jsonEncode(entry.toRow())) {
      throw StateError('Pending training completion must be retried');
    }
    final validated = TrainingHistoryEntry.fromRow(entry.toRow());
    final active = trainingSession;
    if (active != null &&
        active.sessionId == _protectedTrainingRecoveryId &&
        validated.id != active.sessionId) {
      throw StateError('Existing training recovery must be resolved');
    }
    if (trainingHistory.length >= TrainingHistorySync.limit) {
      throw StateError('Training history limit reached');
    }
    final op = SyncOp.trainingHistoryInsert(validated);
    final delivery = await _commitSyncIntents(
      [op],
      notifyQueued: false,
      publish: () {
        _trainingHistory = [
          validated,
          ..._trainingHistoryState.where((item) => item.id != entry.id),
        ];
        // An unrelated paused session and its route stay intact.
        if (_trainingSession?.sessionId == entry.id) {
          _trainingSession = null;
          _trainingSessionRetired = true;
          _retireTrainingSource(entry.snapshot.plan.id);
          _trainingSessionVersion++;
        }
      },
    );
    if (_trainingHistoryDeletedIds.contains(entry.id)) {
      throw const TrainingCompletionDeleted();
    }
    return delivery;
  });

  /// Adds a workout done outside the player: a free log, or with
  /// [planAttached] a workout of a saved plan. Never touches the active
  /// session, its checkpoint or the plan sources. An ID already in the
  /// history writes nothing; a deleted one throws [TrainingCompletionDeleted].
  /// A plan-attached log throws [TrainingLogBlockedBySession] while a session
  /// or its recovery exists, so one workout is never counted twice.
  Future<SyncDelivery> logCompletedWorkout(
    TrainingHistoryEntry entry, {
    bool planAttached = false,
  }) => _serializeTrainingSession(() async {
    _ensureTrainingSessionActive();
    await _repairTrainingHistoryDeletions();
    if (_trainingHistoryDeletedIds.contains(entry.id)) {
      throw const TrainingCompletionDeleted();
    }
    if (trainingHistory.any((item) => item.id == entry.id)) {
      return _historyInsertDelivery(entry.id);
    }
    if (planAttached) {
      await _repairTrainingSessionRead();
      if (trainingSession != null) throw const TrainingLogBlockedBySession();
    }
    if (trainingHistory.length >= TrainingHistorySync.limit) {
      throw StateError('Training history limit reached');
    }
    final validated = TrainingHistoryEntry.fromRow(entry.toRow());
    if (validated.snapshot.completedSets.isEmpty) {
      throw const FormatException('Empty training log');
    }
    final delivery = await _commitSyncIntents(
      [SyncOp.trainingHistoryInsert(validated)],
      notifyQueued: false,
      publish: () => _trainingHistory = [
        validated,
        ..._trainingHistoryState.where((item) => item.id != validated.id),
      ],
    );
    if (_trainingHistoryDeletedIds.contains(entry.id)) {
      throw const TrainingCompletionDeleted();
    }
    return delivery;
  });

  SyncDelivery _historyInsertDelivery(String id) =>
      _outbox.any(
        (op) =>
            op.kind == SyncOpKind.trainingHistoryInsert && op.entityId == id,
      )
      ? SyncDelivery.queuedRetry
      : SyncDelivery.delivered;

  Future<SyncDelivery> deleteTrainingHistory(String id) =>
      _serializeTrainingSession(() async {
        _ensureTrainingSessionActive();
        if (!isUuidShape(id)) {
          throw const FormatException('Invalid training history ID');
        }
        return _commitSyncIntents(
          [SyncOp.trainingHistoryDelete(id)],
          notifyQueued: false,
          publish: () {
            _trainingHistoryDeletedIds.add(id);
            _trainingHistory = _trainingHistoryState
                .where((entry) => entry.id != id)
                .toList();
            if (_trainingSession?.sessionId == id) {
              _trainingSession = null;
              _trainingSessionVersion++;
            }
          },
        );
      });
}
