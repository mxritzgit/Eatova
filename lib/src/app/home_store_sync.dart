part of 'home_store.dart';

/// Sync-Part von [HomeStore] (DATA-7): die persistierte Write-Outbox mit
/// Replay + Backoff, die Lifetime-Stats-Deltas, das Cache-Write-Through in
/// den [LocalCache] sowie die Fehler-/Snack-Pfade. Dazu der Konto-/Cache-
/// Cleanup ([deleteAccount], [signOutCleanup]). Reine Datei-Aufteilung —
/// Verhalten und Member sind 1:1 aus home_store.dart uebernommen.
mixin _HomeStoreSyncPart on _HomeStoreBase {
  // --- DATA-7 Write-Outbox --------------------------------------------------
  // Fehlgeschlagene Sync-Writes rollen den lokalen State NICHT mehr zurueck,
  // sondern landen als persistierte [SyncOp]s hier und werden idempotent
  // nachgespielt: beim Boot, beim Lifecycle-Flush (flushPendingWrites), nach
  // der naechsten erfolgreichen Operation und ueber den Backoff-Timer.
  List<SyncOp> _outbox = <SyncOp>[];
  bool _outboxReplayInFlight = false;
  Timer? _outboxRetryTimer;
  int _outboxRetryAttempt = 0;

  /// Der dezente Queue-Hinweis (Offline ODER "wird automatisch erneut
  /// versucht") wird pro Fehler-Episode nur EINMAL gezeigt (Reset beim
  /// naechsten Sync-Erfolg) — sonst wuerde jede weitere Aktion erneut toasten.
  /// Welcher der beiden Texte kommt, entscheidet der ERSTE Fehler der Episode
  /// (Klassifizierung: [isNetworkSyncError]).
  bool _syncHintShown = false;

  int _pendingMealsDelta = 0;
  int _pendingWeightLogsDelta = 0;
  bool _statsFlushInFlight = false;
  Timer? _statsSaveDebounce;

  /// Noch nicht synchronisierte Write-Operationen (Sicht fuer Tests/Debug).
  List<SyncOp> get pendingOutbox => List.unmodifiable(_outbox);

  /// Querbezug zum Tracking-Part (Implementierung in [_HomeStoreTrackingPart]):
  /// der Outbox-Replay verbucht den Streak-Tag einer nachgeholten Mahlzeit
  /// serverseitig.
  void _recordTrackingDay({DateTime? day});

  // --- Fehler-/Sync-Routing -------------------------------------------------

  /// Fehler einer Operation OHNE Outbox-Netz (z.B. Konto-Löschung): roter
  /// Snack mit freundlicher, klassifizierter Meldung — NIE der rohe
  /// Exception-Text (Schema-Leakage, unlesbar). Die Roh-Exception geht an
  /// dev.log + CrashReporter.
  void _reportSyncError(String operation, Object error, StackTrace stack) {
    dev.log('$operation failed', error: error, name: 'eatova_sync');
    unawaited(CrashReporter.capture(error, stack, context: operation));
    if (_disposed) return;
    _emitSnack(
      directSyncErrorMessage(error),
      icon: Icons.error_outline_rounded,
      accent: danger,
      duration: kSnackError,
    );
  }

  /// Fire-and-forget Sync-Write OHNE Rollback (DATA-7): schlaegt der Write
  /// fehl, bleibt der optimistische lokale State stehen und die Operation
  /// wandert als persistierter Outbox-Eintrag in die Retry-Queue. Frueher
  /// wurde hier zurueckgerollt — der Eintrag des Nutzers war dann bei jedem
  /// Netz-Schluckauf weg.
  ///
  /// Haengt fuer dieselbe Entitaet bereits eine Op in der Outbox, wird die
  /// neue Operation direkt DAHINTER eingereiht statt live zu schreiben: ein
  /// Live-Write wuerde die pendende Op ueberholen (z.B. ein Update, dessen
  /// Insert noch aussteht, traefe serverseitig 0 Zeilen und der Replay
  /// schriebe danach den alten Stand).
  void _syncOrQueue(
    String operation,
    Future<void> Function() action,
    SyncOp Function() buildOp,
  ) {
    if (sync == null) return;
    final op = buildOp();
    if (_outbox.any((o) => o.entityKey == op.entityKey)) {
      _enqueueOp(op);
      _notifyQueued(null);
      _scheduleOutboxRetry();
      return;
    }
    action().then((_) => _onSyncSuccess()).catchError((Object e, StackTrace st) {
      _handleSyncFailure(operation, e, st, op);
    });
  }

  /// Sync-Write fehlgeschlagen: Op persistiert einreihen, dezent hinweisen,
  /// Retry planen. KEIN Rollback, KEIN roter Fehler-Toast mehr.
  void _handleSyncFailure(
      String operation, Object error, StackTrace stack, SyncOp op) {
    dev.log('$operation failed — Op wandert in die Outbox',
        error: error, name: 'eatova_sync');
    unawaited(CrashReporter.capture(error, stack, context: operation));
    _enqueueOp(op);
    if (_disposed) return;
    _notifyQueued(error);
    _scheduleOutboxRetry();
  }

  void _enqueueOp(SyncOp op) {
    // Waehrend eines laufenden Replays nur anhaengen — der Replay koennte
    // gerade genau die Op abspielen, deren Payload sonst koalesziert (und beim
    // Entfernen verworfen) wuerde.
    _outbox = enqueueCoalesced(_outbox, op, appendOnly: _outboxReplayInFlight);
    _persistOutbox();
  }

  /// Dezenter Hinweis, dass ein Write in der Outbox gelandet ist. Der Text
  /// kommt aus dem puren Mapping (sync_error_messages.dart): Netzwerkfehler ->
  /// "Offline …", alles andere -> freundliche Retry-Meldung OHNE
  /// Exception-Details. [error] ist null, wenn die Op ohne Live-Versuch hinter
  /// eine bereits pendende Op eingereiht wurde (kein frischer Fehler) — dann
  /// gilt der neutrale Retry-Text.
  void _notifyQueued(Object? error) {
    if (_disposed || _syncHintShown) return;
    _syncHintShown = true;
    final offline = error != null && isNetworkSyncError(error);
    _emitSnack(
      queuedSyncHint(error),
      icon: offline ? Icons.cloud_off_rounded : Icons.sync_problem_rounded,
      accent: textMuted,
    );
  }

  /// Nach einem erfolgreichen Sync-Write: Fehler-Episode beenden, Backoff
  /// zuruecksetzen und liegengebliebene Ops direkt nachspielen.
  void _onSyncSuccess() {
    if (_disposed) return;
    _syncHintShown = false;
    _outboxRetryAttempt = 0;
    if (_outbox.isNotEmpty && !_outboxReplayInFlight) {
      unawaited(_replayOutbox());
    }
  }

  /// Plant den naechsten Outbox-/Stats-Retry mit exponentiellem Backoff
  /// (30s -> 1m -> 2m -> 4m Cap; Reset bei Erfolg). Bewusst ohne
  /// connectivity-Paket: der Timer ist der einzige Waechter, zusaetzlich
  /// stossen Boot, Lifecycle-Flush und der naechste Erfolg den Replay an.
  void _scheduleOutboxRetry() {
    if (_disposed || sync == null) return;
    if (_outbox.isEmpty &&
        _pendingMealsDelta == 0 &&
        _pendingWeightLogsDelta == 0) {
      return;
    }
    _outboxRetryTimer?.cancel();
    final delay = Duration(seconds: 30 * (1 << _outboxRetryAttempt));
    if (_outboxRetryAttempt < 3) _outboxRetryAttempt++;
    _outboxRetryTimer = Timer(delay, () {
      unawaited(_replayOutbox());
      unawaited(_flushStatsDelta());
    });
  }

  /// Spielt die persistierte Outbox strikt FIFO gegen Supabase ab. Pro
  /// Entitaet bleibt die Reihenfolge erhalten (insert vor update vor delete);
  /// schlaegt eine Op fehl, blockiert sie nur ihre EIGENE Entitaet fuer diesen
  /// Lauf — Ops anderer Entitaeten laufen weiter. Jede erfolgreiche Op wird
  /// sofort entfernt und der Rest persistiert (kill-sicher: ein Abbruch
  /// mittendrin wiederholt hoechstens bereits bestaetigte, idempotente Ops).
  Future<void> _replayOutbox() async {
    final s = sync;
    if (s == null || _outboxReplayInFlight || _outbox.isEmpty) return;
    _outboxReplayInFlight = true;
    final blocked = <String>{};
    var anySuccess = false;
    try {
      var i = 0;
      while (i < _outbox.length) {
        final op = _outbox[i];
        if (blocked.contains(op.entityKey)) {
          i++;
          continue;
        }
        try {
          await _performOp(s, op);
        } catch (e, st) {
          dev.log('Outbox-Replay: ${op.kind.name} bleibt liegen',
              error: e, name: 'eatova_sync');
          unawaited(CrashReporter.capture(e, st,
              context: 'outbox-replay-${op.kind.name}'));
          blocked.add(op.entityKey);
          i++;
          continue;
        }
        anySuccess = true;
        _outbox = [..._outbox]..removeAt(i);
        _persistOutbox();
      }
    } finally {
      _outboxReplayInFlight = false;
    }
    if (_disposed) return;
    if (blocked.isEmpty) {
      _outboxRetryAttempt = 0;
      _outboxRetryTimer?.cancel();
      if (anySuccess) _syncHintShown = false;
    } else {
      _scheduleOutboxRetry();
    }
  }

  /// Fuehrt EINE Outbox-Op gegen den Server aus. Wirft bei Sync-Fehler (der
  /// Replay-Loop behaelt die Op dann). Nachgelagerte Zaehler laufen wie im
  /// jeweiligen Online-Erfolgspfad.
  Future<void> _performOp(EatovaSync s, SyncOp op) async {
    switch (op.kind) {
      case SyncOpKind.mealInsert:
        final meal = op.meal;
        if (meal == null) return; // korrupter Payload -> Op verfaellt still
        await s.meals.insertLoggedMeal(meal);
        _queueStatsDelta(meals: 1);
        // Streak-Tag der MAHLZEIT verbuchen, nicht "heute" — der Replay kann
        // Tage spaeter laufen. record_tracking_day ist idempotent pro Tag und
        // fuer Tage vor dem letzten gezaehlten Tag ein Server-No-op.
        if (op.trackDay) {
          _recordTrackingDay(day: DateTime.parse(meal.effectiveLocalDay));
        }
      case SyncOpKind.mealUpsert:
        final meal = op.meal;
        if (meal == null) return;
        await s.meals.insertLoggedMeal(meal);
      case SyncOpKind.mealDelete:
        await s.meals.deleteLoggedMeal(op.entityId);
      case SyncOpKind.weightInsert:
        final kg = op.weightKg;
        final ts = op.recordedAt;
        if (kg == null || ts == null) return;
        await s.tracking.insertWeight(kg, ts, id: op.entityId);
        _queueStatsDelta(weightLogs: 1);
      case SyncOpKind.favoriteUpsert:
        final fav = op.favorite;
        if (fav == null) return;
        await s.meals.upsertFavorite(fav);
      case SyncOpKind.favoriteDelete:
        await s.meals.deleteFavorite(op.entityId);
      case SyncOpKind.recipeUpsert:
        final recipe = op.recipe;
        if (recipe == null) return;
        await s.userRecipes.upsert(recipe);
      case SyncOpKind.recipeDelete:
        await s.userRecipes.delete(op.entityId);
    }
  }

  /// Spiegelt noch nicht synchronisierte Outbox-Ops in den (gecachten oder
  /// frisch geladenen) State. Idempotent — mehrfaches Anwenden aendert nichts:
  /// Upserts ersetzen vorhandene Eintraege bzw. fuegen fehlende ein, Deletes
  /// entfernen. Muss innerhalb eines _mutate-Blocks laufen.
  void _applyPendingOpsToState() {
    if (_outbox.isEmpty) return;
    var mealsTouched = false;
    for (final op in _outbox) {
      switch (op.kind) {
        case SyncOpKind.mealInsert:
        case SyncOpKind.mealUpsert:
          final meal = op.meal;
          if (meal == null) break;
          final index = loggedMeals.indexWhere((m) => m.id == meal.id);
          if (index >= 0) {
            final next = [...loggedMeals];
            next[index] = meal;
            loggedMeals = next;
          } else {
            loggedMeals = [meal, ...loggedMeals];
          }
          mealsTouched = true;
        case SyncOpKind.mealDelete:
          loggedMeals = loggedMeals.where((m) => m.id != op.entityId).toList();
        case SyncOpKind.weightInsert:
          final kg = op.weightKg;
          final ts = op.recordedAt;
          if (kg == null || ts == null) break;
          if (weightLog.entries.any((e) => e.timestamp.isAtSameMomentAs(ts))) {
            break;
          }
          final entries = [
            ...weightLog.entries,
            WeightLogEntry(timestamp: ts, weightKg: kg),
          ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
          weightLog = WeightLog(entries: entries);
        case SyncOpKind.favoriteUpsert:
          final fav = op.favorite;
          if (fav == null) break;
          favorites = [fav, ...favorites.where((f) => f.id != fav.id)];
        case SyncOpKind.favoriteDelete:
          favorites = favorites.where((f) => f.id != op.entityId).toList();
        case SyncOpKind.recipeUpsert:
          final recipe = op.recipe;
          if (recipe == null) break;
          _userRecipes = [
            recipe,
            ..._userRecipes.where((r) => r.slug != recipe.slug),
          ];
        case SyncOpKind.recipeDelete:
          _userRecipes =
              _userRecipes.where((r) => r.slug != op.entityId).toList();
      }
    }
    if (mealsTouched) {
      // Server-Sortierung (logged_at absteigend) nach dem Merge wiederherstellen.
      loggedMeals = [...loggedMeals]
        ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    }
  }

  void _showUndoSnackBar(String label, VoidCallback onUndo) {
    if (_disposed) return;
    _emitSnack(
      label,
      icon: Icons.delete_outline_rounded,
      accent: danger,
      action: SnackBarAction(label: 'Rückgängig', onPressed: onUndo),
    );
  }

  /// DSGVO Art. 17: löscht Konto + alle Daten serverseitig (RPC). Liefert true,
  /// wenn die Löschung durchlief (dann darf die Schale ausloggen). Bei Fehler
  /// false (kein Logout, damit der User es erneut versuchen kann).
  Future<bool> deleteAccount() async {
    try {
      await sync?.deleteAccount();
    } catch (e, st) {
      _reportSyncError('Konto-Löschung', e, st);
      return false;
    }
    await _clearCache();
    return true;
  }

  /// Räumt den lokalen Klartext-PII-Cache (Profil, Mood-Notiz, Lifetime-Stats,
  /// Notification-Flag) beim Sign-Out — anders als [deleteAccount] OHNE
  /// Server-RPC. Ohne diesen Schritt überlebten Gesundheits-/Profildaten den
  /// Logout unverschlüsselt in den SharedPreferences (Audit 2026-06-09, M-1).
  /// Muss VOR dem eigentlichen `signOut()` laufen, solange der User noch der
  /// aktuelle ist — der defensive Pfad braucht dessen ID.
  Future<void> signOutCleanup() => _clearCache();

  /// Löscht den lokalen Cache. Bevorzugt den bereits gebooteten [_cache], im
  /// Test den injizierten [debugCache]; kommt der Logout vor dem Boot-Ende
  /// (noch kein _cache), wird er defensiv aus der aktuellen Session-User-ID
  /// gebaut, damit auch dann nichts liegen bleibt.
  Future<void> _clearCache() async {
    final cache = _cache ?? debugCache ?? await _resolveCacheForCurrentUser();
    await cache?.clear();
  }

  Future<LocalCache?> _resolveCacheForCurrentUser() async {
    final userId = sync?.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return null;
    return LocalCache.create(userId);
  }

  // --- Persistenz-Helfer ----------------------------------------------------

  Future<void> _writeCacheSnapshot() async {
    final cache = _cache;
    if (cache == null) return;
    await cache.writeProfile(profile);
    await cache.writeLifetimeStats(lifetimeStats);
    await cache.writeLoggedMeals(_cacheableLoggedMeals());
    await cache.writeFavorites(favorites);
    await cache.writeWeightLog(weightLog);
  }

  /// Bewusste Entscheidung: nur Eintraege innerhalb des Boot-Fensters wandern
  /// in den durablen Cache. On-Demand nachgeladene Alt-Tage bleiben
  /// In-Memory — sie wuerden den SharedPreferences-Blob unbegrenzt aufblaehen,
  /// und der naechste Besuch laedt sie ohnehin frisch vom Server. Pendende
  /// WRITES fuer Alt-Tage sind davon unabhaengig kill-sicher: sie leben in
  /// der persistierten Outbox und werden beim Boot via
  /// _applyPendingOpsToState wieder sichtbar.
  List<LoggedMeal> _cacheableLoggedMeals() {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: MealsSync.loggedMealsWindowDays));
    return loggedMeals
        .where((m) => !m.loggedAt.isBefore(cutoff))
        .toList(growable: false);
  }

  void _cacheLifetimeStats() {
    unawaited(_cache?.writeLifetimeStats(lifetimeStats) ?? Future<void>.value());
  }

  // Write-Through fuer die Offline-Slots (DATA-7): jede lokale Mutation
  // spiegelt sich sofort in den Cache, damit ein Kaltstart ohne Netz den
  // letzten Stand zeigt. Fire-and-forget — ein Cache-Write darf nie den
  // UI-Pfad blockieren. Gefiltert auf das Boot-Fenster (s.
  // _cacheableLoggedMeals) — Alt-Tage blaehen den Cache nicht auf.
  void _cacheLoggedMeals() {
    unawaited(_cache?.writeLoggedMeals(_cacheableLoggedMeals()) ??
        Future<void>.value());
  }

  void _cacheFavorites() {
    unawaited(_cache?.writeFavorites(favorites) ?? Future<void>.value());
  }

  void _cacheWeightLog() {
    unawaited(_cache?.writeWeightLog(weightLog) ?? Future<void>.value());
  }

  void _persistOutbox() {
    unawaited(_cache?.writeOutbox(_outbox) ?? Future<void>.value());
  }

  void _persistPendingStatsDeltas() {
    unawaited(_cache?.writePendingStatsDeltas(
          meals: _pendingMealsDelta,
          weightLogs: _pendingWeightLogsDelta,
        ) ??
        Future<void>.value());
  }

  // --- Lifetime-Stats-Deltas ------------------------------------------------

  void _queueStatsDelta({
    int meals = 0,
    int weightLogs = 0,
  }) {
    if (sync == null) return;
    _pendingMealsDelta += meals;
    _pendingWeightLogsDelta += weightLogs;
    // Pendende Deltas kill-sicher machen (DATA-7): ein App-Kill im Debounce-
    // Fenster oder nach fehlgeschlagenem Flush verliert sie nicht mehr — der
    // naechste Boot hydriert und flusht sie nach.
    _persistPendingStatsDeltas();
    _cacheLifetimeStats();
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_flushStatsDelta());
    });
  }

  Future<void> _flushStatsDelta() async {
    final s = sync;
    if (s == null) return;
    if (_statsFlushInFlight) return;
    final meals = _pendingMealsDelta;
    final weightLogs = _pendingWeightLogsDelta;
    if (meals == 0 && weightLogs == 0) return;
    _pendingMealsDelta = 0;
    _pendingWeightLogsDelta = 0;
    // In-Flight-Stand sofort persistieren: ein Kill WAEHREND des RPCs zaehlt
    // die Deltas schlimmstenfalls nicht — besser als ein Doppel-Increment
    // beim naechsten Boot (der Server ADDIERT, ein Replay eines bereits
    // verbuchten Deltas wuerde die Lebenszeit-Zaehler permanent verfaelschen).
    _persistPendingStatsDeltas();
    _statsFlushInFlight = true;
    try {
      final fresh = await s.lifetimeStats.increment(
        meals: meals,
        weightLogs: weightLogs,
      );
      if (!_disposed) {
        _mutate(() {
          lifetimeStats = fresh;
        });
      }
      _cacheLifetimeStats();
      _onSyncSuccess();
    } catch (e, st) {
      // DATA-7: kein roter Fehler-Toast, kein Rollback — die Deltas gehen
      // zurueck in die (persistierte) Queue und laufen ueber die Retry-Pfade.
      dev.log('Statistik-Sync failed — Deltas bleiben gequeued',
          error: e, name: 'eatova_sync');
      unawaited(CrashReporter.capture(e, st, context: 'lifetime-stats-flush'));
      _pendingMealsDelta += meals;
      _pendingWeightLogsDelta += weightLogs;
      _persistPendingStatsDeltas();
      if (!_disposed) {
        _notifyQueued(e);
        _scheduleOutboxRetry();
      }
    } finally {
      _statsFlushInFlight = false;
    }
  }

  /// Schreibt ausstehende debounced Writes sofort weg (App-Backgrounding)
  /// und spielt liegengebliebene Outbox-Ops nach.
  void flushPendingWrites() {
    final s = sync;
    if (s == null) return;
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce = null;
    unawaited(_flushStatsDelta());
    unawaited(_replayOutbox());
  }
}
