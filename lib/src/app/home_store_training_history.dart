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
    if (!trainingHistory.any((item) => item.id == entry.id) &&
        trainingHistory.length >= TrainingHistorySync.limit) {
      throw StateError('Training history limit reached');
    }
    // Persist the identity before sending. A crash during the network request
    // must retry the same completion, even for upgraded legacy checkpoints.
    final cache = _cache;
    final recovery = validated.recoverySnapshot();
    if (cache == null || !await cache.writeTrainingSession(recovery)) {
      throw StateError('Training session could not be saved');
    }
    _ensureTrainingSessionActive();
    _trainingSession = recovery;
    final op = SyncOp.trainingHistoryInsert(validated);
    var deletedResponse = false;
    final delivery = await _confirmMutation('Training-history', op, () async {
      if (!await sync!.trainingHistory.insert(validated)) {
        deletedResponse = true;
        await _rememberTrainingHistoryDeletion(validated.id);
      }
    });
    _ensureTrainingSessionActive();
    // A failed local receipt may queue the insert, but must not acknowledge
    // completion or clear its recovery until the deletion fence is durable.
    if (deletedResponse && !_trainingHistoryDeletedIds.contains(validated.id)) {
      throw StateError('Training deletion could not be saved');
    }
    _mutate(() {
      _trainingHistory = [
        validated,
        ..._trainingHistoryState.where((item) => item.id != entry.id),
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
    if (_trainingHistoryDeletedIds.contains(entry.id)) {
      throw const TrainingCompletionDeleted();
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
    await _rememberTrainingHistoryDeletion(id);
    return delivery;
  });
}
