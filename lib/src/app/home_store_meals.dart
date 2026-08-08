part of 'home_store.dart';

/// Mahlzeiten-Part von [HomeStore]: Loggen/Editieren/Loeschen inkl. Undo,
/// Favoriten/Recents, Eigen-Rezepte und das On-Demand-Nachladen alter Tage
/// ausserhalb des Boot-Fensters. Reine Datei-Aufteilung — Verhalten und
/// Member sind 1:1 aus home_store.dart uebernommen.
mixin _HomeStoreMealsPart
    on
        _HomeStoreBase,
        _HomeStoreSyncPart,
        _HomeStoreTrackingPart,
        _HomeStoreProfilePart {
  // --- On-Demand-Laden alter Tage (ausserhalb des Boot-Fensters) ------------
  // Der Boot laedt nur das 35-Tage-Fenster (MealsSync.loggedMealsWindowDays).
  // Waehlt der Nutzer per Kalender einen aelteren Tag, wird GENAU dieser Tag
  // nachgeladen und in loggedMeals gemerged. Nachgeladene Alt-Tage bleiben
  // bewusst In-Memory (Session-lokal): sie wandern NICHT in den durablen
  // LocalCache (siehe _cacheableLoggedMeals) und fliegen beim naechsten
  // Fenster-Load wieder raus — die Merge-Quelle ist immer der Server-Stand.
  /// Bereits nachgeladene Alt-Tage (localDayKey) — verhindert wiederholte
  /// Queries beim Hin- und Herspringen. Wird beim Fenster-Refresh geleert.
  final Set<String> _loadedArchiveDays = <String>{};

  /// Gerade in-flight nachladende Alt-Tage (localDayKey) — treibt den
  /// Lade-Zustand der UI und dedupliziert parallele Trigger.
  final Set<String> _loadingArchiveDays = <String>{};

  /// True, waehrend [day] gerade on-demand nachgeladen wird (Alt-Tag
  /// ausserhalb des Boot-Fensters) — die UI zeigt dann einen Spinner statt
  /// eines faelschlich leeren Tages.
  bool isLoadingFoodDay(DateTime day) =>
      _loadingArchiveDays.contains(localDayKey(DateUtils.dateOnly(day)));

  /// Liegt [day] ausserhalb des Boot-Fensters von
  /// [MealsSync.loadLoggedMeals]? Der Fenster-Cutoff ist ein Zeitstempel
  /// (jetzt − 35 Tage), der Grenztag ist also nur PARTIELL geladen — er
  /// zaehlt deshalb bewusst als „ausserhalb" und wird on-demand vollstaendig
  /// nachgeladen (der Merge ist duplikat-sicher per id).
  ///
  /// B5: gerechnet in KALENDERTAGEN ([daysBetween]), nicht ueber
  /// `.difference().inDays`. Letzteres ist Absolutzeit: in jedem Zeitraum, der
  /// eine Fruehjahrsumstellung enthaelt, fehlt eine Stunde, der Randtag zaehlte
  /// dadurch nur als 34 und galt faelschlich als „im Fenster geladen" — er
  /// wurde nach jeder Umstellung fuer fuenf Wochen nie nachgeladen und blieb
  /// dauerhaft leer.
  bool _isOutsideBootWindow(DateTime day) =>
      daysBetween(clock.now(), day) >= MealsSync.loggedMealsWindowDays;

  /// Laedt einen Alt-Tag (ausserhalb des Boot-Fensters) on-demand nach und
  /// merged ihn in [loggedMeals]. Pro Session genau einmal pro Tag
  /// (_loadedArchiveDays); Fehler zeigen die bestehende klassifizierte
  /// Meldung (sync_error_messages) und lassen den Tag beim naechsten Tap
  /// erneut versuchen.
  Future<void> _ensureArchiveDayLoaded(DateTime day) async {
    final s = sync;
    if (s == null) return;
    final target = DateUtils.dateOnly(day);
    final key = localDayKey(target);
    if (_loadedArchiveDays.contains(key) || _loadingArchiveDays.contains(key)) {
      return;
    }
    _loadingArchiveDays.add(key);
    if (!_disposed) notifyListeners(); // Spinner an
    try {
      final rows = await s.meals.loadLoggedMealsForDay(target);
      if (_disposed) return;
      _loadedArchiveDays.add(key);
      _mutate(() => _mergeArchiveMeals(rows));
      // BEWUSST kein _cacheLoggedMeals(): nachgeladene Alt-Tage bleiben
      // In-Memory (siehe _cacheableLoggedMeals) — der durable Cache traegt
      // weiterhin nur das Boot-Fenster.
    } catch (e, st) {
      // Read-Fehler ohne Outbox-Netz (nichts nachzuspielen): klassifizierte
      // Meldung ueber das bestehende Muster, Roh-Fehler an dev.log/Reporter.
      _reportSyncError('Tag-Nachladen', e, st);
    } finally {
      _loadingArchiveDays.remove(key);
      if (!_disposed) notifyListeners(); // Spinner aus
    }
  }

  /// Merged frisch nachgeladene Server-Zeilen eines Alt-Tags duplikat-sicher
  /// in [loggedMeals] (Muster analog [_applyPendingOpsToState]): nur FEHLENDE
  /// ids kommen dazu — eine bereits vorhandene lokale Zeile (z.B. mit noch
  /// nicht synchronisiertem Edit) gewinnt gegen die aeltere Server-Kopie.
  /// Danach werden pendende Outbox-Ops erneut ueberlagert, damit ein noch
  /// nicht replayter Delete keine frisch geladene Zeile wiederbelebt. Muss
  /// innerhalb eines _mutate-Blocks laufen.
  void _mergeArchiveMeals(List<LoggedMeal> rows) {
    final known = loggedMeals.map((m) => m.id).toSet();
    final missing =
        rows.where((m) => !known.contains(m.id)).toList(growable: false);
    if (missing.isNotEmpty) {
      // Server-Sortierung (logged_at absteigend) nach dem Merge herstellen.
      loggedMeals = [...loggedMeals, ...missing]
        ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    }
    _applyPendingOpsToState();
  }

  // --- Mahlzeiten -----------------------------------------------------------

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
        // Logging-Streak: der heutige Log-Tag zaehlt sofort (optimistisch,
        // idempotent pro Tag). Nachtraege fuer vergangene Tage zaehlen nicht.
        lifetimeStats = lifetimeStats.recordTrackedDay(clock.now());
      }
      _rememberRecent(result);
      loggedMeals = [entry, ...loggedMeals];
      if (targetIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
        macroProgress = macroProgressForFoodDate(clock.now());
      }
    });
    if (targetIsToday) {
      // Heute ist jetzt getrackt -> heutigen 20-Uhr-Reminder fallen lassen
      // und das 7-Tage-Fenster ab morgen neu aufziehen. Der optimistische
      // recordTrackedDay-Stand oben reicht dem Planner; der spaetere
      // Server-Refresh via _recordTrackingDay aendert am Plan nichts mehr.
      unawaited(_rescheduleStreakReminder());
    }
    _cacheLoggedMeals();
    _cacheFavorites(); // _rememberRecent hat die Favoriten/Recents mutiert
    final s = sync;
    if (s == null) return entry.id;
    s.meals.insertLoggedMeal(entry).then((_) {
      _queueStatsDelta(meals: 1);
      if (targetIsToday) _recordTrackingDay();
      _onSyncSuccess();
    }).catchError((Object e, StackTrace st) {
      // DATA-7: KEIN Rollback mehr — die Mahlzeit bleibt im Tagebuch stehen
      // und wird als Outbox-Op nachgeholt (inkl. Stats-/Streak-Zaehlung beim
      // Replay-Erfolg). Der Streak-Reminder-Plan von oben bleibt damit
      // ebenfalls korrekt.
      _handleSyncFailure(
        'Mahlzeit',
        e,
        st,
        SyncOp.mealInsert(entry, trackDay: targetIsToday),
      );
    });
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
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
        macroProgress = macroProgressForFoodDate(clock.now());
      }
    });
    _cacheLoggedMeals();
    // Im Outbox-Fall laeuft das Update als voller Upsert derselben Client-UUID
    // — landet auch dann korrekt, wenn der urspruengliche Insert selbst noch
    // in der Queue haengt (Koaleszenz bzw. FIFO pro Entitaet).
    _syncOrQueue(
      'Mahlzeit-Update',
      () => sync!.meals.updateLoggedMeal(updated),
      () => SyncOp.mealUpsert(updated),
    );
  }

  /// Bearbeiten-Sheet: aendert Portion/Bestandteile ([result]), den Slot
  /// ([slot]) und/oder den Tag ([day]) einer bereits geloggten Mahlzeit in
  /// EINEM outbox-sicheren Update (Upsert auf die Client-UUID, kein Rollback).
  /// Nur uebergebene Felder aendern sich; `null` heisst „unveraendert".
  ///
  /// Tag-Verschiebung (DATA-6-konsistent): [loggedAt] wandert unter Erhalt der
  /// lokalen Wanduhr-Zeit auf den Zieltag, [LoggedMeal.localDay] wird auf den
  /// neuen kanonischen Tages-Schluessel gesetzt — Bucketing, Tageszaehler und
  /// Server-Zeile (logged_at + local_day) bleiben damit deckungsgleich.
  ///
  /// Streak-Entscheidung: eine Verschiebung AUF heute verbucht heute als
  /// getrackten Tag (idempotent pro Tag, wie ein frischer Log — heute hat
  /// danach ja >= 1 Mahlzeit). Verschiebungen auf vergangene Tage sind
  /// Nachtraege und lassen die Streak unangetastet (record_tracking_day ist
  /// fuer p_day <= last_workout_date serverseitig ein No-op). Eine
  /// Verschiebung WEG von heute kann den Tag nicht „ent-tracken" — es gibt
  /// serverseitig kein Decrement; bewusst akzeptiert.
  ///
  /// Liefert die aktualisierte Mahlzeit (fuer lokale Sheet-Listen) oder null,
  /// wenn [id] nicht (mehr) existiert. Nach dem Speichern erscheint ein
  /// dezenter Hinweis mit „Rückgängig" (analog zum Loesch-Undo).
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
        // Lokale Wanduhr-Zeit der Mahlzeit beibehalten, nur den Kalendertag
        // tauschen — so bleibt die Slot-Heuristik (loggedAt.hour) stabil.
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
        ? 'Mahlzeit auf ${_moveDayLabel(updated.loggedAt)} verschoben.'
        : 'Mahlzeit aktualisiert.';
    _emitSnack(
      message,
      icon: Icons.check_circle_rounded,
      accent: lime,
      action: SnackBarAction(
        label: 'Rückgängig',
        onPressed: () => _revertLoggedMealUpdate(previous),
      ),
    );
    return updated;
  }

  /// Undo des Bearbeiten-Sheets: stellt den vorherigen Stand der Mahlzeit
  /// wieder her (gleicher outbox-sicherer Upsert-Pfad). Wurde die Mahlzeit
  /// inzwischen geloescht, passiert nichts. Die Streak wird bewusst NICHT
  /// zurueckgerollt (kein Server-Decrement, siehe updateLoggedMealDetails).
  void _revertLoggedMealUpdate(LoggedMeal previous) {
    _applyLoggedMealDetails(previous);
  }

  /// Gemeinsamer Apply-Kern von Update + Undo: ersetzt die Zeile, stellt die
  /// Server-Sortierung (logged_at absteigend) wieder her, zieht die
  /// Tageszaehler/Makros fuer HEUTE nach (eine Verschiebung kann heute auch
  /// betreffen, wenn gerade ein anderer Tag angezeigt wird), spiegelt in den
  /// LocalCache und synct outbox-sicher als idempotenten Upsert.
  void _applyLoggedMealDetails(LoggedMeal updated, {bool recordToday = false}) {
    final index = loggedMeals.indexWhere((m) => m.id == updated.id);
    if (index == -1) return;
    _mutate(() {
      final next = [...loggedMeals];
      next[index] = updated;
      next.sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
      loggedMeals = next;
      dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
      macroProgress = macroProgressForFoodDate(clock.now());
      if (recordToday) {
        // Optimistisch wie beim frischen Log; der Server-Refresh via
        // _recordTrackingDay adoptiert danach die autoritative Zeile.
        lifetimeStats = lifetimeStats.recordTrackedDay(clock.now());
      }
    });
    _cacheLoggedMeals();
    if (recordToday) {
      unawaited(_rescheduleStreakReminder());
      _recordTrackingDay();
    }
    _syncOrQueue(
      'Mahlzeit-Update',
      () => sync!.meals.updateLoggedMeal(updated),
      () => SyncOp.mealUpsert(updated),
    );
  }

  /// Deutsches Kurzlabel fuer den Zieltag der Verschiebe-Bestaetigung.
  ///
  /// B5: [daysBetween] statt `.difference().inDays` — ueber die
  /// Fruehjahrsumstellung (23-Stunden-Tag) meldete die Absolutzeit-Rechnung 0
  /// Tage fuer den Vortag, die Bestaetigung behauptete also „auf heute
  /// verschoben", waehrend die Mahlzeit auf gestern lag.
  String _moveDayLabel(DateTime day) {
    final today = DateUtils.dateOnly(clock.now());
    final target = DateUtils.dateOnly(day);
    final offset = daysBetween(today, target);
    if (offset == 0) return 'heute';
    if (offset == 1) return 'gestern';
    return 'den ${target.day}.${target.month}.';
  }

  void removeLoggedMeal(String id) {
    final matches = loggedMeals.where((m) => m.id == id);
    final removed = matches.isEmpty ? null : matches.first;
    HapticFeedback.lightImpact();
    _mutate(() {
      loggedMeals = loggedMeals.where((m) => m.id != id).toList();
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
      _showUndoSnackBar('Mahlzeit gelöscht', () => _restoreLoggedMeal(removed));
    }
  }

  void _restoreLoggedMeal(LoggedMeal meal) {
    if (loggedMeals.any((m) => m.id == meal.id)) return;
    _mutate(() {
      loggedMeals = [meal, ...loggedMeals];
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(clock.now());
        macroProgress = macroProgressForFoodDate(clock.now());
      }
    });
    _cacheLoggedMeals();
    // Restore zaehlt (wie bisher) KEINE Stats erneut -> mealUpsert, nicht
    // mealInsert. Haengt der Delete noch in der Outbox, sortiert sich der
    // Upsert per FIFO dahinter ein — Endzustand: Zeile existiert wieder.
    _syncOrQueue(
      'Mahlzeit-Restore',
      () => sync!.meals.insertLoggedMeal(meal),
      () => SyncOp.mealUpsert(meal),
    );
  }

  // --- Favoriten / Recents --------------------------------------------------

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
    favorites =
        _cappedFavorites([entry, ...favorites.where((f) => f.id != id)]);
    _syncOrQueue(
      'Favorit',
      () => sync!.meals.upsertFavorite(entry),
      () => SyncOp.favoriteUpsert(entry),
    );
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
      _showUndoSnackBar('Favorit entfernt', () => _restoreFavorite(removed));
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

  // --- Eigen-Rezepte --------------------------------------------------------

  void createUserRecipe(FitnessRecipe recipe) {
    _mutate(() {
      _userRecipes = [
        recipe,
        ..._userRecipes.where((r) => r.slug != recipe.slug)
      ];
    });
    _syncOrQueue(
      'Rezept',
      () => sync!.userRecipes.upsert(recipe),
      () => SyncOp.recipeUpsert(recipe),
    );
  }

  void deleteUserRecipe(String slug) {
    _mutate(() {
      _userRecipes = _userRecipes.where((r) => r.slug != slug).toList();
    });
    _syncOrQueue(
      'Rezept-Delete',
      () => sync!.userRecipes.delete(slug),
      () => SyncOp.recipeDelete(slug),
    );
  }
}
