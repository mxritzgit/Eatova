part of 'home_store.dart';

/// Minimum age before an exhausted retry budget may drop an op
/// (Review 2026-08-08, A4).
///
/// [SyncOp.attempts] counts passes, not time, and lifecycle churn inflates it,
/// so a drop requires spent attempts AND age. Poison-op drops bypass this.
/// 24 h outlasts any outage worth retrying through, without burning battery
/// for weeks on a truly unwritable op.
const Duration kOutboxMinAgeBeforeDrop = Duration(hours: 24);

/// Same for DELETE ops ([SyncOp.isDelete]), but far longer and with no
/// immediate-drop exemption.
///
/// A delete has an EMPTY payload, so no error is structurally impossible —
/// every server error is treated as transient and only time bounds it: drop
/// needs [kOutboxDeleteMaxAttempts] active rejections AND this age. 7 days
/// outlasts any migration/outage window; losing a delete is the worse loss.
/// Offline time is free: network errors are retryFree.
const Duration kOutboxDeleteMinAge = Duration(days: 7);

/// How long a caller waits for the outcome of its write before "queued" applies
/// (gap E).
///
/// Supabase/PostgREST calls carry no timeout, so without this bound a hanging
/// request would never yield a confirmation. The answer stays true after the
/// deadline: the op sits in the persisted queue before the write (gap B) and
/// replay is idempotent.
const Duration kSyncDeliveryWindow = Duration(seconds: 3);

/// Upper bound for the delivery attempt inside [_HomeStoreSyncPart.signOutCleanup]
/// (F1-05). A silent socket must not pin the logout; what is not delivered
/// by then survives in the preserved sync slots (A2) and replays on the next
/// login. Above the 20 s PostgREST request timeout, so a healthy but slow
/// request still gets its answer.
const Duration kSignOutDeliveryBudget = Duration(seconds: 25);

/// Upper bound for waiting on a running cache snapshot before a purge
/// (F1-02). Local IO — anything longer is a hung keystore, and then the
/// closed flag on the cache takes over.
const Duration kCacheSnapshotWaitBudget = Duration(seconds: 3);

/// The payload of an outbox op is unreadable (Review 2026-08-08, A8).
///
/// [SyncOp.tryFromJson] keeps an op with a non-Map payload and substitutes
/// `{}`, so typed accessors return null. Throwing routes it through the same
/// drop path as a poison op instead of silently counting as delivered.
///
/// [toString] carries ONLY the op kind: the payload holds meal names and
/// weights, i.e. health data (see crash_reporter.dart), and this object goes
/// to the CrashReporter.
class _CorruptOpPayload implements Exception {
  const _CorruptOpPayload(this.kind);

  final SyncOpKind kind;

  @override
  String toString() => 'CorruptOpPayload(${kind.name})';
}

