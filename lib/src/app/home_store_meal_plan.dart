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

  /// Open plans the limit counts: not removed, not eaten, in the 35-day window.
  int _openPlannedMealCount() {
    final activeSince = localDayKey(
      clock.now().subtract(const Duration(days: 35)),
    );
    return _plannedMeals
        .where(
          (p) => !p.removed && !p.isEaten && p.day.compareTo(activeSince) >= 0,
        )
        .length;
  }

  Future<SyncDelivery> savePlannedMeal(PlannedMeal plan) =>
      savePlannedMeals([plan]);

  /// Saves [plans] in one local commit, all or none, e.g. one recipe cooked
  /// ahead for several days. The open-plan limit counts every new plan.
  Future<SyncDelivery> savePlannedMeals(
    List<PlannedMeal> plans,
  ) => _serializeMealPlan(() async {
    _ensureMealPlanActive();
    final validated = [
      for (final plan in plans) PlannedMeal.fromJson(plan.toJson()),
    ];
    if (validated.isEmpty ||
        {for (final plan in validated) plan.id}.length != validated.length) {
      throw ArgumentError.value(plans, 'plans', 'Empty or repeated ids');
    }
    var added = 0;
    for (final plan in validated) {
      final existing = _plannedMeals.where((p) => p.id == plan.id).firstOrNull;
      if (plan.isEaten || existing?.isEaten == true) {
        throw const MealPlanAlreadyEaten();
      }
      if (existing == null) added++;
    }
    if (added > 0 && _openPlannedMealCount() + added > kMaxOpenPlannedMeals) {
      throw const MealPlanLimitReached();
    }
    return _commitSyncIntents(
      [for (final plan in validated) SyncOp.mealPlanUpsert(plan)],
      notifyQueued: false,
      publish: () => validated.forEach(_putPlannedMeal),
    );
  });

  Future<SyncDelivery> removePlannedMeal(PlannedMeal plan) =>
      savePlannedMeal(plan.copyWith(removed: true));

  /// Adds [plans] as new entries in one local commit, all or none: the week
  /// suggestion's "Übernehmen". A plan for a day and slot that holds an
  /// entry by now (another device, an edit meanwhile) is left out, so
  /// nothing planned is overwritten or doubled. Resolves to the delivery and
  /// the number of entries written.
  Future<({SyncDelivery delivery, int added})> addPlannedMeals(
    List<PlannedMeal> plans,
  ) => _serializeMealPlan(() async {
    _ensureMealPlanActive();
    final taken = {
      for (final p in _plannedMeals)
        if (!p.removed) (p.day, p.slot),
    };
    final fresh = <PlannedMeal>[];
    for (final plan in plans) {
      final validated = PlannedMeal.fromJson(plan.toJson());
      if (validated.isEaten ||
          validated.removed ||
          _plannedMeals.any((p) => p.id == validated.id)) {
        throw ArgumentError.value(plan.id, 'plans', 'Not a new plan');
      }
      if (taken.add((validated.day, validated.slot))) fresh.add(validated);
    }
    if (fresh.isEmpty) return (delivery: SyncDelivery.delivered, added: 0);
    if (_openPlannedMealCount() + fresh.length > kMaxOpenPlannedMeals) {
      throw const MealPlanLimitReached();
    }
    final delivery = await _commitSyncIntents(
      [for (final plan in fresh) SyncOp.mealPlanUpsert(plan)],
      notifyQueued: false,
      publish: () => fresh.forEach(_putPlannedMeal),
    );
    return (delivery: delivery, added: fresh.length);
  });

  /// A tick reads no plan state, so it skips the plan queue, and it returns
  /// once committed: the receipt shows no delivery feedback, and waiting for
  /// one tick's delivery would hold back the next one.
  Future<SyncDelivery> setShoppingChecked(ShoppingCheck check) async {
    _ensureMealPlanActive();
    final validated = ShoppingCheck.fromJson(check.toJson());
    return _commitSyncIntents(
      [SyncOp.shoppingCheck(validated)],
      notifyQueued: false,
      awaitDelivery: false,
      publish: () {
        _shoppingChecks = {..._shoppingChecks, validated.id: validated.checked};
        _mealPlansVersion++;
      },
    );
  }

  /// One outbox intent owns the recipe snapshot, conversion receipt, diary row
  /// and server counters. Subsequent diary changes follow this UUID in FIFO.
  ///
  /// [day]: the diary day for a plan of a past day; null or today logs now.
  /// A past day keeps the current time of day, like any back-dated entry,
  /// and tracks that day only where it continues the streak
  /// ([LifetimeStats.backfillContinuesStreak]). [PlannedMeal.eatenAt] is the
  /// diary time, so the plan names the day the entry is on.
  Future<SyncDelivery> eatPlannedMeal(String id, {DateTime? day}) =>
      _serializeMealPlan(() async {
        _ensureMealPlanActive();
        final plan = _plannedMeals.where((p) => p.id == id).firstOrNull;
        if (plan == null || plan.removed) {
          throw StateError('Meal no longer planned');
        }
        if (plan.isEaten) return SyncDelivery.delivered;
        final now = clock.now();
        if (day != null && DateUtils.dateOnly(day).isAfter(now)) {
          throw ArgumentError.value(day, 'day', 'A future diary day');
        }
        final pastDay = day == null || _isSameFoodDate(day, now) ? null : day;
        final loggedAt = pastDay == null ? now : _timestampForFoodDate(pastDay);
        final trackDay =
            pastDay == null ||
            lifetimeStats.backfillContinuesStreak(loggedAt, now: now);
        final converted = plan.copyWith(eatenAt: loggedAt);
        final meal = LoggedMeal(
          id: plan.id,
          result: plan.recipe.toMealResultForServings(plan.servings, _l10n),
          loggedAt: loggedAt,
          localDay: localDayKey(loggedAt),
          forcedSlot: plan.slot,
        );
        final op = SyncOp.mealPlanConvert(converted, meal, trackDay: trackDay);
        final delivery = await _commitSyncIntents(
          [op],
          notifyQueued: false,
          publish: () {
            _putPlannedMeal(converted);
            if (!loggedMeals.any((m) => m.id == meal.id)) {
              loggedMeals = [meal, ...loggedMeals];
              lifetimeStats = lifetimeStats.incrementMeals();
              if (trackDay) {
                lifetimeStats = lifetimeStats.recordTrackedDay(loggedAt);
              }
            }
            dailyConsumedKcal = consumedKcalForFoodDate(now);
            macroProgress = macroProgressForFoodDate(now);
            _invalidateTrendWindow();
          },
        );
        if (trackDay) unawaited(_rescheduleStreakReminder());
        return delivery;
      });

  Future<void> retryMealPlans() async {
    _ensureMealPlanActive();
    await _replayOutbox();
    await _loadMealPlans();
  }

  Future<void> _loadMealPlans({bool allowConflictRetry = true}) async {
    final s = sync;
    if (s == null || _disposed || _trainingSessionEnded) return;
    final baselinePlans = _plannedMeals;
    final baselineChecks = _shoppingChecks;
    final version = _mealPlansVersion;
    final cacheVersionsBeforeLoad = Map<String, int>.of(_cacheObservedVersions);
    var conflict = false;
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
      conflict = await _cacheMealPlans(cacheVersionsBeforeLoad);
    } catch (_) {
      if (!_disposed && !_trainingSessionEnded) {
        _mutate(() => mealPlansLoadFailed = true);
      }
    } finally {
      if (!_disposed && !_trainingSessionEnded) {
        _mutate(() => mealPlansLoading = false);
      }
    }
    if (conflict && allowConflictRetry && !_disposed && !_trainingSessionEnded) {
      await _loadMealPlans(allowConflictRetry: false);
    }
  }
}
