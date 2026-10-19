part of 'home_store.dart';

/// Meals part of [HomeStore]: log/edit/delete with undo, favorites/recents,
/// own recipes, and on-demand loading of days not fully covered by boot.
mixin _HomeStoreMealsPart
    on
        _HomeStoreBase,
        _HomeStoreSyncPart,
        _HomeStoreTrackingPart,
        _HomeStoreProfilePart {
  Future<void> _favoriteMutationTail = Future<void>.value();

  /// Whether this session's meal load answered (see [HomeStore]).
  bool get _serverMealsLoaded;

  Future<T> _serializeFavoriteMutation<T>(Future<T> Function() action) {
    final future = _favoriteMutationTail.then((_) => action());
    _favoriteMutationTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return future;
  }

  // --- On-demand loading of days not covered by a complete boot ------------
  // Boot loads at most 1,000 rows of the 35-day window. Picking an older day
  // or a day from a capped window loads exactly that day and merges it into
  // loggedMeals. These reads stay in memory (session-local), never reach the
  // durable LocalCache during the read, and drop out on the next
  // window load — the merge source is always the server state.
  /// Days already loaded on demand (localDayKey), to avoid repeat queries.
  /// Cleared on a window refresh.
  final Set<String> _loadedArchiveDays = <String>{};

  /// Archive days currently in flight (localDayKey) — drives the UI loading
  /// state and dedups parallel triggers.
  final Set<String> _loadingArchiveDays = <String>{};

  /// Archive days whose last load failed (localDayKey): the diary must not
  /// present them as empty. Cleared by a successful load of the day or of
  /// the window; the store itself is per session.
  final Set<String> _failedArchiveDays = <String>{};

  /// The boot hit its row cap, so any in-window day may still be incomplete.
  bool _bootMealsAtCapacity = false;

  /// True while [day] is being loaded on demand; the UI shows a spinner
  /// instead of a wrongly empty day.
  bool isLoadingFoodDay(DateTime day) =>
      _loadingArchiveDays.contains(localDayKey(DateUtils.dateOnly(day)));

  /// True when the last on-demand load of [day] failed, so what the diary
  /// holds for it is not the server state (offline, server error).
  bool foodDayLoadFailed(DateTime day) =>
      _failedArchiveDays.contains(localDayKey(DateUtils.dateOnly(day)));

  /// The diary's retry for a day whose load failed.
  Future<void> retryFoodDayLoad(DateTime day) => _ensureArchiveDayLoaded(day);

  /// Is [day] outside the boot window of [MealsSync.loadLoggedMeals]?
  ///
  /// The cutoff is a timestamp (now − 35 days), so the boundary day is only
  /// PARTIALLY loaded and counts as outside; it is reloaded in full (the merge
  /// dedups by id).
  ///
  /// B5: counted in CALENDAR days ([daysBetween]). `.difference().inDays` is
  /// wall-clock time and loses an hour across a spring DST switch, making the
  /// boundary day count as 34 and stay permanently empty.
  bool _isOutsideBootWindow(DateTime day) =>
      daysBetween(clock.now(), day) >= MealsSync.loggedMealsWindowDays;

  bool _needsFoodDayLoad(DateTime day) =>
      _bootMealsAtCapacity || _isOutsideBootWindow(day);

  /// Loads a selected day on demand and merges it into [loggedMeals]. Once per
  /// day per session (_loadedArchiveDays); errors show the classified message,
  /// mark the day failed (_failedArchiveDays) and leave it retryable.
  Future<void> _ensureArchiveDayLoaded(DateTime day) async {
    final s = sync;
    if (s == null) return;
    final target = DateUtils.dateOnly(day);
    final key = localDayKey(target);
    if (_loadedArchiveDays.contains(key) || _loadingArchiveDays.contains(key)) {
      return;
    }
    _loadingArchiveDays.add(key);
    if (!_disposed) notifyListeners(); // spinner on
    try {
      final rows = await s.meals.loadLoggedMealsForDay(target);
      if (_disposed) return;
      _loadedArchiveDays.add(key);
      _failedArchiveDays.remove(key);
      _mutate(() => _mergeArchiveMeals(rows));
      // No _cacheLoggedMeals(): archive days stay in memory (see
      // durable writes happen only for confirmed local changes or hydration.
    } catch (e, st) {
      // Read error with no outbox safety net (nothing to replay): classified
      // message via the existing pattern, raw error to dev.log/reporter.
      if (!_disposed) _failedArchiveDays.add(key);
      _reportSyncError('Tag-Nachladen', e, st);
    } finally {
      _loadingArchiveDays.remove(key);
      if (!_disposed) notifyListeners(); // spinner off
    }
  }

  /// Merges freshly loaded server rows of an archive day into [loggedMeals]
  /// without duplicates: only MISSING ids are added, an existing local row
  /// (e.g. with an unsynced edit) wins. Pending outbox ops are re-applied
  /// afterwards so an unreplayed delete cannot revive a loaded row. Must run
  /// inside a _mutate block.
  void _mergeArchiveMeals(List<LoggedMeal> rows) {
    final known = loggedMeals.map((m) => m.id).toSet();
    final missing = rows
        .where((m) => !known.contains(m.id))
        .toList(growable: false);
    if (missing.isNotEmpty) {
      // Restore the server order (logged_at descending) after the merge.
      loggedMeals = [...loggedMeals, ...missing]
        ..sort((a, b) {
          final byTime = b.loggedAt.compareTo(a.loggedAt);
          return byTime != 0 ? byTime : b.id.compareTo(a.id);
        });
    }
    _applyPendingOpsToState();
  }

  // --- Meals ----------------------------------------------------------------

  /// Logs [result] on [foodDate], or on [selectedFoodDate] as read now.
  ///
  /// [startedToday]: the entry was started while [foodDate] was today, in a
  /// sheet bound to that day. Confirmed just after midnight, it still tracks
  /// that day (at most one day late), or the evening's last entry left its
  /// day untracked and reset the streak.
  ///
  /// An entry for yesterday tracks yesterday when that continues the chain
  /// ([LifetimeStats.backfillContinuesStreak], 2026-10-19); other back-dated
  /// entries leave the streak alone.
  Future<String> addResultToDailyTotal(
    MealAnalysisResult result, {
    MealSlot? slot,
    DateTime? foodDate,
    bool startedToday = false,
  }) {
    final targetDate = DateUtils.dateOnly(foodDate ?? selectedFoodDate);
    final loggedAt = _timestampForFoodDate(targetDate);
    final addedAt = clock.now();
    final today =
        _isSameFoodDate(targetDate, addedAt) ||
        (startedToday && daysBetween(addedAt, targetDate) == 1);
    return _serializeFavoriteMutation(() async {
      // Read inside the queue: an add before this one may have moved it.
      final trackDay =
          today ||
          lifetimeStats.backfillContinuesStreak(targetDate, now: addedAt);
      final entry = LoggedMeal(
        id: uuidV4(),
        result: result,
        loggedAt: loggedAt,
        forcedSlot: slot,
        // DATA-6: fixed now, as the outbox persists it. Derived later, a zone
        // change in the running app moved the entry to another day.
        localDay: localDayKey(targetDate),
      );
      // FOOD-6: an entry stored under the other UPC-A spelling is the same
      // product and keeps its key; stored keys are not migrated.
      final old = FavoriteMeal.findFor(favorites, result);
      final recentId = old?.id ?? FavoriteMeal.idFor(result);
      final recent = FavoriteMeal(
        id: recentId,
        result: FavoriteMeal.keepImage(result, old?.result),
        addedAt: addedAt,
        // E5: a product entered for an unknown barcode is remembered, so the
        // next scan finds it; the recents cap would drop it. An unpin by the
        // user stands.
        pinned: old?.pinned ?? result.isOwnProduct,
      );
      final before = [recent, ...favorites.where((f) => f.id != recentId)];
      final after = _cappedFavorites(before);
      final intents = [
        SyncOp.mealInsert(entry, trackDay: trackDay),
        SyncOp.favoriteUpsert(recent),
        for (final dropped in before)
          if (!dropped.pinned && !after.any((f) => f.id == dropped.id))
            SyncOp.favoriteDelete(dropped.id),
      ];
      await _commitSyncIntents(
        intents,
        publish: () {
          lifetimeStats = lifetimeStats.incrementMeals();
          if (trackDay) {
            lifetimeStats = lifetimeStats.recordTrackedDay(targetDate);
          }
          favorites = after;
          loggedMeals = [entry, ...loggedMeals.where((m) => m.id != entry.id)];
          _refreshMealTotals();
        },
      );
      HapticFeedback.lightImpact();
      if (trackDay) unawaited(_rescheduleStreakReminder());
      return entry.id;
    });
  }

  void _refreshMealTotals() {
    _invalidateTrendWindow();
    dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
    macroProgress = macroProgressForFoodDate(clock.now());
  }

  Future<void> updateLoggedMealResult(
    String id,
    MealAnalysisResult scaled,
  ) async {
    final target = loggedMeals.where((meal) => meal.id == id).firstOrNull;
    if (target == null) throw StateError('Meal no longer exists');
    await _applyLoggedMealDetails(target.copyWith(result: scaled));
  }

  /// Edit sheet: changes portion ([result]), slot ([slot]) and/or day ([day])
  /// of a logged meal in ONE outbox-safe update (upsert on the client UUID, no
  /// rollback). Only passed fields change; `null` means unchanged.
  ///
  /// Day move (DATA-6 consistent): [LoggedMeal.loggedAt] keeps its local
  /// wall-clock time on the target day and [LoggedMeal.localDay] gets the new
  /// canonical key, so bucketing, day counters and the server row stay
  /// aligned.
  ///
  /// Streak: a move ONTO today records today as tracked (idempotent per day),
  /// and so does a move onto yesterday that continues the chain
  /// ([LifetimeStats.backfillContinuesStreak]). Other moves to past days are
  /// back-fills and leave the streak alone. A move AWAY from today cannot
  /// un-track it — there is no server-side decrement; accepted.
  ///
  /// Returns the updated meal, or null if [id] no longer exists.
  Future<LoggedMeal?> updateLoggedMealDetails(
    String id, {
    MealAnalysisResult? result,
    MealSlot? slot,
    DateTime? day,
  }) async {
    final index = loggedMeals.indexWhere((m) => m.id == id);
    if (index == -1) return null;
    final previous = loggedMeals[index];

    var updated = previous.copyWith(result: result, forcedSlot: slot);
    var dayChanged = false;
    var tracksTarget = false;
    if (day != null) {
      final targetDay = DateUtils.dateOnly(day);
      final targetKey = localDayKey(targetDay);
      if (targetKey != previous.effectiveLocalDay) {
        // Keep the meal's local wall-clock time, swap only the calendar day,
        // so the slot heuristic (loggedAt.hour) stays stable.
        final local = previous.loggedAt.toLocal();
        updated = updated.copyWith(
          loggedAt: DateTime(
            targetDay.year,
            targetDay.month,
            targetDay.day,
            local.hour,
            local.minute,
          ),
          localDay: targetKey,
        );
        dayChanged = true;
        final now = clock.now();
        tracksTarget =
            _isSameFoodDate(targetDay, now) ||
            lifetimeStats.backfillContinuesStreak(targetDay, now: now);
      }
    }
    if (result == null && slot == null && !dayChanged) return previous;

    HapticFeedback.lightImpact();
    await _applyLoggedMealDetails(updated, recordDay: tracksTarget);
    final message = dayChanged
        ? _l10n.mealMovedTo(_moveDayLabel(updated.loggedAt))
        : _l10n.mealUpdated;
    _emitSnack(
      message,
      icon: Icons.check_circle_rounded,
      tone: SnackTone.positive,
      action: SnackBarAction(
        label: _l10n.commonUndo,
        onPressed: () => _undoMutation(() => _revertLoggedMealUpdate(previous)),
      ),
    );
    return updated;
  }

  /// Undo of the edit sheet: restores the previous meal state via the same
  /// outbox-safe upsert. No-op if the meal was deleted meanwhile. The streak
  /// is NOT rolled back (no server decrement, see updateLoggedMealDetails).
  Future<void> _revertLoggedMealUpdate(LoggedMeal previous) =>
      _applyLoggedMealDetails(previous);

  /// Shared apply core of update + undo: replaces the row, restores the server
  /// order, recomputes TODAY's counters/macros (a move can affect today even
  /// while another day is shown), mirrors into the LocalCache and syncs as an
  /// idempotent upsert. [recordDay] also tracks the meal's new day.
  Future<void> _applyLoggedMealDetails(
    LoggedMeal updated, {
    bool recordDay = false,
  }) async {
    final before = loggedMeals.where((m) => m.id == updated.id).firstOrNull;
    if (before == null) {
      throw StateError('Meal no longer exists');
    }
    final update = SyncOp.mealUpsert(updated);
    await _commitSyncIntents(
      [
        update,
        if (recordDay)
          SyncOp.trackingDay(
            updated.effectiveLocalDay,
          ).withPredecessor(update.operationId),
      ],
      publish: () {
        loggedMeals = [updated, ...loggedMeals.where((m) => m.id != updated.id)]
          ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
        if (recordDay) {
          lifetimeStats = lifetimeStats.recordTrackedDay(
            DateTime.parse(updated.effectiveLocalDay),
          );
        }
        _refreshMealTotals();
      },
    );
    if (recordDay) {
      unawaited(_rescheduleStreakReminder());
    } else {
      // A new portion or a move changes today's total, which the evening
      // reminder's text is planned from.
      _replanIfToday([before, updated]);
    }
    if (!identical(before.result, updated.result)) {
      await _serializeFavoriteMutation(
        () => _takePortionIntoRecent(updated.result),
      );
    }
  }

  /// FOOD-7: a re-portioned meal's auto-recent takes the new portion, the
  /// last one used, as a fresh log would; an undo hands the old one back.
  /// Identity and cap stay: the entry keeps its key, place and date, a
  /// pinned favorite keeps its stored portion (as [toggleFavorite] does),
  /// and a recent that already left the list is not brought back.
  Future<void> _takePortionIntoRecent(MealAnalysisResult result) async {
    final old = FavoriteMeal.findFor(favorites, result);
    if (old == null || old.pinned || identical(old.result, result)) return;
    final next = old.copyWith(
      result: FavoriteMeal.keepImage(result, old.result),
    );
    await _commitSyncIntents(
      [SyncOp.favoriteUpsert(next)],
      publish: () {
        favorites = [
          for (final favorite in favorites)
            favorite.id == next.id ? next : favorite,
        ];
      },
    );
  }

  /// Re-plans the evening reminders when one of [meals] lies on today: the
  /// half-logged-day question is planned from today's total (C4 planner).
  void _replanIfToday(Iterable<LoggedMeal> meals) {
    final today = localDayKey(clock.now());
    if (meals.any((m) => m.effectiveLocalDay == today)) {
      unawaited(_rescheduleGuarded('notifications-intake'));
    }
  }

  /// Short label for the target day of the move confirmation.
  ///
  /// B5: [daysBetween], not `.difference().inDays` — across a 23-hour spring
  /// day the wall-clock math reported 0 days for yesterday, so the
  /// confirmation claimed "moved to today".
  ///
  /// The date comes from `intl`: skeleton `Md` yields `28.3.` under `de` and
  /// `3/28` under `en`; the German-only preposition lives in the ARB text
  /// ([AppLocalizations.dayLabelOnDate]).
  String _moveDayLabel(DateTime day) {
    final today = DateUtils.dateOnly(clock.now());
    final target = DateUtils.dateOnly(day);
    final offset = daysBetween(today, target);
    if (offset == 0) return _l10n.dayLabelToday;
    if (offset == 1) return _l10n.dayLabelYesterday;
    _ensureDateSymbols();
    return _l10n.dayLabelOnDate(DateFormat.Md(_l10n.localeName).format(target));
  }

  Future<void> removeLoggedMeal(String id) async {
    final removed = loggedMeals.where((m) => m.id == id).firstOrNull;
    await _commitSyncIntents(
      [SyncOp.mealDelete(id)],
      publish: () {
        loggedMeals = loggedMeals.where((m) => m.id != id).toList();
        _refreshMealTotals();
      },
    );
    HapticFeedback.lightImpact();
    if (removed == null) return;
    _replanIfToday([removed]);
    Future<void>? restore;
    _showUndoSnackBar(
      _l10n.commonMealDeleted,
      () => _undoMutation(() => restore ??= _restoreLoggedMeal(removed)),
    );
  }

  Future<void> _restoreLoggedMeal(LoggedMeal meal) async {
    // A delivered delete is terminal for its UUID. Undo restores the content
    // under a new identity without counting another lifetime logging event.
    final restored = LoggedMeal(
      id: uuidV4(),
      result: meal.result,
      loggedAt: meal.loggedAt,
      forcedSlot: meal.forcedSlot,
      localDay: meal.localDay,
    );
    await _commitSyncIntents(
      [SyncOp.mealUpsert(restored)],
      publish: () {
        loggedMeals = [
          restored,
          ...loggedMeals.where((m) => m.id != meal.id && m.id != restored.id),
        ];
        _refreshMealTotals();
      },
    );
    _replanIfToday([restored]);
  }

  void _undoMutation(Future<void> Function() action) {
    unawaited(
      action().catchError((Object error, StackTrace stack) {
        _reportSyncError('undo', error, stack);
      }),
    );
  }

  // --- Trends -----------------------------------------------------------------

  /// Day totals of every day in the trends window this store knows
  /// completely, keyed by local day; null for a known day without entries.
  ///
  /// The trends page lays them over the server's window
  /// (`overlayTrendTotals`): they hold writes still waiting in the outbox,
  /// which the server rows miss for up to the cache's two minutes (TRN-9).
  /// With [confirmedOnly], only after this session's meal load answered: a
  /// cached list alone may lack another device's entries and would hide them
  /// on the trends page. Today's preview, which shows nothing else, takes the
  /// cache. [days] counts back from today.
  Map<String, TrendDayTotals?> trendLocalTotals({
    bool confirmedOnly = true,
    int days = TrendService.trendWindowDays,
  }) {
    if (confirmedOnly && sync != null && !_serverMealsLoaded) {
      return const <String, TrendDayTotals?>{};
    }
    final today = startOfDay(clock.now());
    final known = <String, TrendDayTotals?>{};
    for (var n = 0; n < days; n++) {
      final day = addDays(today, -n);
      final key = localDayKey(day);
      if (!_loadedArchiveDays.contains(key) && _needsFoodDayLoad(day)) {
        continue;
      }
      final meals = mealsForFoodDate(day);
      if (meals.isEmpty) {
        known[key] = null;
        continue;
      }
      final sum = meals.fold(
        MacroProgress.empty,
        (total, meal) => total.add(meal.result),
      );
      known[key] = TrendDayTotals(
        day: day,
        kcal: sum.kcal,
        proteinG: sum.proteinG,
        carbsG: sum.carbsG,
        fatG: sum.fatG,
      );
    }
    return known;
  }

  /// Whether [day] passes the complete-day rule ([isCompleteDay] against
  /// the daily goal): the day strip's marker. A day this store does not
  /// know completely (outside the boot window, a capped boot, still loading)
  /// is never marked, rather than judged on part of its entries.
  bool isCompleteFoodDay(DateTime day) {
    final target = DateUtils.dateOnly(day);
    final key = localDayKey(target);
    if (_loadingArchiveDays.contains(key) ||
        (!_loadedArchiveDays.contains(key) && _needsFoodDayLoad(target))) {
      return false;
    }
    final meals = mealsForFoodDate(target);
    if (meals.isEmpty) return false;
    return isCompleteDay(
      intakeKcal: consumedKcalForFoodDate(target),
      goalKcal: profile.dailyKcalGoal,
    );
  }

  // --- Copy meals -----------------------------------------------------------

  /// Day+slot keys of a repeat in flight, so a double tap copies once.
  final Set<String> _repeatsInFlight = <String>{};

  /// True when the meals of the day before [day] in memory are that whole
  /// day: inside a complete boot window, or loaded on demand. Only such a
  /// day is a repeat source, or a partial day would be copied as complete.
  bool previousFoodDayComplete(DateTime day) {
    final previous = addDays(DateUtils.dateOnly(day), -1);
    return _loadedArchiveDays.contains(localDayKey(previous)) ||
        !_needsFoodDayLoad(previous);
  }

  /// The meals of the day before [day], or none while that day is not
  /// completely known ([previousFoodDayComplete]); the diary's repeat source.
  List<LoggedMeal> repeatableMealsBefore(DateTime day) {
    if (!previousFoodDayComplete(day)) return const <LoggedMeal>[];
    return mealsForFoodDate(addDays(DateUtils.dateOnly(day), -1));
  }

  /// Today's quiet hint (2026-10-19): today holds no entry yet, yesterday
  /// is completely known and empty, and the chain ended the day before
  /// yesterday, so an entry for yesterday would save it
  /// ([LifetimeStats.yesterdayRescuesStreak]). After today's first entry the
  /// server could no longer merge yesterday, so the hint is gone by then.
  bool get yesterdayRescuesStreak {
    final now = clock.now();
    return lifetimeStats.yesterdayRescuesStreak(now) &&
        mealsForFoodDate(now).isEmpty &&
        previousFoodDayComplete(now) &&
        repeatableMealsBefore(now).isEmpty;
  }

  /// "Repeat yesterday": copies the entries of [slot] on the day before [day]
  /// onto [day], into the same slot. A no-op (empty result) once [slot] on
  /// [day] holds anything, which also absorbs a double tap.
  ///
  /// Returns the ids of the copies.
  Future<List<String>> repeatPreviousDaySlot(
    MealSlot slot,
    DateTime day,
  ) async {
    final target = DateUtils.dateOnly(day);
    final key = '${localDayKey(target)}:${slot.name}';
    if (_repeatsInFlight.contains(key) ||
        mealsForFoodDate(target).any((m) => m.slot == slot)) {
      return const <String>[];
    }
    final sources = repeatableMealsBefore(
      target,
    ).where((m) => m.slot == slot).toList(growable: false);
    if (sources.isEmpty) throw StateError('Nothing to repeat');
    _repeatsInFlight.add(key);
    try {
      final today = _isSameFoodDate(target, clock.now());
      return await _copyMeals(
        sources,
        target,
        slot,
        today
            ? _l10n.foodCopyRepeatedYesterday(sources.length)
            : _l10n.foodCopyRepeatedPreviousDay(sources.length),
      );
    } finally {
      _repeatsInFlight.remove(key);
    }
  }

  /// "Copy to…" of the edit sheet: copies the logged meals [ids] onto [day],
  /// into [slot] or each one's own slot. The originals stay untouched.
  ///
  /// Returns the ids of the copies; ids no longer logged are skipped.
  Future<List<String>> copyLoggedMeals(
    List<String> ids, {
    required DateTime day,
    MealSlot? slot,
  }) async {
    final wanted = ids.toSet();
    final sources = loggedMeals
        .where((m) => wanted.contains(m.id))
        .toList(growable: false);
    if (sources.isEmpty) throw StateError('Meal no longer exists');
    final target = DateUtils.dateOnly(day);
    return _copyMeals(
      sources,
      target,
      slot,
      _l10n.foodCopyDone(sources.length, _moveDayLabel(target)),
    );
  }

  /// Shared core: each source becomes a NEW entry through the add path's
  /// commit (fresh UUID, one `mealInsert` per copy in one atomic local
  /// commit, outbox, server row caps, lifetime count and streak day, with
  /// the add path's yesterday rule). No AI call and no quota.
  ///
  /// Recents and favorites stay as they are: the sources were already logged
  /// once, and a repeated slot of four entries would otherwise push four of
  /// the five recents out. The product photo is an immutable Open Food Facts
  /// URL inside the result value (logged meals keep no local files), so the
  /// copy shares that value and deleting either entry leaves the other whole.
  Future<List<String>> _copyMeals(
    List<LoggedMeal> sources,
    DateTime target,
    MealSlot? slot,
    String message,
  ) async {
    final now = clock.now();
    if (daysBetween(target, now) > 0) {
      throw ArgumentError.value(target, 'day', 'must not be in the future');
    }
    // Today, or yesterday continuing the chain, is a tracked day.
    final trackDay =
        _isSameFoodDate(target, now) ||
        lifetimeStats.backfillContinuesStreak(target, now: now);
    final copies = _notAfter(now, [
      for (final source in sources) _copyOnto(source, target, slot),
    ]);
    await _commitSyncIntents(
      [for (final copy in copies) SyncOp.mealInsert(copy, trackDay: trackDay)],
      publish: () {
        for (var i = 0; i < copies.length; i++) {
          lifetimeStats = lifetimeStats.incrementMeals();
        }
        if (trackDay) lifetimeStats = lifetimeStats.recordTrackedDay(target);
        loggedMeals = [...copies, ...loggedMeals]
          ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
        _refreshMealTotals();
      },
    );
    HapticFeedback.lightImpact();
    if (trackDay) unawaited(_rescheduleStreakReminder());
    final ids = [for (final copy in copies) copy.id];
    Future<void>? undo;
    _emitSnack(
      message,
      icon: Icons.check_circle_rounded,
      tone: SnackTone.positive,
      action: SnackBarAction(
        label: _l10n.commonUndo,
        onPressed: () => _undoMutation(() => undo ??= _removeCopies(ids)),
      ),
    );
    return ids;
  }

  /// A new entry with [source]'s result on [target], in [slot] or the
  /// source's own slot. The move's day pattern: the local wall-clock time
  /// moves to the target day (seconds included, so copies keep their order
  /// within the slot) and [LoggedMeal.localDay] gets the target's key.
  LoggedMeal _copyOnto(LoggedMeal source, DateTime target, MealSlot? slot) {
    final local = source.loggedAt.toLocal();
    return LoggedMeal(
      id: uuidV4(),
      result: source.result,
      loggedAt: DateTime(
        target.year,
        target.month,
        target.day,
        local.hour,
        local.minute,
        local.second,
        local.millisecond,
      ),
      forcedSlot: slot ?? source.slot,
      localDay: localDayKey(target),
    );
  }

  /// Copies whose wall-clock time lies after [now] (yesterday's dinner
  /// repeated in the morning) move to just before [now], in their order, so
  /// no entry is logged in the future. Earlier times stay as they are.
  List<LoggedMeal> _notAfter(DateTime now, List<LoggedMeal> copies) {
    final ahead = copies.where((c) => c.loggedAt.isAfter(now)).toList()
      ..sort((a, b) => a.loggedAt.compareTo(b.loggedAt));
    if (ahead.isEmpty) return copies;
    final moved = <String, DateTime>{
      for (var i = 0; i < ahead.length; i++)
        ahead[i].id: now.subtract(Duration(milliseconds: ahead.length - 1 - i)),
    };
    return [
      for (final copy in copies)
        moved.containsKey(copy.id)
            ? copy.copyWith(loggedAt: moved[copy.id])
            : copy,
    ];
  }

  /// Undo of a copy: deletes exactly the copies still logged, in one commit.
  /// The lifetime count stays, as for any deleted entry.
  Future<void> _removeCopies(List<String> ids) async {
    final present = ids
        .where((id) => loggedMeals.any((m) => m.id == id))
        .toList(growable: false);
    if (present.isEmpty) return;
    final removed = loggedMeals
        .where((m) => present.contains(m.id))
        .toList(growable: false);
    await _commitSyncIntents(
      [for (final id in present) SyncOp.mealDelete(id)],
      publish: () {
        loggedMeals = loggedMeals
            .where((m) => !present.contains(m.id))
            .toList();
        _refreshMealTotals();
      },
    );
    _replanIfToday(removed);
  }

  // --- Favorites / recents --------------------------------------------------

  static const int _maxAutoRecents = FavoriteMeal.maxAutoRecents;

  List<FavoriteMeal> _cappedFavorites(List<FavoriteMeal> source) {
    final pinned = source.where((f) => f.pinned).toList(growable: false);
    final recents = source
        .where((f) => !f.pinned)
        .take(_maxAutoRecents)
        .toList();
    return [...pinned, ...recents];
  }

  bool isFavorite(MealAnalysisResult result) =>
      FavoriteMeal.findFor(favorites, result)?.pinned ?? false;

  Future<void> toggleFavorite(MealAnalysisResult result) =>
      _serializeFavoriteMutation(() async {
        final old = FavoriteMeal.findFor(favorites, result);
        final id = old?.id ?? FavoriteMeal.idFor(result);
        // The stored portion stays; only a missing photo is taken over.
        final entry =
            old?.copyWith(
              pinned: !old.pinned,
              result: FavoriteMeal.keepImage(old.result, result),
            ) ??
            FavoriteMeal(
              id: id,
              result: result,
              addedAt: clock.now(),
              pinned: true,
            );
        final next = _cappedFavorites(
          [entry, ...favorites.where((f) => f.id != id)]
            ..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
        );
        final survives = next.any((f) => f.id == id);
        await _commitSyncIntents([
          survives ? SyncOp.favoriteUpsert(entry) : SyncOp.favoriteDelete(id),
          for (final old in favorites)
            if (!old.pinned && old.id != id && !next.any((f) => f.id == old.id))
              SyncOp.favoriteDelete(old.id),
        ], publish: () => favorites = next);
        HapticFeedback.selectionClick();
      });

  Future<void> removeFavorite(String id) =>
      _serializeFavoriteMutation(() async {
        final removed = favorites.where((f) => f.id == id).firstOrNull;
        if (removed == null) return;
        await _commitSyncIntents(
          [SyncOp.favoriteDelete(id)],
          publish: () {
            favorites = favorites.where((f) => f.id != id).toList();
          },
        );
        // The add sheet forgets recents through here, not only favorites.
        _showUndoSnackBar(
          removed.pinned
              ? _l10n.commonFavoriteRemoved
              : _l10n.commonRecentRemoved,
          () => _undoMutation(() => _restoreFavorite(removed)),
        );
      });

  Future<void> _restoreFavorite(FavoriteMeal favorite) =>
      _serializeFavoriteMutation(() async {
        await _commitSyncIntents(
          [SyncOp.favoriteUpsert(favorite)],
          publish: () {
            favorites = [
              favorite,
              ...favorites.where((f) => f.id != favorite.id),
            ];
          },
        );
      });

  // --- Own recipes ----------------------------------------------------------

  /// Saves an editor draft only after delivery or durable outbox acceptance.
  Future<SyncDelivery> saveUserRecipe(FitnessRecipe recipe) =>
      _saveRecipeDraft(recipe, requireExisting: false);

  Future<SyncDelivery> _saveRecipeDraft(
    FitnessRecipe recipe, {
    required bool requireExisting,
    int? expectedRevision,
    void Function(SyncOp operation)? observeOperation,
  }) async {
    if (_disposed ||
        _trainingSessionEnded ||
        !recipe.userCreated ||
        !recipe.slug.startsWith('user_') ||
        recipe.slug.length > 200 ||
        recipe.title.trim().isEmpty ||
        recipe.title.runes.length > 300 ||
        recipe.description.runes.length > 4000 ||
        recipe.portion.runes.length > 1000 ||
        recipe.ingredients.runes.length > 20000 ||
        recipe.preparation.runes.length > 20000 ||
        recipe.imageAsset.runes.length > 2048 ||
        recipe.categories.length > 32 ||
        recipe.categories.join(',').runes.length > 2000 ||
        recipe.caloriesKcal < 0 ||
        recipe.caloriesKcal > 10000 ||
        recipe.estimatedGrams < 0 ||
        recipe.estimatedGrams > 10000 ||
        [
          recipe.proteinG,
          recipe.carbsG,
          recipe.fatG,
        ].any((n) => n < 0 || n > 1000)) {
      throw StateError('Recipe cannot be saved');
    }
    if (requireExisting &&
        (!_userRecipes.any((r) => r.slug == recipe.slug && r.userCreated) ||
            _pendingRecipeDeletes.contains(recipe.slug))) {
      throw StateError('Recipe is no longer available');
    }
    final validated = FitnessRecipe.fromRow(
      recipe.toRow(),
    ).copyWith(professionalHint: recipe.professionalHint);
    final cancelsPendingDelete =
        !requireExisting && _pendingRecipeDeletes.contains(recipe.slug);
    final pendingDeleteRevision = cancelsPendingDelete
        ? _userRecipes
              .where((r) => r.slug == recipe.slug)
              .firstOrNull
              ?.serverRevision
        : null;
    final operation = SyncOp.recipeUpsert(
      validated,
      expectedRevision:
          expectedRevision ??
          recipe.serverRevision ??
          pendingDeleteRevision ??
          (_userRecipes.any((r) => r.slug == recipe.slug) ? null : 0),
    );
    observeOperation?.call(operation);
    return _commitSyncIntents(
      [operation],
      notifyQueued: false,
      publish: () {
        if (cancelsPendingDelete) {
          _pendingRecipeDeletes = {..._pendingRecipeDeletes}
            ..remove(recipe.slug);
        }
        _userRecipes = [
          validated,
          ..._userRecipes.where((r) => r.slug != recipe.slug),
        ];
      },
    );
  }

  /// Creates an own recipe and reports what happened to it.
  ///
  /// Gap E: the recipes screen showed a synchronous "saved" toast and the
  /// store's generic queue hint then wiped it. The screen now awaits this
  /// result and says both in ONE sentence, while the store withholds its own
  /// hint (`notifyQueued: false`).
  Future<SyncDelivery> createUserRecipe(FitnessRecipe recipe) =>
      saveUserRecipe(recipe);

  Future<SyncDelivery> deleteUserRecipe(String slug) => _commitSyncIntents(
    [
      SyncOp.recipeDelete(
        slug,
        expectedRevision: _userRecipes
            .where((r) => r.slug == slug)
            .firstOrNull
            ?.serverRevision,
      ),
    ],
    notifyQueued: false,
    publish: () {
      _userRecipes = _userRecipes.where((r) => r.slug != slug).toList();
      _pendingRecipeDeletes = {..._pendingRecipeDeletes}..remove(slug);
    },
  );

  Future<RecipeHistoryPage> loadUserRecipeHistory({
    String? slug,
    int? beforeRevision,
  }) async {
    _ensureMutationActive();
    final service = sync;
    if (service == null) throw StateError('Recipe history unavailable');
    final result = await UserRecipeReads(
      service.client,
      service.userId,
    ).loadHistory(slug: slug, beforeRevision: beforeRevision);
    _ensureMutationActive();
    return result;
  }

  Future<SyncDelivery> restoreUserRecipe(
    FitnessRecipe recipe, {
    required int expectedRevision,
  }) => _saveRecipeDraft(
    recipe,
    requireExisting: false,
    expectedRevision: expectedRevision,
  );
}

/// One-time init of the `intl` date symbols; without it `DateFormat.Md('de')`
/// throws a LocaleDataException. `initializeDateFormatting()` loads its CLDR
/// table synchronously, so the guard only saves repeated setup.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}
