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
  bool get _serverMealsLoaded;

  Object? _energyCheckKey;
  EnergyCheckProposal? _energyCheckProposal;

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

  /// Today's weekly-check proposal, or null.
  ///
  /// Only on data the server answered in this session — profile, weight log
  /// and the complete meal window — like the weight-trend re-anchor: a goal
  /// proposal from a stale cache would be advice built on missing days.
  EnergyCheckProposal? get energyCheckProposal {
    if (sync != null &&
        !(_hydratedFromRealSource &&
            _serverAnsweredProfileAndWeightLog &&
            _serverMealsLoaded &&
            !_bootMealsAtCapacity &&
            energyCheckStepsReady)) {
      return null;
    }
    final today = startOfDay(clock.now());
    // Identity of the inputs: the store replaces these on every change.
    final key = (profile, loggedMeals, weightLog, dailyActivity, today);
    if (key == _energyCheckKey) return _energyCheckProposal;
    _energyCheckKey = key;
    return _energyCheckProposal = const EnergyCheck().evaluate(
      profile: profile,
      today: today,
      intakeKcal: consumedKcalForFoodDate,
      // Only what this device holds: step values are not synced, and a day
      // without one must not count as zero steps.
      burnedKcal: (day) => dailyActivity[localDayKey(day)]?.kcal,
      stepSourceToday: stepsForFoodDate(clock.now()) != null,
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
    final today = startOfDay(clock.now());
    for (var n = 1; n <= EnergyCheck.windowDays; n++) {
      if (_disposed) return;
      await _maybeBackfillDailyActivity(addDays(today, -n));
    }
    // After a rollover meanwhile, the new day's own refresh marks its window.
    if (_disposed ||
        daysBetween(clock.now(), today) != 0 ||
        energyCheckStepsReady) {
      return;
    }
    _mutate(() => _energyCheckStepsDay = today);
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
