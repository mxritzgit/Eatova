part of 'home_store.dart';

mixin _HomeStoreTrainingHistoryPart
    on _HomeStoreBase, _HomeStoreSyncPart, _HomeStoreTrainingPart {
  Future<SyncDelivery> completeTrainingSession(
    TrainingHistoryEntry entry, {
    required int generation,
  }) => _serializeTrainingSession(() async {
    _ensureTrainingSessionActive();
    if (trainingHistory.any((item) => item.id == entry.id)) {
      return _outbox.any(
            (op) =>
                op.kind == SyncOpKind.trainingHistoryInsert &&
                op.entityId == entry.id,
          )
          ? SyncDelivery.queuedRetry
          : SyncDelivery.delivered;
    }
    if (generation <
        (_trainingSourceGenerations[entry.snapshot.plan.id] ?? 0)) {
      throw const TrainingCompletionSourceRetired();
    }
    final validated = TrainingHistoryEntry.fromRow(entry.toRow());
    if (!trainingHistory.any((item) => item.id == entry.id) &&
        trainingHistory.length >= TrainingHistorySync.limit) {
      throw StateError('Training history limit reached');
    }
    // Persist the identity before sending. A crash during the network request
    // must retry the same completion, even for upgraded legacy checkpoints.
    final cache = _cache;
    if (cache == null ||
        !await cache.writeTrainingSession(validated.snapshot)) {
      throw StateError('Training session could not be saved');
    }
    _ensureTrainingSessionActive();
    _trainingSession = validated.snapshot;
    final op = SyncOp.trainingHistoryInsert(validated);
    final delivery = await _confirmMutation(
      'Training-history',
      op,
      () => sync!.trainingHistory.insert(validated),
    );
    _ensureTrainingSessionActive();
    _mutate(() {
      _trainingHistory = [
        validated,
        ...trainingHistory.where((item) => item.id != entry.id),
      ];
      _trainingSessionRetired = true;
      _retireTrainingSource(entry.snapshot.plan.id);
      _trainingSessionVersion++;
    });
    _cacheTrainingHistory();
    // The receipt already protects history. A failed checkpoint cleanup is
    // safe: hydration hides recovery for completed session IDs.
    if (await cache.writeTrainingSession(null)) {
      _ensureTrainingSessionActive();
      _mutate(() {
        _trainingSession = null;
        _trainingSessionVersion++;
      });
    }
    return delivery;
  });

  Future<SyncDelivery> deleteTrainingHistory(
    String id,
  ) => _serializeTrainingSession(() async {
    _ensureTrainingSessionActive();
    if (!isUuidShape(id)) {
      throw const FormatException('Invalid training history ID');
    }
    // A previous completion may still have an uncleared on-disk checkpoint.
    // Clear it before deleting its history, so it cannot reappear as resumable.
    if (_trainingSession?.sessionId == id) {
      if (!await (_cache?.writeTrainingSession(null) ?? Future.value(false))) {
        throw StateError('Training session could not be saved');
      }
      _ensureTrainingSessionActive();
      _trainingSession = null;
      _trainingSessionVersion++;
    }
    final op = SyncOp.trainingHistoryDelete(id);
    final delivery = await _confirmMutation(
      'Training-history-delete',
      op,
      () => sync!.trainingHistory.delete(id),
    );
    _ensureTrainingSessionActive();
    _mutate(
      () => _trainingHistory = trainingHistory
          .where((entry) => entry.id != id)
          .toList(),
    );
    _cacheTrainingHistory();
    return delivery;
  });
}
