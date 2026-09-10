part of 'home_store.dart';

mixin _HomeStoreMealPlanPart
    on _HomeStoreBase, _HomeStoreSyncPart, _HomeStoreProfilePart {
  Future<void> _mealPlanTail = Future<void>.value();

  Future<T> _serializeMealPlan<T>(Future<T> Function() action) {
    final result = _mealPlanTail.then((_) => action());
    _mealPlanTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  void _ensureMealPlanActive() {
    if (_disposed || _trainingSessionEnded || (_cache?.isClosed ?? false)) {
      throw StateError('Account session ended');
    }
  }

  Future<SyncDelivery> savePlannedMeal(PlannedMeal plan) => _serializeMealPlan(
    () async {
      _ensureMealPlanActive();
      final validated = PlannedMeal.fromJson(plan.toJson());
      final existing = _plannedMeals.where((p) => p.id == plan.id).firstOrNull;
      if (validated.isEaten || existing?.isEaten == true) {
        throw StateError('Meal already eaten');
      }
      final activeSince = localDayKey(
        clock.now().subtract(const Duration(days: 35)),
      );
      if (existing == null &&
          _plannedMeals
                  .where(
                    (p) =>
                        !p.removed &&
                        !p.isEaten &&
                        p.day.compareTo(activeSince) >= 0,
                  )
                  .length >=
              500) {
        throw StateError('Meal plan limit reached');
      }
      final delivery = await _confirmMutation(
        'meal-plan',
        SyncOp.mealPlanUpsert(validated),
        () => sync!.mealPlans.save(validated),
      );
      _ensureMealPlanActive();
      _mutate(() => _putPlannedMeal(validated));
      _cacheMealPlans();
      return delivery;
    },
  );

  Future<SyncDelivery> removePlannedMeal(PlannedMeal plan) =>
      savePlannedMeal(plan.copyWith(removed: true));

  Future<SyncDelivery> setShoppingChecked(ShoppingCheck check) =>
      _serializeMealPlan(() async {
        _ensureMealPlanActive();
        final validated = ShoppingCheck.fromJson(check.toJson());
        final delivery = await _confirmMutation(
          'shopping-check',
          SyncOp.shoppingCheck(validated),
          () => sync!.mealPlans.check(validated),
        );
        _ensureMealPlanActive();
        _mutate(() {
          _shoppingChecks = {
            ..._shoppingChecks,
            validated.id: validated.checked,
          };
          _mealPlansVersion++;
        });
        _cacheMealPlans();
        return delivery;
      });

  /// One outbox intent owns the recipe snapshot, conversion receipt, diary row
  /// and server counters. Subsequent diary changes follow this UUID in FIFO.
  Future<SyncDelivery> eatPlannedMeal(
    String id,
  ) => _serializeMealPlan(() async {
    _ensureMealPlanActive();
    final plan = _plannedMeals.where((p) => p.id == id).firstOrNull;
    if (plan == null || plan.removed) {
      throw StateError('Meal no longer planned');
    }
    if (plan.isEaten) return SyncDelivery.delivered;
    final now = clock.now();
    final converted = plan.copyWith(eatenAt: now);
    final meal = LoggedMeal(
      id: plan.id,
      result: plan.recipe.toMealResultForServings(plan.servings, _l10n),
      loggedAt: now,
      localDay: localDayKey(now),
      forcedSlot: plan.slot,
    );
    final op = SyncOp.mealPlanConvert(converted, meal, trackDay: true);
    MealPlanConversion? receipt;
    final delivery = await _confirmMutation('meal-plan-eaten', op, () async {
      receipt = await sync!.mealPlans.convert(converted, meal, trackDay: true);
      _reconcileMealPlanConversion(receipt!, op);
    });
    _ensureMealPlanActive();
    _mutate(() {
      if (receipt == null) _putPlannedMeal(converted);
      if (receipt == null && !loggedMeals.any((m) => m.id == meal.id)) {
        loggedMeals = [meal, ...loggedMeals];
        lifetimeStats = lifetimeStats.incrementMeals().recordTrackedDay(now);
      }
      dailyConsumedKcal = consumedKcalForFoodDate(now);
      macroProgress = macroProgressForFoodDate(now);
      _invalidateTrendWindow();
    });
    _cacheMealPlans();
    _cacheLoggedMeals();
    _cacheLifetimeStats();
    unawaited(_rescheduleStreakReminder());
    return delivery;
  });

  Future<void> retryMealPlans() async {
    _ensureMealPlanActive();
    await _replayOutbox();
    await _loadMealPlans();
  }

  Future<void> _loadMealPlans() async {
    final s = sync;
    if (s == null || _disposed || _trainingSessionEnded) return;
    final baselinePlans = _plannedMeals;
    final baselineChecks = _shoppingChecks;
    final version = _mealPlansVersion;
    _mutate(() => mealPlansLoading = true);
    try {
      final data = await s.mealPlans.load();
      _ensureMealPlanActive();
      _mutate(() {
        if (version == _mealPlansVersion) {
          _plannedMeals = List.unmodifiable(data.plans);
          _shoppingChecks = {
            for (final check in data.checks) check.id: check.checked,
          };
          _mealPlansVersion++;
        } else {
          _plannedMeals = HomeStore._mergeRacedLoad(
            local: _plannedMeals,
            server: data.plans,
            baseline: baselinePlans,
            keyOf: (p) => p.id,
          );
          _shoppingChecks = {
            for (final check in data.checks)
              check.id: baselineChecks[check.id] != _shoppingChecks[check.id]
                  ? _shoppingChecks[check.id] ?? check.checked
                  : check.checked,
            for (final entry in _shoppingChecks.entries)
              if (!data.checks.any((c) => c.id == entry.key))
                entry.key: entry.value,
          };
          _mealPlansVersion++;
        }
        _applyPendingOpsToState();
        mealPlansLoadFailed = false;
      });
      _cacheMealPlans();
    } catch (_) {
      if (!_disposed && !_trainingSessionEnded) {
        _mutate(() => mealPlansLoadFailed = true);
      }
    } finally {
      if (!_disposed && !_trainingSessionEnded) {
        _mutate(() => mealPlansLoading = false);
      }
    }
  }
}
