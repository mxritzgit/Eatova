part of 'home_store.dart';

/// Meals part of [HomeStore]: log/edit/delete with undo, favorites/recents,
/// own recipes, and on-demand loading of days outside the boot window.
mixin _HomeStoreMealsPart
    on
        _HomeStoreBase,
        _HomeStoreSyncPart,
        _HomeStoreTrackingPart,
        _HomeStoreProfilePart {
  // --- On-demand loading of days outside the boot window --------------------
  // Boot loads only the 35-day window (MealsSync.loggedMealsWindowDays);
  // picking an older day loads exactly that day and merges it into
  // loggedMeals. Such days stay in memory (session-local), never reach the
  // durable LocalCache (see _cacheableLoggedMeals), and drop out on the next
  // window load — the merge source is always the server state.
  /// Archive days already loaded (localDayKey), to avoid repeat queries.
  /// Cleared on a window refresh.
  final Set<String> _loadedArchiveDays = <String>{};

  /// Archive days currently in flight (localDayKey) — drives the UI loading
  /// state and dedups parallel triggers.
  final Set<String> _loadingArchiveDays = <String>{};

  /// True while [day] is being loaded on demand; the UI shows a spinner
  /// instead of a wrongly empty day.
  bool isLoadingFoodDay(DateTime day) =>
      _loadingArchiveDays.contains(localDayKey(DateUtils.dateOnly(day)));

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

  /// Loads an archive day on demand and merges it into [loggedMeals]. Once per
  /// day per session (_loadedArchiveDays); errors show the classified message
  /// and leave the day retryable on the next tap.
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
      _mutate(() => _mergeArchiveMeals(rows));
      // No _cacheLoggedMeals(): archive days stay in memory (see
      // _cacheableLoggedMeals), the durable cache holds only the boot window.
    } catch (e, st) {
      // Read error with no outbox safety net (nothing to replay): classified
      // message via the existing pattern, raw error to dev.log/reporter.
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
    final missing =
        rows.where((m) => !known.contains(m.id)).toList(growable: false);
    if (missing.isNotEmpty) {
      // Restore the server order (logged_at descending) after the merge.
      loggedMeals = [...loggedMeals, ...missing]
        ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    }
    _applyPendingOpsToState();
  }

  // --- Meals ----------------------------------------------------------------

  String addResultToDailyTotal(
    MealAnalysisResult result, {
    MealSlot? slot,
    DateTime? foodDate,
  }) {
    final targetDate = DateUtils.dateOnly(foodDate ?? selectedFoodDate);
    final entry = LoggedMeal(
      id: uuidV4(),
      result: result,
      loggedAt: _timestampForFoodDate(targetDate),
      forcedSlot: slot,
    );
    final targetIsToday = _isSameFoodDate(targetDate, clock.now());
    HapticFeedback.lightImpact();
    _mutate(() {
      lifetimeStats = lifetimeStats.incrementMeals();
      if (targetIsToday) {
        // Logging streak: today counts immediately (optimistic, idempotent
        // per day). Back-fills for past days do not count.
        lifetimeStats = lifetimeStats.recordTrackedDay(clock.now());
      }
      _rememberRecent(result);
      loggedMeals = [entry, ...loggedMeals];
      _invalidateTrendWindow();
      if (targetIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
        macroProgress = macroProgressForFoodDate(clock.now());
      }
    });
    if (targetIsToday) {
      // Today is tracked now: drop today's 20:00 reminder and re-open the
      // 7-day window from tomorrow. The optimistic recordTrackedDay above is
      // enough for the planner.
      unawaited(_rescheduleStreakReminder());
    }
    _cacheLoggedMeals();
    _cacheFavorites(); // _rememberRecent mutated favorites/recents
    if (sync == null) return entry.id;
    // DATA-7: NO rollback — the meal stays in the diary and is caught up as an
    // outbox op (including stats/streak counting on replay success).
    //
    // Gap B: goes through the same op-first path as every other write; the
    // former dedicated then/catchError never created an op on a hanging
    // request.
    _syncOrQueue(
      'Mahlzeit',
      () => sync!.meals.insertLoggedMeal(entry),
      () => SyncOp.mealInsert(entry, trackDay: targetIsToday),
      onDelivered: () {
        // Exactly the side effects _performOp does itself on replay, so they
        // run only after LIVE delivery.
        _queueStatsDelta(meals: 1);
        // The MEAL's day, not the delivery's: this callback runs after the
        // network round trip. A log at 23:59:58 would otherwise book p_day =
        // D+1, which has no source row in logged_meals —
        // record_tracking_day throws EX_DAY_NOT_LOGGED, day D stays uncounted
        // and the op retries until the drop deadline.
        if (targetIsToday) _recordTrackingDay(day: targetDate);
      },
    );
    return entry.id;
  }

  void updateLoggedMealResult(String id, MealAnalysisResult scaled) {
    final index = loggedMeals.indexWhere((m) => m.id == id);
    if (index == -1) return;
    final target = loggedMeals[index];
    final updated = target.copyWith(result: scaled);
    _mutate(() {
      final nextMeals = [...loggedMeals];
      nextMeals[index] = updated;
      loggedMeals = nextMeals;
      _invalidateTrendWindow();
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
        macroProgress = macroProgressForFoodDate(clock.now());
      }
    });
    _cacheLoggedMeals();
    // Queued, the update is a full upsert on the same client UUID, so it lands
    // correctly even while the original insert is still queued (FIFO per
    // entity).
    _syncOrQueue(
      'Mahlzeit-Update',
      () => sync!.meals.updateLoggedMeal(updated),
      () => SyncOp.mealUpsert(updated),
    );
  }

  /// Edit sheet: changes portion ([result]), slot ([slot]) and/or day ([day])
  /// of a logged meal in ONE outbox-safe update (upsert on the client UUID, no
  /// rollback). Only passed fields change; `null` means unchanged.
  ///
  /// Day move (DATA-6 consistent): [loggedAt] keeps its local wall-clock time
  /// on the target day and [LoggedMeal.localDay] gets the new canonical key,
  /// so bucketing, day counters and the server row stay aligned.
  ///
  /// Streak: a move ONTO today records today as tracked (idempotent per day).
  /// Moves to past days are back-fills and leave the streak alone. A move AWAY
  /// from today cannot un-track it — there is no server-side decrement;
  /// accepted.
  ///
  /// Returns the updated meal, or null if [id] no longer exists.
  LoggedMeal? updateLoggedMealDetails(
    String id, {
    MealAnalysisResult? result,
    MealSlot? slot,
    DateTime? day,
  }) {
    final index = loggedMeals.indexWhere((m) => m.id == id);
    if (index == -1) return null;
    final previous = loggedMeals[index];

    var updated = previous.copyWith(result: result, forcedSlot: slot);
    var dayChanged = false;
    var movedToToday = false;
    if (day != null) {
      final targetDay = DateUtils.dateOnly(day);
      final targetKey = localDayKey(targetDay);
      if (targetKey != previous.effectiveLocalDay) {
        // Keep the meal's local wall-clock time, swap only the calendar day,
        // so the slot heuristic (loggedAt.hour) stays stable.
        final local = previous.loggedAt.toLocal();
        updated = updated.copyWith(
          loggedAt: DateTime(targetDay.year, targetDay.month, targetDay.day,
              local.hour, local.minute),
          localDay: targetKey,
        );
        dayChanged = true;
        movedToToday = _isSameFoodDate(targetDay, clock.now());
      }
    }
    if (result == null && slot == null && !dayChanged) return previous;

    HapticFeedback.lightImpact();
    _applyLoggedMealDetails(updated, recordToday: movedToToday);
    final message = dayChanged
        ? _l10n.mealMovedTo(_moveDayLabel(updated.loggedAt))
        : _l10n.mealUpdated;
    _emitSnack(
      message,
      icon: Icons.check_circle_rounded,
      tone: SnackTone.positive,
      action: SnackBarAction(
        label: _l10n.commonUndo,
        onPressed: () => _revertLoggedMealUpdate(previous),
      ),
    );
    return updated;
  }

  /// Undo of the edit sheet: restores the previous meal state via the same
  /// outbox-safe upsert. No-op if the meal was deleted meanwhile. The streak
  /// is NOT rolled back (no server decrement, see updateLoggedMealDetails).
  void _revertLoggedMealUpdate(LoggedMeal previous) {
    _applyLoggedMealDetails(previous);
  }

  /// Shared apply core of update + undo: replaces the row, restores the server
  /// order, recomputes TODAY's counters/macros (a move can affect today even
  /// while another day is shown), mirrors into the LocalCache and syncs as an
  /// idempotent upsert.
  void _applyLoggedMealDetails(LoggedMeal updated, {bool recordToday = false}) {
    final index = loggedMeals.indexWhere((m) => m.id == updated.id);
    if (index == -1) return;
    _mutate(() {
      final next = [...loggedMeals];
      next[index] = updated;
      next.sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
      loggedMeals = next;
      _invalidateTrendWindow();
      dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
      macroProgress = macroProgressForFoodDate(clock.now());
      if (recordToday) {
        // Optimistic like a fresh log; the trackingDay op queued below adopts
        // the authoritative row when it is delivered.
        lifetimeStats = lifetimeStats.recordTrackedDay(clock.now());
      }
    });
    _cacheLoggedMeals();
    if (recordToday) unawaited(_rescheduleStreakReminder());
    // As in the live log and the replay: the day comes from the same source
    // that goes into the server row (logged_meals.local_day), which is what
    // the RPC's source proof compares against.
    final trackedDay =
        recordToday ? DateTime.parse(updated.effectiveLocalDay) : null;
    // NO `onDelivered: _recordTrackingDay` here — the queued op below is the
    // ONE path that books the day, live and offline alike. Both together fired
    // record_tracking_day TWICE per live move (C-01): the callback runs in the
    // PATCH's `then`, and the `_onSyncSuccess` two lines further down starts
    // the replay of the queued twin in the SAME microtask. Two concurrent RPCs,
    // two lifetimeStats adoptions — and the callback's answer then filtered the
    // outbox (`_clearQueuedTrackingDay`) WHILE that replay was walking it,
    // which cost the replay cursor the op that moved up.
    _syncOrQueue(
      'Mahlzeit-Update',
      () => sync!.meals.updateLoggedMeal(updated),
      () => SyncOp.mealUpsert(updated),
    );
    if (trackedDay != null) {
      // The day gets its own op: SyncOp.mealUpsert carries no `trackDay` flag
      // (unlike mealInsert), so nothing else would ever book it. Enqueued AFTER
      // the upsert, so the FIFO replay writes the row first — P1-05:
      // record_tracking_day needs a logged_meals row for the day
      // (EX_DAY_NOT_LOGGED -> P0001), and a move ONTO today is exactly the case
      // where today may still be empty.
      //
      // It carries the live path too, not just the offline one: the PATCH's
      // success runs `_onSyncSuccess` -> `_replayOutbox`, which plays this op
      // once the row exists — one RPC, in order. And it is the only form that
      // survives what a delivery callback cannot reach: offline, entity already
      // busy, a request that never answers, a kill in between. Coalesced per
      // day.
      _queueTrackingDay(trackedDay);
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

  void removeLoggedMeal(String id) {
    final matches = loggedMeals.where((m) => m.id == id);
    final removed = matches.isEmpty ? null : matches.first;
    HapticFeedback.lightImpact();
    _mutate(() {
      loggedMeals = loggedMeals.where((m) => m.id != id).toList();
      _invalidateTrendWindow();
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
        macroProgress = macroProgressForFoodDate(clock.now());
      }
    });
    _cacheLoggedMeals();
    _syncOrQueue(
      'Mahlzeit-Delete',
      () => sync!.meals.deleteLoggedMeal(id),
      () => SyncOp.mealDelete(id),
    );
    if (removed != null) {
      _showUndoSnackBar(_l10n.commonMealDeleted, () => _restoreLoggedMeal(removed));
    }
  }

  void _restoreLoggedMeal(LoggedMeal meal) {
    if (loggedMeals.any((m) => m.id == meal.id)) return;
    _mutate(() {
      loggedMeals = [meal, ...loggedMeals];
      _invalidateTrendWindow();
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
        macroProgress = macroProgressForFoodDate(clock.now());
      }
    });
    _cacheLoggedMeals();
    // Restore counts NO stats again -> mealUpsert, not mealInsert. If the
    // delete is still queued, FIFO puts the upsert behind it, so the row ends
    // up existing again.
    _syncOrQueue(
      'Mahlzeit-Restore',
      () => sync!.meals.insertLoggedMeal(meal),
      () => SyncOp.mealUpsert(meal),
    );
  }

  // --- Favorites / recents --------------------------------------------------

  static const int _maxAutoRecents = 5;

  void _rememberRecent(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    final existing = favorites.where((f) => f.id == id);
    final wasPinned = existing.isNotEmpty && existing.first.pinned;
    final entry = FavoriteMeal(
      id: id,
      result: result,
      addedAt: clock.now(),
      pinned: wasPinned,
    );
    final vorDemDeckel = [entry, ...favorites.where((f) => f.id != id)];
    final nachDemDeckel = _cappedFavorites(vorDemDeckel);
    favorites = nachDemDeckel;
    _syncOrQueue(
      'Favorit',
      () => sync!.meals.upsertFavorite(entry),
      () => SyncOp.favoriteUpsert(entry),
    );
    _forgetDroppedRecents(vorDemDeckel, nachDemDeckel);
  }

  /// Propagates the local recents cap to the server (review 2026-08-19).
  ///
  /// [_cappedFavorites] only dropped the oldest auto-recent from the in-memory
  /// list; the server row stayed and favorite_meals grew with every distinct
  /// meal, so the next cold start brought the whole history back.
  ///
  /// Pinned favorites are outside the recents quota and cannot be hit by the
  /// cap; the `pinned` filter is kept anyway — an unrequested deletion is the
  /// costlier error.
  ///
  /// No undo snack: recents are an automatic suggestion list, not user
  /// content, so their turnover is expected.
  void _forgetDroppedRecents(
      List<FavoriteMeal> vorher, List<FavoriteMeal> nachher) {
    if (vorher.length == nachher.length) return;
    final behalten = nachher.map((f) => f.id).toSet();
    for (final gefallen in vorher) {
      if (gefallen.pinned || behalten.contains(gefallen.id)) continue;
      _syncOrQueue(
        'Favorit-Delete',
        () => sync!.meals.deleteFavorite(gefallen.id),
        () => SyncOp.favoriteDelete(gefallen.id),
      );
    }
  }

  List<FavoriteMeal> _cappedFavorites(List<FavoriteMeal> source) {
    final pinned = source.where((f) => f.pinned).toList(growable: false);
    final recents =
        source.where((f) => !f.pinned).take(_maxAutoRecents).toList();
    return [...pinned, ...recents];
  }

  bool isFavorite(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    final matches = favorites.where((f) => f.id == id);
    return matches.isNotEmpty && matches.first.pinned;
  }

  void toggleFavorite(MealAnalysisResult result) {
    HapticFeedback.selectionClick();
    final id = FavoriteMeal.idFor(result);
    final existing = favorites.where((f) => f.id == id);
    final isPinned = existing.isNotEmpty && existing.first.pinned;

    if (isPinned) {
      final downgraded = existing.first.copyWith(pinned: false);
      final next = _cappedFavorites(
        [...favorites.where((f) => f.id != id), downgraded]
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
      );
      final survived = next.any((f) => f.id == id);
      _mutate(() => favorites = next);
      _cacheFavorites();
      if (survived) {
        _syncOrQueue(
          'Favorit',
          () => sync!.meals.upsertFavorite(downgraded),
          () => SyncOp.favoriteUpsert(downgraded),
        );
      } else {
        _syncOrQueue(
          'Favorit-Delete',
          () => sync!.meals.deleteFavorite(id),
          () => SyncOp.favoriteDelete(id),
        );
      }
    } else {
      final entry = existing.isNotEmpty
          ? existing.first.copyWith(pinned: true)
          : FavoriteMeal(
              id: id, result: result, addedAt: clock.now(), pinned: true);
      _mutate(() {
        favorites = [entry, ...favorites.where((f) => f.id != id)];
      });
      _cacheFavorites();
      _syncOrQueue(
        'Favorit',
        () => sync!.meals.upsertFavorite(entry),
        () => SyncOp.favoriteUpsert(entry),
      );
    }
  }

  void removeFavorite(String id) {
    final matches = favorites.where((f) => f.id == id);
    final removed = matches.isEmpty ? null : matches.first;
    _mutate(() {
      favorites = favorites.where((f) => f.id != id).toList();
    });
    _cacheFavorites();
    _syncOrQueue(
      'Favorit-Delete',
      () => sync!.meals.deleteFavorite(id),
      () => SyncOp.favoriteDelete(id),
    );
    if (removed != null) {
      _showUndoSnackBar(
          _l10n.commonFavoriteRemoved, () => _restoreFavorite(removed));
    }
  }

  void _restoreFavorite(FavoriteMeal fav) {
    if (favorites.any((f) => f.id == fav.id)) return;
    _mutate(() {
      favorites = fav.pinned
          ? [fav, ...favorites]
          : _cappedFavorites([fav, ...favorites]);
    });
    _cacheFavorites();
    _syncOrQueue(
      'Favorit-Restore',
      () => sync!.meals.upsertFavorite(fav),
      () => SyncOp.favoriteUpsert(fav),
    );
  }

  // --- Own recipes ----------------------------------------------------------

  // Gap A: own recipes were the only user collection WITHOUT a local
  // write-through; the outbox was their only safety net. Both mutations
  // therefore mirror into the cache BEFORE the network write.
  //
  // The cache stays the second, INDEPENDENT net: an outbox op can be
  // delivered, dropped at the cap or unreadable, and the boot merge (gap C)
  // keeps the server list from overwriting the cached state.

  /// Creates an own recipe and reports what happened to it.
  ///
  /// Gap E: the recipes screen showed a synchronous "saved" toast and the
  /// store's generic queue hint then wiped it. The screen now awaits this
  /// result and says both in ONE sentence, while the store withholds its own
  /// hint ([aufruferMeldetAusgang]).
  Future<SyncDelivery> createUserRecipe(FitnessRecipe recipe) {
    _mutate(() {
      _userRecipes = [
        recipe,
        ..._userRecipes.where((r) => r.slug != recipe.slug)
      ];
    });
    _cacheUserRecipes();
    return _syncOrQueue(
      'Rezept',
      () => sync!.userRecipes.upsert(recipe),
      () => SyncOp.recipeUpsert(recipe),
      aufruferMeldetAusgang: true,
    );
  }

  /// Deletes an own recipe. Reports the outcome like [createUserRecipe] — an
  /// unbacked "deleted" would be the same error in reverse.
  Future<SyncDelivery> deleteUserRecipe(String slug) {
    _mutate(() {
      _userRecipes = _userRecipes.where((r) => r.slug != slug).toList();
    });
    _cacheUserRecipes();
    return _syncOrQueue(
      'Rezept-Delete',
      () => sync!.userRecipes.delete(slug),
      () => SyncOp.recipeDelete(slug),
      aufruferMeldetAusgang: true,
    );
  }
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
