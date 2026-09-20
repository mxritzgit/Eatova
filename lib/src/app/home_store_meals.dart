part of 'home_store.dart';

/// Meals part of [HomeStore]: log/edit/delete with undo, favorites/recents,
/// own recipes, and on-demand loading of days outside the boot window.
mixin _HomeStoreMealsPart
    on
        _HomeStoreBase,
        _HomeStoreSyncPart,
        _HomeStoreTrackingPart,
        _HomeStoreProfilePart {
  Future<void> _favoriteMutationTail = Future<void>.value();

  Future<T> _serializeFavoriteMutation<T>(Future<T> Function() action) {
    final future = _favoriteMutationTail.then((_) => action());
    _favoriteMutationTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return future;
  }

  // --- On-demand loading of days outside the boot window --------------------
  // Boot loads only the 35-day window (MealsSync.loggedMealsWindowDays);
  // picking an older day loads exactly that day and merges it into
  // loggedMeals. Such days stay in memory (session-local), never reach the
  // durable LocalCache during the read, and drop out on the next
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
      // durable writes happen only for confirmed local changes or hydration.
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
    final missing = rows
        .where((m) => !known.contains(m.id))
        .toList(growable: false);
    if (missing.isNotEmpty) {
      // Restore the server order (logged_at descending) after the merge.
      loggedMeals = [...loggedMeals, ...missing]
        ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    }
    _applyPendingOpsToState();
  }

  // --- Meals ----------------------------------------------------------------

  Future<String> addResultToDailyTotal(
    MealAnalysisResult result, {
    MealSlot? slot,
    DateTime? foodDate,
  }) => _serializeFavoriteMutation(() async {
    final targetDate = DateUtils.dateOnly(foodDate ?? selectedFoodDate);
    final entry = LoggedMeal(
      id: uuidV4(),
      result: result,
      loggedAt: _timestampForFoodDate(targetDate),
      forcedSlot: slot,
    );
    final today = _isSameFoodDate(targetDate, clock.now());
    final recentId = FavoriteMeal.idFor(result);
    final old = favorites.where((f) => f.id == recentId).firstOrNull;
    final recent = FavoriteMeal(
      id: recentId,
      result: result,
      addedAt: clock.now(),
      pinned: old?.pinned ?? false,
    );
    final before = [recent, ...favorites.where((f) => f.id != recentId)];
    final after = _cappedFavorites(before);
    final intents = [
      SyncOp.mealInsert(entry, trackDay: today),
      SyncOp.favoriteUpsert(recent),
      for (final dropped in before)
        if (!dropped.pinned && !after.any((f) => f.id == dropped.id))
          SyncOp.favoriteDelete(dropped.id),
    ];
    await _commitSyncIntents(
      intents,
      publish: () {
        lifetimeStats = lifetimeStats.incrementMeals();
        if (today) lifetimeStats = lifetimeStats.recordTrackedDay(targetDate);
        favorites = after;
        loggedMeals = [entry, ...loggedMeals.where((m) => m.id != entry.id)];
        _refreshMealTotals();
      },
    );
    HapticFeedback.lightImpact();
    if (today) unawaited(_rescheduleStreakReminder());
    return entry.id;
  });

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
    var movedToToday = false;
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
        movedToToday = _isSameFoodDate(targetDay, clock.now());
      }
    }
    if (result == null && slot == null && !dayChanged) return previous;

    HapticFeedback.lightImpact();
    await _applyLoggedMealDetails(updated, recordToday: movedToToday);
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
  /// idempotent upsert.
  Future<void> _applyLoggedMealDetails(
    LoggedMeal updated, {
    bool recordToday = false,
  }) async {
    if (!loggedMeals.any((m) => m.id == updated.id)) {
      throw StateError('Meal no longer exists');
    }
    final update = SyncOp.mealUpsert(updated);
    await _commitSyncIntents(
      [
        update,
        if (recordToday) SyncOp.trackingDay(updated.effectiveLocalDay)
            .withPredecessor(update.operationId),
      ],
      publish: () {
        loggedMeals = [updated, ...loggedMeals.where((m) => m.id != updated.id)]
          ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
        if (recordToday) {
          lifetimeStats = lifetimeStats.recordTrackedDay(clock.now());
        }
        _refreshMealTotals();
      },
    );
    if (recordToday) unawaited(_rescheduleStreakReminder());
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
  }

  void _undoMutation(Future<void> Function() action) {
    unawaited(
      action().catchError((Object error, StackTrace stack) {
        _reportSyncError('undo', error, stack);
      }),
    );
  }

  // --- Favorites / recents --------------------------------------------------

  static const int _maxAutoRecents = 5;

  List<FavoriteMeal> _cappedFavorites(List<FavoriteMeal> source) {
    final pinned = source.where((f) => f.pinned).toList(growable: false);
    final recents = source
        .where((f) => !f.pinned)
        .take(_maxAutoRecents)
        .toList();
    return [...pinned, ...recents];
  }

  bool isFavorite(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    final matches = favorites.where((f) => f.id == id);
    return matches.isNotEmpty && matches.first.pinned;
  }

  Future<void> toggleFavorite(MealAnalysisResult result) =>
      _serializeFavoriteMutation(() async {
        final id = FavoriteMeal.idFor(result);
        final old = favorites.where((f) => f.id == id).firstOrNull;
        final entry =
            old?.copyWith(pinned: !old.pinned) ??
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
        _showUndoSnackBar(
          _l10n.commonFavoriteRemoved,
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

  /// Replaces the same owned recipe; a stale route cannot recreate a deletion.
  Future<SyncDelivery> updateUserRecipe(FitnessRecipe recipe) =>
      _saveRecipeDraft(recipe, requireExisting: true);

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
        ? _userRecipes.where((r) => r.slug == recipe.slug).firstOrNull?.serverRevision
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
          _pendingRecipeDeletes = {..._pendingRecipeDeletes}..remove(recipe.slug);
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
  /// hint ([aufruferMeldetAusgang]).
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