/// Sync part of [HomeStore] (DATA-7): the persisted write outbox with replay
/// and backoff, lifetime-stats deltas, cache write-through and the error/snack
/// paths, plus account/cache cleanup ([deleteAccount], [signOutCleanup]).
/// Pure file split — behaviour is unchanged from home_store.dart.
mixin _HomeStoreSyncPart on _HomeStoreBase {
  // --- DATA-7 write outbox --------------------------------------------------
  // Failed sync writes do NOT roll back local state; they land here as
  // persisted [SyncOp]s and replay idempotently on boot, lifecycle flush, the
  // next successful operation and the backoff timer.
  List<SyncOp> _outbox = <SyncOp>[];
  bool _outboxReplayInFlight = false;
  Timer? _outboxRetryTimer;
  int _outboxRetryAttempt = 0;

  /// Whether the persisted sync state (outbox + stats deltas) has been adopted
  /// into the store. Until then an empty [_outbox] says nothing about the
  /// previous session's blob, so [signOutCleanup] must preserve it unseen
  /// (A2). Stays false after a FAILED hydration attempt too: the blob may be
  /// intact and merely unreadable right now.
  bool _syncStateHydrated = false;

  /// Gap F: reading the outbox slot THREW (as opposed to: the slot was empty).
  /// While this holds, the in-memory state is not a valid version of the
  /// persisted blob and must not overwrite it — [_persistOutbox] retries
  /// hydration once instead.
  bool _outboxHydrationFailed = false;
  bool _outboxRepairInFlight = false;

  /// Same for the deltas slot (W7b). [_persistPendingStatsDeltas] always
  /// rewrites the slot wholesale, so a swallowed read error would restart it
  /// at 0 and leave the lifetime counters too low. Same mechanism as above
  /// (flag + one-shot re-hydration).
  bool _statsHydrationFailed = false;
  bool _statsRepairInFlight = false;

  /// The subtle queue hint (offline OR "will retry") is shown ONCE per error
  /// episode, reset on the next sync success. Which of the two texts appears
  /// is decided by the FIRST error of the episode ([isNetworkSyncError]).
  bool _syncHintShown = false;

  /// Like [_syncHintShown], but for the severe case: the outbox dropped ops for
  /// good (poison op, exhausted budget or queue cap). Also once per episode.
  bool _outboxLossNotified = false;

  /// Like [_outboxLossNotified], but for the loss of a DELETE. A second flag on
  /// purpose: the two messages say opposite things ("something is missing" vs
  /// "something is back"), so one flag would swallow the delete notice.
  bool _outboxDeleteLossNotified = false;

  /// Entities whose op was dropped for good (Review 2026-08-08, A6).
  ///
  /// They may not exist server-side while still visible locally. A later live
  /// write would be a PATCH, and a PATCH hitting 0 rows returns 204 — success,
  /// silently wrong. Writes to these entities therefore go through the outbox,
  /// where every op is a full upsert on the client UUID ([_syncOrQueue]), which
  /// REPAIRS the entity instead of deleting it locally.
  ///
  /// Deliberately not persisted: after a cold start the server load replaces
  /// the meal list anyway, so there is nothing left to repair.
  final Set<String> _orphanedEntities = <String>{};

  /// Entities with a live write IN FLIGHT, plus the op already queued for it
  /// (gap B: queue first, then deliver).
  ///
  /// Three jobs:
  ///  * [_syncOrQueue] tells "busy because something failed" (queue hint) from
  ///    "busy because a write is running" (no hint).
  ///  * [_enqueueOp] must not let a counting op be coalesced away
  ///    (see [_koaleszenzUnsicher]).
  ///  * [_replayOutbox] skips them, otherwise replay writes the same row twice
  ///    and a mealInsert counts the meal twice.
  ///
  /// Deliberately not persisted: after a cold start no write is running and the
  /// op sits in the persisted queue anyway.
  final Map<String, SyncOp> _inFlightOps = <String, SyncOp>{};

  int _pendingMealsDelta = 0;
  int _pendingWeightLogsDelta = 0;

  /// Idempotency key of the currently pending delta bundle — the id
  /// `increment_lifetime_stats(p_request_id)` retains for 30 days
  /// (migration 20260814120000_audit_rls_guard.sql).
  ///
  /// Invariant: non-`null` exactly while deltas are pending. Created with the
  /// bundle's first delta, persisted alongside the numbers, so it survives a
  /// cold start. A NEW id appears only once a bundle is booked and a fresh one
  /// starts — only a retry with the SAME id is recognised as a repeat.
  ///
  /// The bundle carries LIVE deltas only; replay counts through its own
  /// [SyncOpKind.statsIncrement] entry with a derived id.
  String? _pendingStatsRequestId;

  bool _statsFlushInFlight = false;
  Timer? _statsSaveDebounce;

  /// Not yet synced write operations (view for tests/debug).
  List<SyncOp> get pendingOutbox => List.unmodifiable(_outbox);

  /// Cross-reference to the tracking part (implemented in
  /// [_HomeStoreTrackingPart]): outbox replay books the streak day of a
  /// replayed meal server-side.
  void _recordTrackingDay({DateTime? day});

  // --- Error/sync routing ---------------------------------------------------

  /// Failure of an operation WITHOUT the outbox net (e.g. account deletion):
  /// red snack with a classified message, NEVER the raw exception text (schema
  /// leakage). The raw exception goes to dev.log + CrashReporter.
  ///
  /// [message] replaces only the snack text, for callers that know more than
  /// the generic classification (e.g. [deleteAccountErrorMessage] knows the
  /// server-side reauth rejection). Log and CrashReporter stay untouched.
  ///
  /// [netzfehlerMelden]: report even a plain outage. Default off (F1-04: the
  /// user sees the offline text, Sentry only what is not an outage); the
  /// account deletion turns it on — a GDPR request that did not go through
  /// must be visible, whatever the cause.
  void _reportSyncError(String operation, Object error, StackTrace stack,
      {String? message, bool netzfehlerMelden = false}) {
    dev.log('$operation failed', error: error, name: 'eatova_sync');
    unawaited(netzfehlerMelden
        ? CrashReporter.capture(error, stack, context: operation)
        : CrashReporter.captureSyncFailure(error, stack, context: operation));
    if (_disposed) return;
    _emitSnack(
      message ?? directSyncErrorMessage(error, _l10n),
      icon: Icons.error_outline_rounded,
      tone: SnackTone.error,
      duration: kSnackError,
    );
  }

  /// Fire-and-forget sync write WITHOUT rollback (DATA-7): optimistic local
  /// state stands, and the operation sits as a persisted outbox entry in the
  /// retry queue until the server acknowledges it.
  ///
  /// Gap B — ordering: the op is created and persisted FIRST, then delivered,
  /// then removed on success. Creating it in `catchError` lost it to a kill
  /// before the failure, and a request that HANGS fires neither `then` nor
  /// `catchError` (Supabase/PostgREST calls carry no timeout).
  ///
  /// If a FAILED op for the same entity is already queued, the new operation is
  /// appended instead of written live: a live write would overtake the pending
  /// op (e.g. an update whose insert is still outstanding hits 0 rows, and
  /// replay would then write the stale state afterwards).
  ///
  /// Same for entities whose op was once DROPPED ([_orphanedEntities], A6):
  /// the live path (PATCH on 0 rows = 204 = "success") would never notice.
  ///
  /// [onDelivered] runs ONLY after a successful LIVE delivery, for the counter
  /// side effects the replay path handles itself. When the op is queued instead
  /// the callback stays out, otherwise the value counts twice.
  ///
  /// The return value says what REALLY happened (gap E). Callers evaluating it
  /// set [aufruferMeldetAusgang] and take over notifying the user: the generic
  /// queue hint stays out (it would immediately clear the caller's more precise
  /// snack), and the answer arrives after [kSyncDeliveryWindow] at the latest.
  /// Fire-and-forget callers simply ignore the value.
  Future<SyncDelivery> _syncOrQueue(
    String operation,
    Future<void> Function() action,
    SyncOp Function() buildOp, {
    VoidCallback? onDelivered,
    bool aufruferMeldetAusgang = false,
  }) {
    // Without sync there is nothing to deliver (preview/test shell).
    if (sync == null) return Future<SyncDelivery>.value(SyncDelivery.delivered);
    final op = buildOp();
    final entitaetBelegt = _orphanedEntities.contains(op.entityKey) ||
        _outbox.any((o) => o.entityKey == op.entityKey);
    // Busy because a live write is RUNNING is not busy because one FAILED:
    // only a failure justifies the queue hint.
    final nurLaufenderWrite = _inFlightOps.containsKey(op.entityKey);
    _enqueueOp(op);
    if (entitaetBelegt) {
      if (!nurLaufenderWrite) {
        if (!aufruferMeldetAusgang) _notifyQueued(null);
        _scheduleOutboxRetry();
      }
      // No live write: the running one or the replay delivers in order
      // (FIFO per entity).
      return Future<SyncDelivery>.value(SyncDelivery.queuedRetry);
    }
    _inFlightOps[op.entityKey] = op;
    final zustellung = action().then<SyncDelivery>((_) {
      _inFlightOps.remove(op.entityKey);
      _dequeueDeliveredOp(op);
      onDelivered?.call();
      _onSyncSuccess();
      return SyncDelivery.delivered;
    }).onError<Object>((e, st) {
      _inFlightOps.remove(op.entityKey);
      _handleSyncFailure(operation, e, st,
          aufruferMeldetAusgang: aufruferMeldetAusgang);
      return queuedDelivery(e);
    });
    if (!aufruferMeldetAusgang) return zustellung;
    // Only for waiting callers, otherwise the timer hangs off EVERY write. The
    // op is already in the persisted queue, so "queued" stays true after a
    // timeout even if the request lands later.
    return zustellung.timeout(kSyncDeliveryWindow,
        onTimeout: () => SyncDelivery.queuedRetry);
  }

  /// Sync write failed: hint subtly, schedule a retry. No rollback, no red
  /// toast. The op already sits in the persisted queue (gap B) and simply stays
  /// there; re-queueing is deliberately avoided because it may legitimately be
  /// gone by now (coalesced, capped, delivered by replay).
  void _handleSyncFailure(
    String operation,
    Object error,
    StackTrace stack, {
    bool aufruferMeldetAusgang = false,
  }) {
    dev.log('$operation failed — Op bleibt in der Outbox liegen',
        error: error, name: 'eatova_sync');
    // `captureSyncFailure` instead of `capture`: a plain network outage is the
    // intended flow here, not an incident — otherwise every offline write
    // raised a high-priority Sentry issue.
    unawaited(CrashReporter.captureSyncFailure(error, stack,
        context: operation));
    if (_disposed) return;
    // The caller says it more precisely, in ONE toast. [_syncHintShown] stays
    // untouched so a later, DIFFERENT action still gets its hint.
    if (!aufruferMeldetAusgang) _notifyQueued(error);
    _scheduleOutboxRetry();
  }

  /// Removes the LIVE-delivered op from the queue — by identity, not by entity
  /// key: a younger op may have coalesced into its place while the write ran,
  /// and that one describes state the server does not have yet.
  void _dequeueDeliveredOp(SyncOp op) {
    // A delivery confirmed after dispose belongs to a session that is gone;
    // its persisted op replays idempotently on the next login (F1-02).
    if (_disposed) return;
    final at = _outbox.indexWhere((o) => identical(o, op));
    if (at < 0) return;
    _outbox = [..._outbox]..removeAt(at);
    _persistOutbox();
  }

  /// May [op] REPLACE (coalesce) a queued op of the same entity? Not while a
  /// live write for that entity is running whose replay books a COUNTER.
  ///
  /// A mealInsert's replay books +1 meal. If a later update coalesces it away,
  /// the op whose live success counts disappears, but the merged op is still a
  /// mealInsert and counts a second time on replay. So append instead of
  /// replace; per-entity order (FIFO) is preserved.
  ///
  /// Load-bearing: live counting uses the bundle id, replay counting the id
  /// derived from the source UUID — two distinct operations server-side, so
  /// they do not dedupe each other. The exclusivity of both paths is the guard.
  bool _koaleszenzUnsicher(SyncOp op) {
    final laufend = _inFlightOps[op.entityKey];
    return laufend != null &&
        (laufend.kind == SyncOpKind.mealInsert ||
            laufend.kind == SyncOpKind.weightInsert);
  }

  void _enqueueOp(SyncOp op) {
    // Append-only during a running replay: it may be playing exactly the op
    // whose payload would otherwise be coalesced (and dropped on removal).
    // Same for an op with a live write in flight (see _koaleszenzUnsicher).
    _outbox = enqueueCoalesced(_outbox, op,
        appendOnly: _outboxReplayInFlight || _koaleszenzUnsicher(op));
    // Cap only outside a running replay: the replay loop walks indices, and a
    // head trim would pull its cursor out from under it. The next enqueue
    // afterwards trims the few extra ops again.
    if (!_outboxReplayInFlight) {
      final capped = capOutbox(_outbox);
      if (capped.dropped.isNotEmpty) {
        dev.log(
            'Outbox-Cap erreicht: ${capped.dropped.length} aelteste Op(s) '
            'verworfen (Queue > $kOutboxMaxOps)',
            name: 'eatova_sync');
        // Technical facts only — NEVER op.payload (meals/weights are health
        // data, see crash_reporter.dart).
        CrashReporter.breadcrumb(
            'outbox-cap: ${capped.dropped.length} ops dropped');
        _outbox = capped.queue;
        // The cap trims deletes last, but it does trim them (hard limit, see
        // capOutbox) — then the replay path applies: restore entries, report
        // both loss kinds separately.
        final lostDeletes = capped.dropped.where((o) => o.isDelete).toList();
        if (lostDeletes.isNotEmpty) {
          unawaited(_restoreDroppedDeletes(lostDeletes));
        }
        _notifyDroppedOps(capped.dropped);
      }
    }
    _persistOutbox();
  }

  /// Subtle hint that a write landed in the outbox. Text comes from the pure
  /// mapping (sync_error_messages.dart), never with exception details. [error]
  /// is null when the op was queued behind a pending one without a live
  /// attempt; then the neutral retry text applies.
  void _notifyQueued(Object? error) {
    if (_disposed || _syncHintShown) return;
    _syncHintShown = true;
    final offline = error != null && isNetworkSyncError(error);
    _emitSnack(
      queuedSyncHint(error, _l10n),
      icon: offline ? Icons.cloud_off_rounded : Icons.sync_problem_rounded,
      tone: SnackTone.neutral,
    );
  }

  /// Reports the losses of ONE cap event, split by kind. A single
  /// `_notifyOutboxLoss(deletesLost: dropped.any(isDelete))` would swallow the
  /// write loss in the mixed case: if deletes fall, capOutbox ordering means
  /// ALL writes fell first, and the user would lose them under the wrong
  /// message.
  void _notifyDroppedOps(List<SyncOp> dropped) {
    final deletes = dropped.where((o) => o.isDelete).length;
    // statsIncrement entries are counters, not user content — "an entry is
    // missing" would be the wrong message for them.
    final inhalte = dropped
        .where((o) => !o.isDelete && o.kind != SyncOpKind.statsIncrement)
        .length;
    if (inhalte > 0) _notifyOutboxLoss();
    if (deletes > 0) _notifyOutboxLoss(deletesLost: true);
  }

  /// Reports ops dropped FOR GOOD — unlike [_notifyQueued] this is real data
  /// loss. The text carries no technical details; the raw exception goes to
  /// dev.log + CrashReporter only. Once per episode.
  ///
  /// [deletesLost] picks the inverse text: a dropped write means something is
  /// MISSING, a dropped delete means something is BACK. Both count separately,
  /// so an episode says each exactly once.
  void _notifyOutboxLoss({bool deletesLost = false}) {
    if (_disposed) return;
    if (deletesLost) {
      if (_outboxDeleteLossNotified) return;
      _outboxDeleteLossNotified = true;
    } else {
      if (_outboxLossNotified) return;
      _outboxLossNotified = true;
    }
    _emitSnack(
      deletesLost ? outboxDeleteLossHint(_l10n) : outboxLossHint(_l10n),
      icon: Icons.sync_problem_rounded,
      tone: SnackTone.error,
      duration: kSnackError,
    );
  }

  /// Restores the entries of dropped DELETE ops into local state (A5).
  ///
  /// A dropped delete is the only loss that UNDOES itself: the row is gone
  /// locally but not server-side, and no later write touches the entity, so
  /// [_orphanedEntities] never kicks in. Without this the user notices nothing
  /// until a cold start counts the deleted meal again. This is what makes the
  /// finite [kOutboxDeleteMinAge] deadline acceptable: the drop ends visibly
  /// and repairably instead of silently.
  ///
  /// The content only exists on the server (a delete op has an empty payload),
  /// so this costs one read per affected collection. If the read does NOT find
  /// the row, the delete had arrived after all — the read doubles as the check.
  ///
  /// Each collection has its own try: one failed read must not take the others
  /// down.
  Future<void> _restoreDroppedDeletes(List<SyncOp> ops) async {
    final s = sync;
    if (s == null || _disposed) return;
    final mealIds = <String>{}, favoriteIds = <String>{}, recipeSlugs = <String>{};
    for (final op in ops) {
      switch (op.kind) {
        case SyncOpKind.mealDelete:
          mealIds.add(op.entityId);
        case SyncOpKind.favoriteDelete:
          favoriteIds.add(op.entityId);
        case SyncOpKind.recipeDelete:
          recipeSlugs.add(op.entityId);
        default:
          break;
      }
    }
    if (mealIds.isNotEmpty) {
      try {
        // By id, NOT via the window load: the row can be older than the boot
        // window (delete from the archive day picker).
        final rows = await s.meals.loadLoggedMealsByIds(mealIds);
        final back = rows.where((m) => mealIds.contains(m.id)).toList();
        if (back.isNotEmpty && !_disposed) {
          _mutate(() {
            final known = loggedMeals.map((m) => m.id).toSet();
            loggedMeals = <LoggedMeal>[
              ...loggedMeals,
              ...back.where((m) => !known.contains(m.id)),
            ]..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
            final today = clock.now();
            dailyConsumedKcal = consumedKcalForFoodDate(today);
            macroProgress = macroProgressForFoodDate(today);
          });
          _cacheLoggedMeals();
        }
      } catch (e, st) {
        _reportRestoreFailure('meals', e, st);
      }
    }
    if (favoriteIds.isNotEmpty) {
      try {
        final rows = await s.meals.loadFavorites();
        final back = rows.where((f) => favoriteIds.contains(f.id)).toList();
        if (back.isNotEmpty && !_disposed) {
          _mutate(() {
            final known = favorites.map((f) => f.id).toSet();
            favorites = <FavoriteMeal>[
              ...favorites,
              ...back.where((f) => !known.contains(f.id)),
            ];
          });
          _cacheFavorites();
        }
      } catch (e, st) {
        _reportRestoreFailure('favorites', e, st);
      }
    }
    if (recipeSlugs.isNotEmpty) {
      try {
        final rows = await s.userRecipes.load();
        final back = rows.where((r) => recipeSlugs.contains(r.slug)).toList();
        if (back.isNotEmpty && !_disposed) {
          _mutate(() {
            final known = _userRecipes.map((r) => r.slug).toSet();
            _userRecipes = <FitnessRecipe>[
              ..._userRecipes,
              ...back.where((r) => !known.contains(r.slug)),
            ];
          });
          // As for meals/favorites: the restore must reach the cache, else the
          // recipe is gone again on the next offline cold start (gap A).
          _cacheUserRecipes();
        }
      } catch (e, st) {
        _reportRestoreFailure('recipes', e, st);
      }
    }
  }

  /// The restore is best effort: if the read fails (offline), the entry stays
  /// invisible until the next boot, which fetches it from the server anyway.
  /// The loss snack runs independently.
  void _reportRestoreFailure(String what, Object e, StackTrace st) {
    dev.log('Outbox: Wiedereinblendung nach verworfenem Delete '
        'fehlgeschlagen ($what)', error: e, name: 'eatova_sync');
    unawaited(CrashReporter.captureSyncFailure(e, st,
        context: 'outbox-restore-$what'));
  }

  /// After a successful sync write: end the error episode, reset the backoff
  /// and replay any queued ops right away.
  void _onSyncSuccess() {
    if (_disposed) return;
    _syncHintShown = false;
    _outboxLossNotified = false;
    _outboxDeleteLossNotified = false;
    _outboxRetryAttempt = 0;
    if (_outbox.isNotEmpty && !_outboxReplayInFlight) {
      unawaited(_replayOutbox());
    }
  }

  /// Arms the next outbox/stats retry at the CURRENT backoff stage
  /// (30s -> 1m -> 2m -> 4m cap; reset on success) — but only while no timer
  /// is active (F1-03). Every failure used to cancel and re-arm it and bump
  /// the stage, so four offline meals in two minutes pushed the first replay
  /// four minutes past the last log. The stage now moves only in
  /// [_bumpRetryStage], at the end of a failed pass. No connectivity package:
  /// the timer is the only guard, plus boot, lifecycle flush and the next
  /// success trigger a replay.
  void _scheduleOutboxRetry() {
    if (_disposed || sync == null) return;
    if (_outbox.isEmpty &&
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

  /// Next backoff stage — only after a pass that ended with something still
  /// undelivered. Applies to the NEXT arming; an armed timer keeps its delay.
  void _bumpRetryStage() {
    if (_outboxRetryAttempt < 3) _outboxRetryAttempt++;
  }

  /// The timer's work: replay, then flush the stats channel. If only deltas
  /// are open the replay has no end to escalate at, so the tick climbs the
  /// stage itself before the flush — its failure then arms at the new stage,
  /// its success resets to 0 as usual.
  Future<void> _retryTick() async {
    final hatteOps = _outbox.isNotEmpty;
    await _replayOutbox(vomTimer: true);
    if (_disposed) return;
    if (!hatteOps &&
        (_pendingMealsDelta != 0 || _pendingWeightLogsDelta != 0)) {
      _bumpRetryStage();
    }
    await _flushStatsDelta();
  }

  /// Replays the persisted outbox strictly FIFO against Supabase. Order per
  /// entity is preserved; a failing op blocks only its OWN entity for this
  /// pass. Every successful op is removed and the rest persisted immediately
  /// (kill-safe: an abort mid-run at worst repeats idempotent ops).
  ///
  /// Failures are sorted by [_verdictFor] (= [classifyOutboxFailure] plus the
  /// two state-dependent rules from Review 2026-08-08):
  ///  * [OutboxVerdict.drop] — dropped for good, otherwise it would retry
  ///    forever and permanently block its entity ([_syncOrQueue] cuts that
  ///    entity off from the server). The entity lands in [_orphanedEntities].
  ///  * [OutboxVerdict.retryCounted] — stays, spends one attempt.
  ///  * [OutboxVerdict.retryFree] — stays without spending budget (network
  ///    errors; offline, boot + flush + timer must not drain the budget).
  ///
  /// [vomTimer]: the pass was started by the backoff timer. Only such a pass
  /// climbs the stage when it ends blocked; a resume/backgrounding flush or a
  /// boot pass failing offline leaves the ladder alone (F1-03).
  Future<void> _replayOutbox({bool vomTimer = false}) async {
    final s = sync;
    if (s == null || _outboxReplayInFlight || _outbox.isEmpty) return;
    _outboxReplayInFlight = true;
    final blocked = <String>{};
    var anySuccess = false;
    var droppedWrites = false;
    final droppedDeletes = <SyncOp>[];
    try {
      var i = 0;
      while (i < _outbox.length) {
        final op = _outbox[i];
        // If a live write is running for the entity, the op belongs to it
        // (gap B) — replaying it too would write the same row twice and a
        // mealInsert would count the meal twice. Its outcome triggers the next
        // pass itself; no `blocked` entry, else a silent request would keep the
        // backoff timer alive forever.
        if (blocked.contains(op.entityKey) ||
            _inFlightOps.containsKey(op.entityKey)) {
          i++;
          continue;
        }
        try {
          await _performOp(s, op);
        } catch (e, st) {
          // The list may have changed during the await, so find the op by
          // identity instead of trusting the index.
          final at = _outbox.indexWhere((o) => identical(o, op));
          final verdict = _verdictFor(e, op);
          if (verdict == OutboxVerdict.drop) {
            dev.log(
                'Outbox-Replay: ${op.kind.name} endgueltig verworfen '
                '(Versuch ${op.attempts + 1})',
                error: e,
                name: 'eatova_sync');
            // Kind + raw exception only — never op.payload (health data, see
            // crash_reporter.dart).
            unawaited(CrashReporter.capture(e, st,
                context: 'outbox-drop-${op.kind.name}'));
            // A5: a dropped delete must not stay silent — the entry still
            // exists server-side and is restored locally after the replay.
            // Counted separately: the two losses mean opposite things.
            if (op.isDelete) {
              droppedDeletes.add(op);
            } else if (op.kind != SyncOpKind.statsIncrement) {
              droppedWrites = true;
            }
            // A6: the entity is now potentially orphaned (present locally, not
            // server-side), so future writes must go through the outbox, where
            // they arrive as a full upsert. Content ops only: nobody writes to
            // 'stats:<uuid>' again, and its loss is a counter, not an entry.
            if (op.kind != SyncOpKind.statsIncrement) {
              _orphanedEntities.add(op.entityKey);
            }
            if (at >= 0) {
              _outbox = [..._outbox]..removeAt(at);
              _persistOutbox();
              // The op that moved up now sits at this position and is next.
              i = at;
            } else {
              i++;
            }
            continue;
          }
          if (verdict == OutboxVerdict.retryCounted && at >= 0) {
            _outbox = [..._outbox]..[at] = op.incrementAttempt();
            _persistOutbox();
          }
          dev.log('Outbox-Replay: ${op.kind.name} bleibt liegen',
              error: e, name: 'eatova_sync');
          // Sync filter (F1-04): an offline pass raised one event per op per
          // pass, every 30 s, for the whole outage.
          unawaited(CrashReporter.captureSyncFailure(e, st,
              context: 'outbox-replay-${op.kind.name}'));
          blocked.add(op.entityKey);
          i++;
          continue;
        }
        anySuccess = true;
        // The entity exists server-side again — the live path may touch it
        // (A6).
        _orphanedEntities.remove(op.entityKey);
        // By identity, not by loop index: the index can go stale during the
        // await (_clearQueuedTrackingDay and _dequeueDeliveredOp both shorten
        // the queue in that window), and `removeAt(i)` would then drop a
        // FOREIGN op or throw a RangeError outside the inner try.
        final at = _outbox.indexWhere((o) => identical(o, op));
        // Removing the op and creating its counter follow-up are ONE list
        // update and thus ONE persisted blob write, so a kill hits either the
        // state before (op present, no entry; the next replay recreates it with
        // the SAME derived id) or after. Appended at the end: the loop still
        // reaches it this pass. The duplicate check is queue hygiene only — a
        // double entry is a server-side no-op thanks to the identical id.
        final followUp = _statsFollowUpFor(op);
        final followUpId = followUp?.entityId;
        bool traegtFollowUp(List<SyncOp> q) =>
            followUpId != null &&
            q.any((o) =>
                o.kind == SyncOpKind.statsIncrement &&
                o.entityId == followUpId);
        if (at >= 0) {
          final next = [..._outbox]..removeAt(at);
          if (followUp != null && !traegtFollowUp(next)) next.add(followUp);
          _outbox = next;
          _persistOutbox();
          // The op that moved up now sits at this position.
          i = at;
        } else {
          // Already removed elsewhere. The follow-up is still created: a
          // coalesced twin replaying later produces the same id, caught locally
          // by the check and server-side by the dedup.
          if (followUp != null && !traegtFollowUp(_outbox)) {
            _outbox = [..._outbox, followUp];
            _persistOutbox();
          }
          i++;
        }
      }
    } finally {
      _outboxReplayInFlight = false;
    }
    if (_disposed) return;
    // Restore first, THEN report: the snack claims the entry is back, so it
    // must be there when the user looks.
    if (droppedDeletes.isNotEmpty) await _restoreDroppedDeletes(droppedDeletes);
    if (_disposed) return;
    // Both messages if both happened — they describe two different losses.
    if (droppedWrites) _notifyOutboxLoss();
    if (droppedDeletes.isNotEmpty) _notifyOutboxLoss(deletesLost: true);
    // An empty queue is "done" even if ops WERE blocked: they were all dropped,
    // so a backoff timer would have nothing left to do.
    if (blocked.isEmpty || _outbox.isEmpty) {
      _outboxRetryAttempt = 0;
      // Only the outbox is done; open stats deltas keep their timer.
      if (_pendingMealsDelta == 0 && _pendingWeightLogsDelta == 0) {
        _outboxRetryTimer?.cancel();
        _outboxRetryTimer = null;
      }
      if (anySuccess) {
        _syncHintShown = false;
        _outboxLossNotified = false;
        _outboxDeleteLossNotified = false;
      }
    } else {
      // A timer pass ended with ops still blocked: climb one stage, then arm
      // at it. Any other pass (resume flush, boot) only arms if idle. Ladder
      // from the first live failure: 30 s, 60 s, 120 s, 240 s (F1-03).
      if (vomTimer) _bumpRetryStage();
      _scheduleOutboxRetry();
    }
  }

  /// Decides what happens to a failed op. Thin wrapper around
  /// [classifyOutboxFailure]; the two state-dependent rules live here:
  ///
  ///  * A8 — an unreadable payload is undeliverable and takes the DROP path.
  ///  * A4 — a drop caused only by the exhausted attempt budget also needs wall
  ///    clock time ([kOutboxMinAgeBeforeDrop]). The counter-check with
  ///    `attempts: 0` reveals the cause: still "drop" without a spent budget
  ///    means the error itself (poison op) and takes effect immediately.
  ///  * A5 — [SyncOp.isDelete] has no immediate drop at all, and its deadline
  ///    is the long [kOutboxDeleteMinAge]. Both conditions must hold: budget
  ///    alone burns to lifecycle churn, the clock alone would drop a long
  ///    offline op at the first server rejection.
  ///
  /// The wall clock runs through `clock.now()`, so the deadline is testable and
  /// a backwards system-time jump cannot make an op undroppable.
  OutboxVerdict _verdictFor(Object error, SyncOp op) {
    if (error is _CorruptOpPayload) return OutboxVerdict.drop;
    final verdict = classifyOutboxFailure(error, op.attempts, kind: op.kind);
    if (verdict != OutboxVerdict.drop) return verdict;
    if (op.isDelete) {
      return _agedOut(op, kOutboxDeleteMinAge)
          ? OutboxVerdict.drop
          : OutboxVerdict.retryCounted;
    }
    if (classifyOutboxFailure(error, 0, kind: op.kind) == OutboxVerdict.drop) {
      return OutboxVerdict.drop;
    }
    return _agedOut(op, kOutboxMinAgeBeforeDrop)
        ? OutboxVerdict.drop
        : OutboxVerdict.retryCounted;
  }

  bool _agedOut(SyncOp op, Duration minAge) =>
      clock.now().difference(op.queuedAt) >= minAge;

  /// Runs ONE outbox op against the server. Throws on sync error (the replay
  /// loop then keeps the op) and on an unreadable payload
  /// ([_CorruptOpPayload] — the op is dropped, A8).
  ///
  /// The LIFETIME counter of a counting op is deliberately NOT booked here: the
  /// replay loop creates its [SyncOpKind.statsIncrement] follow-up atomically
  /// with the op's removal instead (see [_statsFollowUpFor], [_replayOutbox]),
  /// so a kill in between cannot count twice. The streak day stays here:
  /// [_recordTrackingDay] is idempotent per day server-side.
  Future<void> _performOp(EatovaSync s, SyncOp op) async {
    switch (op.kind) {
      case SyncOpKind.mealInsert:
        final meal = op.meal;
        if (meal == null) throw _CorruptOpPayload(op.kind);
        await s.meals.insertLoggedMeal(meal);
        // Book the MEAL's streak day, not "today" — replay can run days later.
        // record_tracking_day is idempotent per day and a server-side no-op for
        // days before the last counted one.
        if (op.trackDay) {
          _recordTrackingDay(day: DateTime.parse(meal.effectiveLocalDay));
        }
      case SyncOpKind.mealUpsert:
        final meal = op.meal;
        if (meal == null) throw _CorruptOpPayload(op.kind);
        await s.meals.insertLoggedMeal(meal);
      case SyncOpKind.mealDelete:
        await s.meals.deleteLoggedMeal(op.entityId);
      case SyncOpKind.weightInsert:
        final kg = op.weightKg;
        final ts = op.recordedAt;
        if (kg == null || ts == null) throw _CorruptOpPayload(op.kind);
        await s.tracking.insertWeight(kg, ts, id: op.entityId);
      case SyncOpKind.favoriteUpsert:
        final fav = op.favorite;
        if (fav == null) throw _CorruptOpPayload(op.kind);
        await s.meals.upsertFavorite(fav);
      case SyncOpKind.favoriteDelete:
        await s.meals.deleteFavorite(op.entityId);
      case SyncOpKind.recipeUpsert:
        final recipe = op.recipe;
        if (recipe == null) throw _CorruptOpPayload(op.kind);
        await s.userRecipes.upsert(recipe);
      case SyncOpKind.recipeDelete:
        await s.userRecipes.delete(op.entityId);
      case SyncOpKind.profileUpsert:
        // Gap D. The save is a full row upsert on the user id, so idempotent.
        // An unreadable/incomplete payload does NOT pass (A8 path): replay
        // would otherwise clobber a real profile row with invented numbers.
        final p = op.profile;
        if (p == null) throw _CorruptOpPayload(op.kind);
        await s.profile.save(p);
      case SyncOpKind.statsIncrement:
        final meals = op.statsMeals;
        final weightLogs = op.statsWeightLogs;
        // An empty increment or a non-UUID entityId can never be delivered
        // (the RPC parameter is uuid) — A8 path, like any unreadable payload.
        if ((meals <= 0 && weightLogs <= 0) || !isUuidShape(op.entityId)) {
          throw _CorruptOpPayload(op.kind);
        }
        // entityId IS the request id: every repeat sends the same one, so an
        // already booked entry is not added again and leaves the queue as a
        // normal success.
        final frischeZeile = await s.lifetimeStats.increment(
          meals: meals,
          weightLogs: weightLogs,
          requestId: op.entityId,
        );
        if (_disposed) return;
        _mutate(() {
          lifetimeStats = frischeZeile;
          // As in _flushStatsDelta: the server row is authoritative for the
          // counters, not for an undelivered streak day.
          _overlayPendingTrackingDays();
        });
        _cacheLifetimeStats();
      case SyncOpKind.trackingDay:
        // The day lives in entityId (YYYY-MM-DD), not in the payload; an
        // unparsable value is still the A8 case — never deliverable.
        final tag = DateTime.tryParse(op.entityId);
        if (tag == null) throw _CorruptOpPayload(op.kind);
        final fresh = await s.lifetimeStats.recordTrackingDay(tag);
        if (_disposed) return;
        _mutate(() {
          lifetimeStats = fresh;
          _overlayPendingTrackingDays();
        });
        _cacheLifetimeStats();
    }
  }

  /// The counter follow-up of a successfully replayed op, or null if the op
  /// does not count. Created ATOMICALLY with the op's removal (same blob write,
  /// see [_replayOutbox]) and carrying a request id DERIVED from the source
  /// UUID, so every repeat is the same operation to the server.
  SyncOp? _statsFollowUpFor(SyncOp op) {
    final zaehltMeal = op.kind == SyncOpKind.mealInsert;
    final zaehltWeight = op.kind == SyncOpKind.weightInsert;
    if (!zaehltMeal && !zaehltWeight) return null;
    final requestId = deriveStatsRequestId(op.entityId);
    if (requestId == null) {
      // entityId is not a UUID — impossible from our factories, so only
      // reachable via a tampered/foreign blob. The counter is skipped for this
      // one op. Op kind only in reporting, never the payload.
      dev.log('Outbox: Stats-Request-Id nicht ableitbar (${op.kind.name}) — '
          'Zaehler-Folgeeintrag entfaellt', name: 'eatova_sync');
      CrashReporter.breadcrumb('stats-rid underivable: ${op.kind.name}');
      return null;
    }
    return SyncOp.statsIncrement(
      requestId: requestId,
      meals: zaehltMeal ? 1 : 0,
      weightLogs: zaehltWeight ? 1 : 0,
    );
  }

  /// Mirrors unsynced outbox ops into the (cached or freshly loaded) state.
  /// Idempotent: upserts replace or insert, deletes remove. Must run inside a
  /// _mutate block.
  void _applyPendingOpsToState() {
    if (_outbox.isEmpty) return;
    var mealsTouched = false;
    for (final op in _outbox) {
      switch (op.kind) {
        case SyncOpKind.mealInsert:
        case SyncOpKind.mealUpsert:
          final meal = op.meal;
          if (meal == null) break;
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
          _userRecipes =
              _userRecipes.where((r) => r.slug != op.entityId).toList();
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

  /// GDPR Art. 17: deletes account and all data server-side (RPC). Returns true
  /// if the deletion went through (the shell may then sign out), false on error
  /// so the user can retry.
  Future<bool> deleteAccount() async {
    try {
      await sync?.deleteAccount();
    } catch (e, st) {
      // The server-side reauth rejection (EX_REAUTH_REQUIRED) needs its own
      // sentence: retrying later does not help, a new mail code is required.
      _reportSyncError('Konto-Löschung', e, st,
          message: deleteAccountErrorMessage(e, _l10n),
          netzfehlerMelden: true);
      return false;
    }
    // D9: scheduled reminders live in the OS, not in our cache — without this
    // they keep firing after the deletion.
    await notificationService.cancelAll();
    // B3: same reason — health state lives in the service object, not in the
    // namespaced cache.
    _resetHealthConnection();
    // No preserveOutbox: the account is gone, so there is no delivery target.
    await _clearCache();
    return true;
  }

  /// Clears the local PII cache (profile, lifetime stats, diary, favorites,
  /// weight, notification flag) on sign-out — unlike [deleteAccount] WITHOUT a
  /// server RPC (Audit 2026-06-09, M-1). Must run BEFORE `signOut()` while the
  /// user is still current: the defensive path needs their id.
  ///
  /// Unsynced writes are no longer destroyed with it (Review 2026-08-08, A2).
  /// A delivery attempt runs first; whatever is left over survives the logout
  /// in the outbox AND the pending stats deltas and replays at the next login
  /// of the same user.
  ///
  /// Both channels count: the meal write can succeed while
  /// `increment_lifetime_stats` (its own RPC) fails, leaving an empty queue and
  /// outstanding counters. Tying `preserveOutbox` to `_outbox.length` alone
  /// would drop the lifetime counters and with them the streak basis.
  ///
  /// PII surviving the logout is acceptable for this one slot: the cache is
  /// AES-256-GCM encrypted and EVERY slot key carries the user id
  /// (`eatova.v1.outbox.<uid>`, see local_cache.dart). Since gap D the slot may
  /// also hold a profile op; same reasoning. `eatova.v1.profile.<uid>` still
  /// falls.
  Future<void> signOutCleanup() async {
    // Deliver before discarding: online the queue is empty afterwards and the
    // full clear applies as before. Bounded (F1-05): a silent socket must not
    // pin the logout — whatever is still undelivered at the deadline is
    // counted below and survives in the preserved slots.
    await _replayOutbox()
        .timeout(kSignOutDeliveryBudget, onTimeout: _logSignOutDeadline);
    // The pending lifetime deltas are their own state, not part of the outbox:
    // the meal write can succeed while `increment_lifetime_stats` fails. So
    // this channel needs its own delivery attempt too, otherwise the logout
    // pulls away the streak basis. A live write finishing during the replay can
    // still book a delta.
    var flushDeadlineHit = false;
    await _flushStatsDelta().timeout(kSignOutDeliveryBudget, onTimeout: () {
      flushDeadlineHit = true;
      _logSignOutDeadline();
    });
    // Only a flush THIS call started and that ran past the deadline is put
    // back: its numbers are neither in the slot nor confirmed. A flight that
    // was already running (the call returned at once) keeps its own outcome.
    if (flushDeadlineHit && _statsFlushInFlight) _requeueInFlightStatsBundle();
    // Only what delivery could not shift justifies a surviving slot. The store
    // state is authoritative once boot has run. `preserveOutbox` holds
    // _outboxKey AND _pendingStatsKey.
    final remaining = _outbox.length +
        _pendingMealsDelta.abs() +
        _pendingWeightLogsDelta.abs();
    // D9: scheduled reminders are OS state and know no user — else the family
    // tablet shows the previous user's streak reminder.
    await notificationService.cancelAll();
    // B3: health state is process-local and knows no user — else B's profile
    // card keeps showing A's connection.
    _resetHealthConnection();
    // Before hydration completes, `remaining == 0` says nothing. Conservative:
    // a wrongly kept empty slot costs nothing, a wrongly cleared one costs up
    // to 500 unacknowledged writes (A2).
    await _clearCache(preserveOutbox: remaining > 0 || !_syncStateHydrated);
  }

  void _logSignOutDeadline() {
    dev.log(
        'signOutCleanup: Zustellversuch nach '
        '${kSignOutDeliveryBudget.inSeconds}s abgebrochen — Rest bleibt im '
        'Sync-Slot',
        name: 'eatova_sync');
  }

  /// Disconnects Apple Health on user change — service AND store field.
  /// `health.reset()` clears verifier and cached `authState`;
  /// `healthAuthState` is the copy the profile card renders.
  void _resetHealthConnection() {
    health.reset();
    healthAuthState = health.authState;
  }

  /// Clears the local cache. Prefers the booted [_cache], the injected
  /// [debugCache] in tests; if the logout beats the boot, it is rebuilt
  /// defensively from the current session user id so nothing is left behind.
  ///
  /// [preserveOutbox] holds back `_outboxKey`/`_pendingStatsKey` (A2).
  Future<void> _clearCache({bool preserveOutbox = false}) async {
    // F1-02: a snapshot still writing (logout right after boot) must finish
    // BEFORE the purge, or its remaining slots land on cleared keys — the
    // encrypting store serialises per key, not across keys. Bounded: past the
    // budget the closed flag set by clear() turns the rest into no-ops.
    final laufend = _cacheSnapshotInFlight;
    if (laufend != null) {
      await laufend.timeout(kCacheSnapshotWaitBudget, onTimeout: () {});
    }
    final cache = _cache ?? debugCache ?? await _resolveCacheForCurrentUser();
    await cache?.clear(preserveOutbox: preserveOutbox);
    // Own-recipe photos are files in the app directory, not in the LocalCache,
    // so they need their own call — same M-1 reasoning as the recipe row, and
    // therefore also under `preserveOutbox: true` (the outbox carries rows, not
    // bytes). Accepted consequence: a replayed recipe upsert keeps its
    // `local:` marker without bytes and falls back to the placeholder.
    await RecipeImageStore.instance.clear();
  }

  Future<LocalCache?> _resolveCacheForCurrentUser() async {
    final userId = sync?.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return null;
    return LocalCache.create(userId);
  }

  // --- Persistence helpers --------------------------------------------------

  /// The snapshot currently writing, so a purge can wait for it (F1-02).
  Future<void>? _cacheSnapshotInFlight;

  /// Writes the full mirror state after a server load. Tracked in
  /// [_cacheSnapshotInFlight]; never runs twice concurrently — the second
  /// caller waits for the first, then writes the (newer) state.
  Future<void> _writeCacheSnapshot() async {
    final laufend = _cacheSnapshotInFlight;
    if (laufend != null) await laufend;
    final eigener = _writeCacheSnapshotNow();
    _cacheSnapshotInFlight = eigener;
    try {
      await eigener;
    } finally {
      if (identical(_cacheSnapshotInFlight, eigener)) {
        _cacheSnapshotInFlight = null;
      }
    }
  }

  Future<void> _writeCacheSnapshotNow() async {
    final cache = _cache;
    if (cache == null) return;
    // A1: without a real hydration source (cache unreadable AND server boot
    // empty) the state is pure ctor defaults. Writing them would clobber the
    // existing data, and the NEXT boot would read them as a real source,
    // opening applySettings' clobber lock. No knowledge -> no snapshot.
    if (!_hydratedFromRealSource) return;
    // `_disposed` between slots: a session loss mid-snapshot must not write
    // the remaining slots after the AuthGate's purge (F1-02).
    if (_disposed) return;
    await cache.writeProfile(profile);
    if (_disposed) return;
    await cache.writeLifetimeStats(lifetimeStats);
    if (_disposed) return;
    await cache.writeLoggedMeals(_cacheableLoggedMeals());
    if (_disposed) return;
    await cache.writeFavorites(favorites);
    if (_disposed) return;
    await cache.writeWeightLog(weightLog);
    if (_disposed) return;
    // Gap A: without this only the just-created recipe reached the cache
    // (write-through), never the server-loaded ones — an offline cold start
    // showed an empty own-recipe list.
    await cache.writeUserRecipes(_userRecipes);
  }

  /// Only entries inside the boot window reach the durable cache. On-demand
  /// loaded older days stay in memory: they would inflate the SharedPreferences
  /// blob without bound and are reloaded from the server anyway. Pending WRITES
  /// for older days stay kill-safe in the persisted outbox.
  List<LoggedMeal> _cacheableLoggedMeals() {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: MealsSync.loggedMealsWindowDays));
    return loggedMeals
        .where((m) => !m.loggedAt.isBefore(cutoff))
        .toList(growable: false);
  }

  void _cacheLifetimeStats() {
    unawaited(_cache?.writeLifetimeStats(lifetimeStats) ?? Future<void>.value());
  }

  // Write-through for the offline slots (DATA-7): every local mutation hits the
  // cache immediately so an offline cold start shows the last state.
  // Fire-and-forget — a cache write must never block the UI path. Filtered to
  // the boot window (see _cacheableLoggedMeals). Debounced (G9b): a burst of
  // five would otherwise encrypt the whole blob five times (~91 ms AES-GCM each
  // at 210 meals). Pending writes are not lost: flushPendingWrites() forces
  // them on lifecycle, clear() discards them on purpose so a running timer
  // cannot write cleared PII back.
  void _cacheLoggedMeals() {
    _cache?.writeLoggedMealsDebounced(_cacheableLoggedMeals());
  }

  void _cacheFavorites() {
    _cache?.writeFavoritesDebounced(favorites);
  }

  void _cacheWeightLog() {
    _cache?.writeWeightLogDebounced(weightLog);
  }

  void _cacheUserRecipes() {
    _cache?.writeUserRecipesDebounced(_userRecipes);
  }

  void _persistOutbox() {
    // After dispose the blob on disk is the last valid state of this session;
    // an in-memory queue touched by a late callback is not (F1-02).
    if (_disposed) return;
    // Gap F: the in-memory state is a valid version of the blob only if
    // hydration could read it. Otherwise `_outbox` is a fresh queue from this
    // session, and writing it destroys up to [kOutboxMaxOps] undelivered
    // writes.
    if (_outboxHydrationFailed) {
      unawaited(_repairOutboxHydration());
      return;
    }
    unawaited(_cache?.writeOutbox(_outbox) ?? Future<void>.value());
  }

  /// Retries a failed outbox hydration before the first write.
  ///
  /// A second read instead of a permanent write lock, because a lock would make
  /// a permanently unreadable blob poison every future session. The second read
  /// separates the two cases:
  ///
  ///  * it SUCCEEDS -> the first error was transient. The read ops are the
  ///    older ones and go before this session's; the normal path then writes
  ///    the merged queue.
  ///  * it fails again -> the blob is unreadable and hence undeliverable. It is
  ///    already lost, and keeping it would drag THIS session's writes down too.
  ///
  /// Uses the THROWING read variant (W7b): with the tolerant
  /// [LocalCache.readOutbox] a broken blob would arrive as `null`,
  /// indistinguishable from "slot empty", and the second failure would go
  /// unreported.
  ///
  /// Runs at most once concurrently; afterwards [_outboxHydrationFailed] is
  /// false either way.
  Future<void> _repairOutboxHydration() async {
    if (_outboxRepairInFlight) return;
    _outboxRepairInFlight = true;
    List<SyncOp>? blob;
    try {
      blob = await _cache?.readOutboxOrThrow();
    } catch (e, st) {
      dev.log('Outbox-Nachhydration fehlgeschlagen — der persistierte Blob '
          'ist unlesbar und damit ohnehin unzustellbar',
          error: e, stackTrace: st, name: 'eatova_sync');
      unawaited(CrashReporter.capture(e, st, context: 'outbox-rehydrate'));
    } finally {
      _outboxRepairInFlight = false;
      _outboxHydrationFailed = false;
    }
    if (_disposed) return;
    if (blob != null && blob.isNotEmpty) {
      CrashReporter.breadcrumb('outbox-rehydrate: ${blob.length} ops restored');
      // Layer this session's ops onto the re-read ones with the regular enqueue
      // mechanics (per-entity coalescing, FIFO), so the merge cannot
      // double-book.
      var vereint = blob;
      for (final op in _outbox) {
        vereint = enqueueCoalesced(vereint, op);
      }
      final capped = capOutbox(vereint);
      _outbox = capped.queue;
      if (capped.dropped.isNotEmpty) {
        // As with the regular cap in [_enqueueOp] — unlike the cap during
        // hydration, where the following boot load cleans up; here boot is long
        // done.
        final lostDeletes = capped.dropped.where((o) => o.isDelete).toList();
        if (lostDeletes.isNotEmpty) {
          unawaited(_restoreDroppedDeletes(lostDeletes));
        }
        _notifyDroppedOps(capped.dropped);
      }
      // The recovered writes are unknown to the state (hydration never saw
      // them) — without this an offline-logged meal would sit in the queue but
      // be invisible in the diary.
      _mutate(_applyPendingOpsToState);
      _scheduleOutboxRetry();
    }
    _persistOutbox();
  }

  void _persistPendingStatsDeltas() {
    // W7b, the brake from [_persistOutbox]: the in-memory numbers are a valid
    // version of the slot only if hydration could read it. Otherwise writing
    // them destroys the previous session's deltas and their request id.
    if (_statsHydrationFailed) {
      unawaited(_repairStatsHydration());
      return;
    }
    unawaited(_cache?.writePendingStatsDeltas(
          meals: _pendingMealsDelta,
          weightLogs: _pendingWeightLogsDelta,
          requestId: _pendingStatsRequestId,
        ) ??
        Future<void>.value());
  }

  /// Retries a failed deltas hydration before the first write — the counterpart
  /// to [_repairOutboxHydration], same reasoning and flow: on success the
  /// re-read numbers are the older ones and get added; on a second failure the
  /// slot was lost anyway and the normal write path resumes.
  ///
  /// Also via the throwing read variant, else a broken slot would arrive as
  /// "empty" and the failure would stay invisible.
  ///
  /// Runs at most once concurrently; afterwards [_statsHydrationFailed] is
  /// false either way.
  Future<void> _repairStatsHydration() async {
    if (_statsRepairInFlight) return;
    _statsRepairInFlight = true;
    ({int meals, int weightLogs, String? requestId})? blob;
    try {
      blob = await _cache?.readPendingStatsDeltasOrThrow();
    } catch (e, st) {
      dev.log('Deltas-Nachhydration fehlgeschlagen — der persistierte Slot '
          'ist unlesbar und damit ohnehin nicht mehr verbuchbar',
          error: e, stackTrace: st, name: 'eatova_sync');
      unawaited(
          CrashReporter.capture(e, st, context: 'pending-stats-rehydrate'));
    } finally {
      _statsRepairInFlight = false;
      _statsHydrationFailed = false;
    }
    if (_disposed) return;
    if (blob != null && (blob.meals != 0 || blob.weightLogs != 0)) {
      // The fact only, no numbers: the slot holds meal and weight counters and
      // this text goes into reporting.
      CrashReporter.breadcrumb('pending-stats-rehydrate: deltas restored');
      _pendingMealsDelta += blob.meals;
      _pendingWeightLogsDelta += blob.weightLogs;
      // The RE-READ bundle's id wins, not the session's: only it can already be
      // booked server-side. Same trade-off as in [_flushStatsDelta]: a bounded
      // shortfall in the abort window beats a permanent overcount that no path
      // ever corrects.
      final wiedergefunden = blob.requestId;
      if (wiedergefunden != null) _pendingStatsRequestId = wiedergefunden;
      _scheduleOutboxRetry();
    }
    _persistPendingStatsDeltas();
  }

  // --- Streak days (second review 2026-08-10) -------------------------------

  /// Queues a tracked logging day whose RPC just failed.
  ///
  /// Without it the optimistic local state did not survive a second: the
  /// debounced [_flushStatsDelta] adopted the fresh server row, which does not
  /// know the day, and [_cacheLifetimeStats] persisted the loss — a broken
  /// streak although the meal had arrived.
  ///
  /// Deliberately NO second persistence channel beside the outbox: it would
  /// have to rebuild kill safety, FIFO, coalescing, cap, budget, backoff, loss
  /// reporting and logout survival. The day replays idempotently, so it belongs
  /// in the existing queue.
  void _queueTrackingDay(DateTime day) {
    if (sync == null || _disposed) return;
    _enqueueOp(SyncOp.trackingDay(localDayKey(day)));
    _scheduleOutboxRetry();
  }

  /// Re-applies undelivered streak days on top of a freshly adopted server row.
  /// Must run inside a `_mutate` block.
  ///
  /// Without it [_queueTrackingDay] would only go half way: the day sits
  /// kill-safe in the queue, but the DISPLAY still jumps to "streak broken"
  /// because [_flushStatsDelta] adopts the fresh server row shortly after. Same
  /// pattern as [_applyPendingOpsToState] on boot, restricted to this one
  /// channel: the stats flush runs on EVERY mutation, and the full overlay over
  /// up to [kOutboxMaxOps] ops does not belong in that hot path.
  ///
  /// [LifetimeStats.recordTrackedDay] is idempotent per day and a no-op for
  /// days before the last counted one, so FIFO order carries itself.
  void _overlayPendingTrackingDays() {
    for (final op in _outbox) {
      if (op.kind != SyncOpKind.trackingDay) continue;
      final tag = DateTime.tryParse(op.entityId);
      if (tag != null) lifetimeStats = lifetimeStats.recordTrackedDay(tag);
    }
  }

  /// Removes a day from the queue whose RPC went through LIVE, so an older
  /// failed op is not replayed later — harmless (the RPC is idempotent per day)
  /// but a needless request, and an op that pins the queue at logout.
  void _clearQueuedTrackingDay(String localDay) {
    final gefiltert = _outbox
        .where((o) =>
            !(o.kind == SyncOpKind.trackingDay && o.entityId == localDay))
        .toList();
    if (gefiltert.length == _outbox.length) return;
    _outbox = gefiltert;
    _persistOutbox();
  }

  // --- Lifetime stats deltas ------------------------------------------------

  /// Books a lifetime delta into the pending bundle.
  ///
  /// Exclusively the LIVE path (`onDelivered` in
  /// home_store_meals/home_store_tracking). Replay counts through its own
  /// [SyncOpKind.statsIncrement] entry instead: this slot commits IMMEDIATELY
  /// while the op leaves the outbox one write later, so a kill in between would
  /// count twice on the next boot.
  void _queueStatsDelta({
    int meals = 0,
    int weightLogs = 0,
  }) {
    // A delivery confirmed after dispose: no slot write, no flush timer with
    // a signed-out client (F1-02). The replay path counts the meal instead if
    // its op is still persisted.
    if (sync == null || _disposed) return;
    _pendingMealsDelta += meals;
    _pendingWeightLogsDelta += weightLogs;
    // A fresh bundle gets its request id here, and ONLY here. `??=` is the
    // point: while the bundle is open it keeps its id, however many deltas
    // arrive and however often the flush fails.
    _pendingStatsRequestId ??= uuidV4();
    // Make pending deltas kill-safe (DATA-7): the next boot hydrates and
    // flushes them.
    _persistPendingStatsDeltas();
    _cacheLifetimeStats();
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_flushStatsDelta());
    });
  }

  Future<void> _flushStatsDelta() async {
    final s = sync;
    if (s == null) return;
    if (_statsFlushInFlight) return;
    final meals = _pendingMealsDelta;
    final weightLogs = _pendingWeightLogsDelta;
    if (meals == 0 && weightLogs == 0) return;
    // Legacy data: a bundle persisted by an older build carries no id — assign
    // one here instead of failing on `null` or discarding the bundle.
    final requestId = _pendingStatsRequestId ?? uuidV4();
    _pendingMealsDelta = 0;
    _pendingWeightLogsDelta = 0;
    // The id is reset WITH the numbers: whatever is queued during the flight
    // belongs to another bundle and gets its own id. Inheriting this one, the
    // server could dismiss it as a repeat and it would be silently lost.
    _pendingStatsRequestId = null;
    // Persist the in-flight state at once: a kill DURING the RPC at worst fails
    // to count the deltas, which beats a double increment on the next boot (the
    // server ADDS, so a replayed booked delta corrupts the counters for good).
    _persistPendingStatsDeltas();
    _statsFlushInFlight = true;
    _inFlightStatsBundle =
        (meals: meals, weightLogs: weightLogs, requestId: requestId);
    try {
      final fresh = await s.lifetimeStats.increment(
        meals: meals,
        weightLogs: weightLogs,
        requestId: requestId,
      );
      if (!_disposed) {
        _mutate(() {
          lifetimeStats = fresh;
          // The server row is authoritative for the COUNTERS, not for an
          // undelivered streak day — this is where it used to vanish.
          _overlayPendingTrackingDays();
        });
        _cacheLifetimeStats();
      }
      _onSyncSuccess();
    } catch (e, st) {
      // DATA-7: no red toast, no rollback — the deltas go back into the
      // persisted queue and run through the retry paths. The id goes back with
      // them: `p_request_id` makes the retry the SAME operation server-side, so
      // an already booked bundle is not added twice (a fresh id would make the
      // protection a facade).
      //
      // Residual risk: a bundle opened DURING the flight merges into this one
      // and inherits the failed id (only that one can already be booked). If
      // the failed call did land, those few deltas are not counted — a bounded
      // shortfall in a rare abort window instead of a permanent overcount.
      dev.log('Statistik-Sync failed — Deltas bleiben gequeued',
          error: e, name: 'eatova_sync');
      // Sync filter (F1-04): offline is the designed flow here too.
      unawaited(CrashReporter.captureSyncFailure(e, st,
          context: 'lifetime-stats-flush'));
      // Already re-queued by the logout deadline: adding again would count
      // the bundle twice on the next login (same id, but doubled numbers).
      if (_inFlightStatsBundle != null) {
        _pendingMealsDelta += meals;
        _pendingWeightLogsDelta += weightLogs;
        _pendingStatsRequestId = requestId;
        _persistPendingStatsDeltas();
      }
      if (!_disposed) {
        _notifyQueued(e);
        _scheduleOutboxRetry();
      }
    } finally {
      _statsFlushInFlight = false;
      _inFlightStatsBundle = null;
    }
  }

  /// The bundle currently on the wire, so a bounded logout can put it back
  /// into the slot (F1-05). Null outside a flight.
  ({int meals, int weightLogs, String requestId})? _inFlightStatsBundle;

  /// Logout deadline hit while a flush is on the wire: the slot holds 0 (the
  /// flight persisted its start state), so the bundle would be lost. Re-queue
  /// it under the SAME request id — if the hanging call lands after all, the
  /// next login's retry is a server-side repeat and adds nothing.
  ///
  /// The id is ASSIGNED, not `??=`: a bundle opened during the flight merges
  /// into this one and must inherit the flight's id (same reasoning as the
  /// catch branch of [_flushStatsDelta]) — only that id can already be
  /// booked; under a fresh id a landed call would be added again on the next
  /// login, a permanent overcount.
  void _requeueInFlightStatsBundle() {
    final bundle = _inFlightStatsBundle;
    if (bundle == null) return;
    _inFlightStatsBundle = null;
    _pendingMealsDelta += bundle.meals;
    _pendingWeightLogsDelta += bundle.weightLogs;
    _pendingStatsRequestId = bundle.requestId;
    _persistPendingStatsDeltas();
  }

  /// Flushes pending debounced writes immediately (app backgrounding) and
  /// replays queued outbox ops.
  void flushPendingWrites() {
    // Before the sync guard: the debounced cache writes (G9b) do not depend on
    // the sync client, and backgrounding inside the debounce window would
    // otherwise lose the last diary state.
    unawaited(_cache?.flush() ?? Future<void>.value());
    final s = sync;
    if (s == null) return;
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce = null;
    unawaited(_flushStatsDelta());
    unawaited(_replayOutbox());
  }
}
