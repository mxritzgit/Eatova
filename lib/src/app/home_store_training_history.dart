part of 'home_store.dart';

mixin _HomeStoreTrainingHistoryPart
    on _HomeStoreBase, _HomeStoreSyncPart, _HomeStoreTrainingPart {
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
      return _outbox.any(
            (op) =>
                op.kind == SyncOpKind.trainingHistoryInsert &&
                op.entityId == entry.id,
          )
          ? SyncDelivery.queuedRetry
          : SyncDelivery.delivered;
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
    if (pending == null &&
        (generation <
                (_trainingSourceGenerations[entry.snapshot.plan.id] ?? 0) ||
            !_trainingSourceAllows(entry.snapshot) ||
            _trainingSourceChanges.any(
              (op) => _sourceChangeInvalidates(op, entry.snapshot),
            ) ||
            _sourceDeliveryInvalidates(entry.snapshot))) {
      throw const TrainingCompletionSourceRetired();
    }
    final validated = TrainingHistoryEntry.fromRow(entry.toRow());
    final active = trainingSession;
    if (active != null &&
        active.sessionId == _protectedTrainingRecoveryId &&
        validated.id != active.sessionId) {
      throw StateError('Existing training recovery must be resolved');
    }
    if (!trainingHistory.any((item) => item.id == entry.id) &&
        trainingHistory.length >= TrainingHistorySync.limit) {
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
        _trainingSession = null;
        _trainingSessionRetired = true;
        _retireTrainingSource(entry.snapshot.plan.id);
        _trainingSessionVersion++;
      },
    );
    if (_trainingHistoryDeletedIds.contains(entry.id)) {
      throw const TrainingCompletionDeleted();
    }
    return delivery;
  });

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
