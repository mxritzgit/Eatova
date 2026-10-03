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
            !_bootMealsAtCapacity)) {
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
      burnedKcal: burnedKcalForFoodDate,
      weightLog: weightLog,
    );
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
    await _commitSyncIntents(
      [SyncOp.profileUpsert(next)],
      publish: () => profile = next,
    );
    if (stepKcal != 0 &&
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
