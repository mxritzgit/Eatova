part of 'home_store.dart';

/// Tracking part of [HomeStore]: weight logging (manual + Apple Health
/// import), the health snapshot (steps) and the server-side streak day
/// (record_tracking_day). File split only, no behaviour change.
mixin _HomeStoreTrackingPart on _HomeStoreBase, _HomeStoreSyncPart {
  // healthAuthState lives in _HomeStoreBase next to dailySteps: the logout
  // path in _HomeStoreSyncPart must reset it on user switch (B3), and sync
  // does not depend on this mixin, so it could never see a field declared
  // here.
  DateTime? healthLastFetch;
  bool healthSyncing = false;

  /// Daily activity: steps plus estimated burned kcal per local calendar day
  /// (key: [localDayKey]).
  ///
  /// Today's entry is upserted on every verified health refresh, so the last
  /// refresh of a day is its final value; past days are topped up once per
  /// session by [_maybeBackfillDailyActivity].
  ///
  /// Mutation REPLACES the map: the shell's slice selectors compare by
  /// identity (G11 pattern, see eatova_home_page).
  Map<String, ({int steps, int kcal})> dailyActivity =
      <String, ({int steps, int kcal})>{};

  /// Days this session already attempted a backfill for, so revisiting an
  /// archive day does not cost a health query on every tap.
  final Set<String> _dailyActivityBackfillAttempted = <String>{};

  /// Older entries drop out of the map on upsert; a forever-growing blob is
  /// not worth more than a year of history.
  static const Duration _dailyActivityRetention = Duration(days: 400);

  /// In-memory dedup for the HealthKit weight offer: refreshHealthSteps()
  /// runs on cold start AND every resume, so without this the offer snack
  /// would reappear each time. Deliberately not persisted — one fresh offer
  /// per app start is fine.
  double? _lastOfferedHealthWeightKg;

  // --- Health ---------------------------------------------------------------

  Future<void> connectHealth() async {
    if (_disposed) return;
    _mutate(() => healthSyncing = true);
    final state = await health.requestAuthorization();
    if (_disposed) return;
    _mutate(() => healthAuthState = state);
    if (state == HealthAuthState.granted) {
      await refreshHealthSteps();
    } else {
      _mutate(() => healthSyncing = false);
    }
  }

  Future<void> refreshHealthSteps() async {
    if (_disposed) return;
    _mutate(() => healthSyncing = true);
    final snapshot = await health.readSnapshot();
    if (_disposed) return;
    _mutate(() {
      healthSyncing = false;
      // B3: the service re-verifies the permission on every refresh and can
      // fall back from granted to unverified/denied, so adopt its state in
      // BOTH branches instead of only upgrading on success.
      healthAuthState = health.authState;
      if (snapshot != null) {
        dailySteps = snapshot.stepsToday;
        healthLastFetch = snapshot.fetchedAt;
        // Pin to the SNAPSHOT's day, not "today": a refresh at the midnight
        // second still belongs to the query time.
        _recordDailyActivity(snapshot.fetchedAt, snapshot.stepsToday);
      }
      // No `else { dailySteps = 0; }`: an unverified state yields null, and
      // the last measured value beats an invented zero.
    });
    // Offer the snapshot weight for import (deduped) instead of discarding it.
    if (snapshot != null) {
      _maybeOfferHealthWeight(snapshot.latestWeightKg);
    }
  }

  /// Burned kcal for [date]: live from [dailySteps] today, the pinned value
  /// from [dailyActivity] for past days. 0 means "no entry".
  ///
  /// Every step counts (kcal review 2026-08-21): the daily goal uses a PAL
  /// ladder WITHOUT walking (`ActivityLevel.palFactor`), so the full step sum
  /// is not double counting.
  int burnedKcalForFoodDate(DateTime date) {
    if (_isSameFoodDate(date, clock.now())) {
      return estimateKcalBurnedFromSteps(
        steps: dailySteps,
        weightKg: profile.weightKg,
        heightCm: profile.heightCm,
        sex: profile.sex,
      );
    }
    return dailyActivity[localDayKey(date)]?.kcal ?? 0;
  }

  /// Step count for [date] — live today, pinned for past days. `null` means
  /// "no step source", which hides the steps card instead of claiming 0.
  ///
  /// Today the source counts as present once the permission is verified OR a
  /// step count already arrived, so an early morning 0 is a real 0.
  int? stepsForFoodDate(DateTime date) {
    if (_isSameFoodDate(date, clock.now())) {
      if (healthAuthState == HealthAuthState.granted || dailySteps > 0) {
        return dailySteps;
      }
      return null;
    }
    return dailyActivity[localDayKey(date)]?.steps;
  }

  /// Upserts the calendar day of [day] with [steps]; kcal are frozen using
  /// the CURRENT profile (the estimate is coarser than the weight drift).
  /// Must run inside a _mutate block; the cache write is fire-and-forget.
  void _recordDailyActivity(DateTime day, int steps) {
    if (steps <= 0) return;
    final key = localDayKey(day);
    final kcal = estimateKcalBurnedFromSteps(
      steps: steps,
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
      sex: profile.sex,
    );
    // Unchanged -> bail WITHOUT replacing the map: slice selectors compare by
    // identity, so a resume without new steps must cost neither a rebuild nor
    // an AES-GCM cache write (guarded by home_page_rebuild_test).
    if (dailyActivity[key] == (steps: steps, kcal: kcal)) return;
    // YYYY-MM-DD sorts lexicographically = chronologically, so the cutoff is
    // a string compare, not date parsing.
    final cutoff = localDayKey(clock.now().subtract(_dailyActivityRetention));
    dailyActivity = <String, ({int steps, int kcal})>{
      for (final e in dailyActivity.entries)
        if (e.key.compareTo(cutoff) >= 0) e.key: e.value,
      key: (steps: steps, kcal: kcal),
    };
    unawaited(_cache?.writeDailyActivity(dailyActivity) ?? Future<void>.value());
  }

  /// Backfills the full day total for a PAST day from the health store, once
  /// per day and session. An EXISTING entry is refreshed too: it may stem
  /// from a refresh before day end, while the history knows the full sum. If
  /// the service returns nothing, the stored value stays untouched.
  Future<void> _maybeBackfillDailyActivity(DateTime day) async {
    if (_disposed || _isSameFoodDate(day, clock.now())) return;
    final key = localDayKey(day);
    if (!_dailyActivityBackfillAttempted.add(key)) return;
    final steps = await health.readStepsOnDay(day);
    if (_disposed || steps == null || steps <= 0) return;
    _mutate(() => _recordDailyActivity(day, steps));
  }

  /// Offers an Apple Health weight for import via snack. Requires a value in
  /// the snapshot, a >= 0.1 kg deviation from the last logged weight (or no
  /// weight at all), and that the same value was not offered before
  /// ([_lastOfferedHealthWeightKg]). After an import the 0.1 kg threshold
  /// suppresses the next offer on its own.
  void _maybeOfferHealthWeight(double? kg) {
    // Outside 20..400 kg the sample is a unit or sensor error; offering it
    // would only lead to a tap that [importHealthWeight] discards.
    if (_disposed || kg == null || !isValidWeightLogKg(kg)) return;
    final lastLogged = weightLog.latest?.weightKg;
    if (lastLogged != null && (kg - lastLogged).abs() < 0.1) return;
    if (_lastOfferedHealthWeightKg == kg) return;
    _lastOfferedHealthWeightKg = kg;
    // Locale-aware via NumberFormat: comma under `de`, dot under `en`.
    final label = NumberFormat('0.0', _l10n.localeName).format(kg);
    _emitSnack(
      _l10n.commonHealthWeightOfferMessage(label),
      icon: Icons.monitor_weight_outlined,
      tone: SnackTone.positive,
      // Unsolicited offer on resume/cold start: longer than kSnackAction so
      // the tap is realistically reachable.
      duration: const Duration(milliseconds: 3500),
      action: SnackBarAction(
        label: _l10n.commonHealthWeightOfferAction,
        onPressed: () => importHealthWeight(kg),
      ),
    );
  }

  // --- Body data (profile) --------------------------------------------------

  /// Manual weigh-in: logs locally, syncs, and writes back to HealthKit.
  void logWeight(double kg) => _logWeightInternal(kg, writeToHealth: true);

  /// Import FROM Apple Health: like [logWeight] but WITHOUT
  /// `health.writeWeight` — writing back would create an echo duplicate.
  ///
  /// Out-of-range samples (20..400 kg) are DISCARDED, not clamped (review G
  /// M-4): a clamped 20 kg from a 7.55 lb/stone sample would be a fiction in
  /// the log. The clamp stays the last barrier for manual input only.
  void importHealthWeight(double kg) {
    if (!isValidWeightLogKg(kg)) return;
    _logWeightInternal(kg, writeToHealth: false);
  }

  /// Shared core of [logWeight] and [importHealthWeight]. The haptic fires in
  /// BOTH paths: the import is user-triggered too (snack action).
  ///
  /// Last barrier before cache, HealthKit and server (F7-02): the sheet
  /// rejects out-of-range input, but a HealthKit import or any other caller
  /// still passes through here, and `weight_log_safe_range_check` would
  /// reject the row with 23514 while the local log already showed it.
  void _logWeightInternal(double rawKg, {required bool writeToHealth}) {
    final kg = WeightLog.sanitizeKg(rawKg);
    if (kg == null) return;
    HapticFeedback.lightImpact();
    final ts = clock.now();
    _mutate(() {
      weightLog = weightLog.add(kg);
      lifetimeStats = lifetimeStats.incrementWeightLogs();
    });
    _cacheWeightLog();
    if (writeToHealth) {
      unawaited(health.writeWeight(kg, ts));
    }
    if (sync == null) return;
    // Client UUID for the server row: live write and a later outbox retry
    // share the id -> upsert, so a retry after an unclear timeout creates no
    // duplicate (DATA-7 idempotency).
    final rowId = uuidV4();
    // No rollback: the weight stays logged and is caught up via the outbox.
    // Gap B: the op is queued BEFORE the write, otherwise a hanging request
    // would never produce one.
    _syncOrQueue(
      'Gewicht',
      () => sync!.tracking.insertWeight(kg, ts, id: rowId),
      () => SyncOp.weightInsert(id: rowId, weightKg: kg, recordedAt: ts),
      // As with the meal insert: otherwise _performOp books the lifetime
      // delta on replay.
      onDelivered: () => _queueStatsDelta(weightLogs: 1),
    );
  }

  // --- Streak ---------------------------------------------------------------

  /// Records a logging day server-side (record_tracking_day, idempotent per
  /// day) and adopts the fresh server row. Defaults to today; an outbox
  /// replay passes the day of the caught-up meal.
  ///
  /// A failure must not stay silent: the debounced [_flushStatsDelta] would
  /// adopt a server row that never saw the day and [_cacheLifetimeStats]
  /// would persist the broken streak. On error the day goes into the same
  /// persisted outbox as any other write ([_queueTrackingDay]).
  @override
  void _recordTrackingDay({DateTime? day}) {
    final s = sync;
    if (s == null) return;
    final tag = day ?? clock.now();
    s.lifetimeStats.recordTrackingDay(tag).then((fresh) {
      if (_disposed) return;
      // An older failed op for the same day is now settled.
      _clearQueuedTrackingDay(localDayKey(tag));
      _mutate(() {
        lifetimeStats = fresh;
        // Other undelivered days stay visible — the server row we just read
        // does not know them.
        _overlayPendingTrackingDays();
      });
      _cacheLifetimeStats();
    }).catchError((Object e, StackTrace st) {
      dev.log('recordTrackingDay failed — Tag bleibt in der Outbox liegen',
          error: e, name: 'home_store');
      // Network failures stay out of Sentry (F1-04); the outbox retries.
      unawaited(CrashReporter.captureSyncFailure(e, st,
          context: 'record-tracking-day'));
      _queueTrackingDay(tag);
    });
  }
}
