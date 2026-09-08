part of 'home_store.dart';

mixin _HomeStoreTrainingPart on _HomeStoreBase, _HomeStoreSyncPart {
  Future<void> saveTrainingSession(TrainingSessionSnapshot? snapshot) async {
    _ensureTrainingSessionActive();
    final validated = snapshot == null
        ? null
        : TrainingSessionSnapshot.fromJson(snapshot.toJson());
    final cache = _cache;
    if (cache == null || !await cache.writeTrainingSession(validated)) {
      throw StateError('Training session could not be saved');
    }
    _ensureTrainingSessionActive();
    _mutate(() {
      _trainingSession = validated;
      _trainingSessionVersion++;
    });
  }

  /// Saves only after an explicit confirmation. Stable IDs make adoption
  /// idempotent; edits replace the same plan without creating another row.
  Future<SyncDelivery> saveTrainingPlan(TrainingPlan plan) {
    _ensureTrainingSessionActive();
    final validated = TrainingPlan.fromRow(plan.toRow());
    final reservedIds = {
      ...trainingPlans.map((entry) => entry.id),
      ..._outbox
          .where((op) => op.kind == SyncOpKind.trainingPlanUpsert)
          .map((op) => op.entityId),
    };
    if (!reservedIds.contains(validated.id) &&
        reservedIds.length >= TrainingPlansSync.plansLimit) {
      throw StateError('Training plan limit reached');
    }
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
  ) async {
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
        _mutate(publish);
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
