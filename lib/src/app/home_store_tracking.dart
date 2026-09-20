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
  bool _healthConnectedByUser = false;

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
  bool _healthWeightImportInFlight = false;

  // --- Health ---------------------------------------------------------------

  /// Called once the account's encrypted cache has been resolved at boot.
  Future<void> restoreHealthConnection() async {
    final service = health;
    if (_disposed || _healthSessionEnded || service is! HealthConnectAccess) {
      return;
    }
    final generation = _healthGeneration;
    final cache = _cache ?? debugCache;
    if (cache != null) {
      if (_healthConnectedByUser) {
        await cache.writeHealthConnectEnabled(true);
      } else {
        final enabled = await cache.readHealthConnectEnabled();
        if (_disposed || generation != _healthGeneration) return;
        if (enabled) {
          (service as HealthConnectAccess).restoreConnection();
          _healthConnectedByUser = true;
        }
      }
    }
    if (_disposed || generation != _healthGeneration) return;
    await refreshHealthSteps();
  }

  Future<void> connectHealth() async {
    if (_disposed || _healthSessionEnded || healthSyncing) return;
    final generation = _healthGeneration;
    _mutate(() => healthSyncing = true);
    final state = await health.requestAuthorization();
    if (_disposed || generation != _healthGeneration) return;
    _mutate(() => healthAuthState = state);
    if (state == HealthAuthState.granted) {
      if (health is HealthConnectAccess) {
        _healthConnectedByUser = true;
        await (_cache ?? debugCache)?.writeHealthConnectEnabled(true);
        if (_disposed || generation != _healthGeneration) return;
      }
      _dailyActivityBackfillAttempted.clear();
      healthSyncing = false;
      await refreshHealthSteps();
    } else {
      _mutate(() {
        healthSyncing = false;
        if (health is HealthConnectAccess) {
          dailySteps = 0;
          healthLastFetch = null;
        }
      });
    }
  }

  Future<void> refreshHealthSteps() =>
      _refreshHealthSteps(allowDayCatchUp: true);

  Future<void> _refreshHealthSteps({required bool allowDayCatchUp}) async {
    if (_disposed || _healthSessionEnded || healthSyncing) return;
    final generation = _healthGeneration;
    final requestedDay = DateUtils.dateOnly(clock.now().toLocal());
    _mutate(() => healthSyncing = true);
    if (_disposed || generation != _healthGeneration) return;
    final snapshot = await health.readSnapshot();
    if (_disposed || generation != _healthGeneration) return;
    _mutate(() {
      healthSyncing = false;
      // B3: the service re-verifies the permission on every refresh and can
      // fall back from granted to unverified/denied, so adopt its state in
      // BOTH branches instead of only upgrading on success.
      healthAuthState = health.authState;
      if (snapshot != null) {
        final fetchedAt = snapshot.fetchedAt.toLocal();
        dailySteps = snapshot.stepsToday;
        healthLastFetch = fetchedAt;
        // Pin to the SNAPSHOT's day, not "today": a refresh at the midnight
        // second still belongs to the query time.
        _recordDailyActivity(fetchedAt, snapshot.stepsToday);
      } else if (health is HealthConnectAccess) {
        dailySteps = 0;
        healthLastFetch = null;
      }
      // iOS retains its last measured value when read access is unverified.
    });
    if (_disposed || generation != _healthGeneration) return;
    // Offer the snapshot weight for import (deduped) instead of discarding it.
    if (snapshot != null) {
      _maybeOfferHealthWeight(snapshot.latestWeightKg);
    }
    // A midnight refresh may have hit the in-flight guard. Catch up once;
    // a failed or repeatedly delayed provider must not create a retry loop.
    final today = clock.now().toLocal();
    if (allowDayCatchUp &&
        !_isSameFoodDate(requestedDay, today) &&
        stepsForFoodDate(today) == null) {
      await _refreshHealthSteps(allowDayCatchUp: false);
    }
  }

  Future<void> openHealthSettings() async {
    final service = health;
    if (_disposed ||
        _healthSessionEnded ||
        healthSyncing ||
        service is! HealthConnectAccess) {
      return;
    }
    final generation = _healthGeneration;
    _mutate(() => healthSyncing = true);
    await (service as HealthConnectAccess).openSettings();
    if (_disposed || generation != _healthGeneration) return;
    _mutate(() {
      healthSyncing = false;
      healthAuthState = health.authState;
    });
  }

  /// Burned kcal for [date]: live from [dailySteps] today, the pinned value
  /// from [dailyActivity] for past days. 0 means "no entry".
  ///
  /// Every step counts (kcal review 2026-08-21): the daily goal uses a PAL
  /// ladder WITHOUT walking (`ActivityLevel.palFactor`), so the full step sum
  /// is not double counting.
  @override
  int burnedKcalForFoodDate(DateTime date) {
    final localDate = date.toLocal();
    if (_isSameFoodDate(localDate, clock.now().toLocal())) {
      final steps = stepsForFoodDate(localDate);
      if (steps == null) return 0;
      return estimateKcalBurnedFromSteps(
        steps: steps,
        weightKg: profile.weightKg,
        heightCm: profile.heightCm,
        sex: profile.sex,
      );
    }
    return dailyActivity[localDayKey(localDate)]?.kcal ?? 0;
  }

  /// Step count for [date] — live today, pinned for past days. `null` means
  /// "no step source", which hides the steps card instead of claiming 0.
  ///
  /// Only a snapshot from this local day proves today's value. Permission
  /// alone cannot distinguish an unavailable reading from a measured zero.
  int? stepsForFoodDate(DateTime date) {
    final localDate = date.toLocal();
    if (_isSameFoodDate(localDate, clock.now().toLocal())) {
      if (_healthSessionEnded ||
          (health is HealthConnectAccess &&
              healthAuthState != HealthAuthState.granted)) {
        return null;
      }
      final fetched = healthLastFetch?.toLocal();
      return fetched != null && _isSameFoodDate(fetched, localDate)
          ? dailySteps
          : null;
    }
    return dailyActivity[localDayKey(localDate)]?.steps;
  }

  /// Upserts the calendar day of [day] with [steps]; kcal are frozen using
  /// the CURRENT profile (the estimate is coarser than the weight drift).
  /// Must run inside a _mutate block; the cache write is fire-and-forget.
  void _recordDailyActivity(DateTime day, int steps) {
    if (steps < 0) return;
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
    unawaited(
      _cache?.writeDailyActivity(dailyActivity) ?? Future<void>.value(),
    );
  }

  /// Backfills the full day total for a PAST day from the health store, once
  /// per day and session. An EXISTING entry is refreshed too: it may stem
  /// from a refresh before day end, while the history knows the full sum. If
  /// the service returns nothing, the stored value stays untouched.
  Future<void> _maybeBackfillDailyActivity(DateTime day) async {
    if (_disposed || _healthSessionEnded || _isSameFoodDate(day, clock.now())) {
      return;
    }
    final generation = _healthGeneration;
    final key = localDayKey(day);
    if (!_dailyActivityBackfillAttempted.add(key)) return;
    final steps = await health.readStepsOnDay(day);
    if (_disposed ||
        generation != _healthGeneration ||
        steps == null ||
        steps < 0) {
      return;
    }
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
    if (_disposed ||
        _healthSessionEnded ||
        _healthWeightImportInFlight ||
        kg == null ||
        !isValidWeightLogKg(kg)) {
      return;
    }
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
        onPressed: () => unawaited(_importOfferedHealthWeight(kg)),
      ),
    );
  }

  /// Snack actions have no awaiting caller. Keep their failure handling and
  /// duplicate-tap guard at the user-action boundary, not in the save API.
  Future<void> _importOfferedHealthWeight(double kg) async {
    if (_disposed || _healthSessionEnded || _healthWeightImportInFlight) return;
    final lastLogged = weightLog.latest?.weightKg;
    if (lastLogged != null && (kg - lastLogged).abs() < 0.1) return;
    final generation = _healthGeneration;
    _healthWeightImportInFlight = true;
    try {
      await importHealthWeight(kg);
    } catch (error, stack) {
      if (_disposed || generation != _healthGeneration) return;
      // A failed commit must not permanently consume the offer for this value.
      if (_lastOfferedHealthWeightKg == kg) _lastOfferedHealthWeightKg = null;
      _reportSyncError(
        'health-weight-import',
        error,
        stack,
        message: _l10n.commonLocalSaveFailed,
      );
    } finally {
      _healthWeightImportInFlight = false;
    }
  }

  // --- Body data (profile) --------------------------------------------------

  /// Manual weigh-in: logs locally, syncs, and writes back to HealthKit.
  Future<void> logWeight(double kg) =>
      _logWeightInternal(kg, writeToHealth: true);

  /// Import FROM Apple Health: like [logWeight] but WITHOUT
  /// `health.writeWeight` — writing back would create an echo duplicate.
  ///
  /// Out-of-range samples (20..400 kg) are DISCARDED, not clamped (review G
  /// M-4): a clamped 20 kg from a 7.55 lb/stone sample would be a fiction in
  /// the log. The clamp stays the last barrier for manual input only.
  Future<void> importHealthWeight(double kg) async {
    if (!isValidWeightLogKg(kg)) return;
    await _logWeightInternal(kg, writeToHealth: false);
  }

  /// Shared core of [logWeight] and [importHealthWeight]. The haptic fires in
  /// BOTH paths: the import is user-triggered too (snack action).
  ///
  /// Last barrier before cache, HealthKit and server (F7-02): the sheet
  /// rejects out-of-range input, but a HealthKit import or any other caller
  /// still passes through here, and `weight_log_safe_range_check` would
  /// reject the row with 23514 while the local log already showed it.
  Future<void> _logWeightInternal(
    double rawKg, {
    required bool writeToHealth,
  }) async {
    final kg = WeightLog.sanitizeKg(rawKg);
    if (kg == null) throw const FormatException('Invalid weight');
    final ts = clock.now();
    final op = SyncOp.weightInsert(id: uuidV4(), weightKg: kg, recordedAt: ts);
    await _commitSyncIntents(
      [op],
      publish: () {
        weightLog = WeightLog(
          entries: [
            ...weightLog.entries,
            WeightLogEntry(timestamp: ts, weightKg: kg),
          ],
        );
        lifetimeStats = lifetimeStats.incrementWeightLogs();
      },
    );
    HapticFeedback.lightImpact();
    if (writeToHealth) unawaited(health.writeWeight(kg, ts));
  }
}
