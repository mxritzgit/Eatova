part of 'home_store.dart';

/// Weekly energy check of [HomeStore] (docs/WEIGHT-TREND.md, stage 2): the
/// proposal for today and its two answers. The estimate itself is the pure
/// [EnergyCheck]; nothing here changes a goal without the user's tap.
mixin _HomeStoreEnergyCheckPart
    on
        _HomeStoreBase,
        _HomeStoreSyncPart,
        _HomeStoreTrackingPart,
        _HomeStoreProfilePart,
        _HomeStoreMealsPart {
  /// The server answered the meal load in this session; set by the boot in
  /// [HomeStore], cleared by a re-hydration that brings back other meals.
  @override
  bool get _serverMealsLoaded;

  Object? _energyCheckKey;
  EnergyCheckEstimate? _energyCheckEstimate;
  EnergyCheckProgress? _energyCheckProgress;

  /// The local day whose window [_backfillEnergyCheckWindow] last refreshed.
  DateTime? _energyCheckStepsDay;

  /// The boot asked for a window refresh, so a new day asks again.
  bool _energyCheckWindowRequested = false;

  /// The window's step values were refreshed from the health store in this
  /// session for TODAY's window ([_backfillEnergyCheckWindow]); the Today
  /// shell selects it, so the card appears once and with final numbers. A
  /// new day ends a window day that holds only its last in-day snapshot.
  bool get energyCheckStepsReady {
    final day = _energyCheckStepsDay;
    return day != null && daysBetween(clock.now(), day) == 0;
  }

  /// The check's sources are complete: data the server answered in this
  /// session — profile, weight log and the complete meal window — like the
  /// weight-trend re-anchor, plus the refreshed step window. A proposal from
  /// a stale cache would be advice built on missing days.
  ///
  /// Public for the Today slice: card and progress line follow the gate
  /// itself instead of relying on an input that changes in the same notify.
  bool get energyCheckSourcesReady =>
      sync == null ||
      (_hydratedFromRealSource &&
          _serverAnsweredProfileAndWeightLog &&
          _serverMealsLoaded &&
          !_bootMealsAtCapacity &&
          energyCheckStepsReady);

  /// Today's weekly-check proposal, or null; only on complete sources
  /// ([energyCheckSourcesReady]).
  EnergyCheckProposal? get energyCheckProposal {
    _refreshEnergyCheck();
    return energyCheckSourcesReady ? _energyCheckEstimate?.proposal : null;
  }

  /// The week's result for Today's quiet card (2026-10-19): the check's
  /// estimate on [EnergyCheck.resultWeekday] when it proposes nothing, on
  /// the same sources and gates as [energyCheckProposal]; else null.
  EnergyCheckEstimate? get energyCheckResult {
    _refreshEnergyCheck();
    final estimate = _energyCheckEstimate;
    if (!energyCheckSourcesReady ||
        estimate == null ||
        estimate.proposal != null ||
        clock.now().weekday != EnergyCheck.resultWeekday) {
      return null;
    }
    return estimate;
  }

  /// How far the weekly check is from an estimate, on the same sources and
  /// inputs as [energyCheckProposal]; null while those are incomplete or
  /// when the check does not apply (manual goal, unfinished onboarding).
  EnergyCheckProgress? get energyCheckProgress {
    _refreshEnergyCheck();
    return energyCheckSourcesReady ? _energyCheckProgress : null;
  }

  /// The check's state for the Coach context (2026-10-22), on the same
  /// sources and gates as the cards; null where it does not apply.
  @override
  String? _energyCheckContext() {
    if (!profile.onboardingCompleted) return null;
    if (profile.manualEnergy) return coachEnergyCheckLine(manualGoal: true);
    _refreshEnergyCheck();
    if (!energyCheckSourcesReady) return null;
    return coachEnergyCheckLine(
      progress: _energyCheckProgress,
      estimate: _energyCheckEstimate,
    );
  }

  /// Recomputes proposal and progress when an input changed.
  void _refreshEnergyCheck() {
    if (!energyCheckSourcesReady) return;
    final today = startOfDay(clock.now());
    // A reading today can arrive without changing the day's pinned value.
    final stepSourceToday = stepsForFoodDate(clock.now()) != null;
    // Identity of the inputs: the store replaces these on every change.
    final key = (
      profile,
      loggedMeals,
      weightLog,
      dailyActivity,
      today,
      stepSourceToday,
    );
    if (key == _energyCheckKey) return;
    _energyCheckKey = key;
    // Only what this device holds: step values are not synced, and a day
    // without one must not count as zero steps.
    int? burnedKcal(DateTime day) => dailyActivity[localDayKey(day)]?.kcal;
    const check = EnergyCheck();
    _energyCheckEstimate = check.estimate(
      profile: profile,
      today: today,
      intakeKcal: consumedKcalForFoodDate,
      burnedKcal: burnedKcal,
      stepSourceToday: stepSourceToday,
      weightLog: weightLog,
    );
    _energyCheckProgress = check.progress(
      profile: profile,
      today: today,
      intakeKcal: consumedKcalForFoodDate,
      burnedKcal: burnedKcal,
      stepSourceToday: stepSourceToday,
      weightLog: weightLog,
    );
  }

  /// Refreshes the window's step values with full-day totals from the
  /// health store, once per day and session ([_maybeBackfillDailyActivity]):
  /// a value pinned before its day ended would understate the modelled
  /// expenditure and push the goal up. Without a health source the reads
  /// return nothing and change nothing.
  Future<void> _backfillEnergyCheckWindow() async {
    _energyCheckWindowRequested = true;
    _energyCheckWindowRuns++;
    try {
      final today = startOfDay(clock.now());
      var complete = true;
      for (var n = 1; n <= EnergyCheck.windowDays; n++) {
        if (_disposed) return;
        if (!await _maybeBackfillDailyActivity(addDays(today, -n))) {
          complete = false;
        }
      }
      // A deferred day still holds its in-day snapshot: the next foreground
      // refresh reads it ([_retryDeferredDailyActivity]). After a rollover
      // meanwhile, the new day's own refresh marks its window.
      if (_disposed ||
          !complete ||
          daysBetween(clock.now(), today) != 0 ||
          energyCheckStepsReady) {
        return;
      }
      _mutate(() => _energyCheckStepsDay = today);
    } finally {
      _energyCheckWindowRuns--;
    }
  }

  /// Window runs in flight; a retry waits for them instead of racing them.
  int _energyCheckWindowRuns = 0;

  /// After a health refresh (resume, new day, pull): repeats the window run
  /// if the last one deferred a day. Only already-read days are skipped, so
  /// this costs nothing once the window is ready, and it never loops by
  /// itself.
  @override
  void _retryDeferredDailyActivity() {
    if (_disposed ||
        !_energyCheckWindowRequested ||
        _energyCheckWindowRuns > 0 ||
        energyCheckStepsReady) {
      return;
    }
    unawaited(_backfillEnergyCheckWindow());
  }

  /// Day rollover: refreshes the new window once the boot has asked, so the
  /// day that just ended counts with its full-day total. Days refreshed
  /// before are not read again ([_maybeBackfillDailyActivity]).
  void _refreshEnergyCheckWindowForNewDay() {
    if (_disposed || !_energyCheckWindowRequested) return;
    unawaited(_backfillEnergyCheckWindow());
  }

  /// Applies [proposal]: its step on the maintenance offset, today as the
  /// answered day, live goals recomputed — and names the new goal.
  Future<void> acceptEnergyCheck(EnergyCheckProposal proposal) =>
      _answerEnergyCheck(stepKcal: proposal.stepKcal);

  /// "Not now": records today, so the next check waits seven days.
  Future<void> dismissEnergyCheck() => _answerEnergyCheck(stepKcal: 0);

  Future<void> _answerEnergyCheck({required int stepKcal}) async {
    // Derived from the published profile, so a goals save in flight lands
    // first (as for the weight re-anchor).
    await _settledLocalMutations();
    final before = profile;
    // The step is relative: another device may have moved the offset since
    // the card was built; the user agreed to the step, not to an absolute.
    final adjustment = (before.energyAdjustmentKcal + stepKcal).clamp(
      -EnergyCheck.maxAdjustmentKcal,
      EnergyCheck.maxAdjustmentKcal,
    );
    final next = const KcalCalculator().applyLiveGoals(
      before.copyWith(
        energyAdjustmentKcal: adjustment,
        energyCheckedOn: startOfDay(clock.now()),
      ),
    );
    final syncHintShown = _syncHintShown;
    await _commitSyncIntents(
      [SyncOp.profileUpsert(next)],
      publish: () => profile = next,
    );
    // The once-per-session "saved here, syncs later" hint this commit may
    // just have raised outranks the confirmation (as for the re-anchor).
    final raisedSyncHint = _syncHintShown && !syncHintShown;
    if (stepKcal != 0 &&
        !raisedSyncHint &&
        !next.manualEnergy &&
        next.dailyKcalGoal != before.dailyKcalGoal &&
        !_disposed) {
      _emitSnack(
        _l10n.commonEnergyCheckApplied(next.dailyKcalGoal),
        icon: Icons.tune_rounded,
      );
    }
  }
}
