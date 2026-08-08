part of 'home_store.dart';

/// Mindestalter einer Op, bevor ein aufgebrauchtes Versuchs-Budget sie
/// verwerfen darf (Review 2026-08-08, A4).
///
/// [SyncOp.attempts] zaehlt Durchlaeufe, nicht Zeit — und Durchlaeufe kommen
/// nicht nur vom Backoff-Timer, sondern auch von Boot, `_onSyncSuccess` und
/// [flushPendingWrites]. Letzteres feuert bei `paused|hidden|detached` UND bei
/// `resumed`; Flutter sendet `inactive -> hidden -> paused` beim Wegschalten
/// und `hidden -> inactive -> resumed` zurueck, ein einziger App-Wechsel sind
/// also bis zu VIER Durchlaeufe. Drei, vier Wechsel zwischen Eatova und
/// WhatsApp waehrend eines fuenfminuetigen Server-Ausfalls haben so das ganze
/// Budget in Sekunden verbrannt und eine gueltige Mahlzeit dauerhaft
/// verworfen.
///
/// Deshalb ist das Budget ab jetzt eine UND-Bedingung: verworfen wird erst,
/// wenn die Versuche aufgebraucht sind UND die Op seit mindestens 24 h in der
/// Queue liegt. Lifecycle-Churn kann den Zaehler weiterhin hochtreiben — er
/// kann damit aber nichts mehr wegwerfen, weil die Wanduhr nicht mitspielt.
/// Unberuehrt bleibt der SOFORT-Verwurf aus dem Fehler selbst (Gift-Op,
/// korrupte Payload): der haengt nicht am Budget und braucht kein Alter.
///
/// Warum 24 h: das ist laenger als jeder Server-Ausfall, den ein Retry
/// ueberdauern soll, und kurz genug, dass eine wirklich unschreibbare Op nicht
/// wochenlang Akku und Traffic frisst.
const Duration kOutboxMinAgeBeforeDrop = Duration(hours: 24);

/// Die Payload einer Outbox-Op ist nicht lesbar (Review 2026-08-08, A8).
///
/// Erreichbar, weil [SyncOp.tryFromJson] eine Op mit nicht-Map-Payload BEHAELT
/// und `{}` einsetzt — die typisierten Zugriffe (`op.meal` & Co.) liefern dann
/// null. Frueher kehrte `_performOp` in diesem Fall einfach frueh zurueck, und
/// der Replay-Loop verbuchte das als Zustellung: `anySuccess = true`, Op
/// entfernt, Queue persistiert. Der einzige Verlustpfad ohne Snack, ohne
/// Breadcrumb, ohne Crash-Report. Jetzt ist es ein Wurf, der im selben
/// Verwurfs-Pfad landet wie eine Gift-Op.
///
/// [toString] traegt bewusst NUR das Op-Kind — die Payload selbst enthaelt
/// Mahlzeiten-Namen und Gewichte, also Gesundheitsdaten (Regel dokumentiert in
/// crash_reporter.dart), und dieses Objekt geht an den CrashReporter.
class _CorruptOpPayload implements Exception {
  const _CorruptOpPayload(this.kind);

  final SyncOpKind kind;

  @override
  String toString() => 'CorruptOpPayload(${kind.name})';
}

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

  /// Wie [_syncHintShown], aber fuer den SCHWEREN Fall: die Outbox hat Ops
  /// endgueltig verworfen (Gift-Op, aufgebrauchtes Versuchs-Budget oder
  /// Queue-Cap). Auch das wird pro Episode nur EINMAL gemeldet und beim
  /// naechsten Sync-Erfolg zurueckgesetzt.
  bool _outboxLossNotified = false;

  /// Entitaeten, deren Op endgueltig verworfen wurde (Review 2026-08-08, A6).
  ///
  /// Sie sind serverseitig moeglicherweise gar nicht vorhanden, lokal aber
  /// weiterhin sichtbar. Ein spaeterer Live-Write auf so eine Entitaet waere
  /// fuer Mahlzeiten ein PATCH — und ein PATCH ohne Treffer ist ein 204, also
  /// kein Fehler: [_onSyncSuccess] feuerte, der Nutzer sah nichts, und die
  /// Mahlzeit existierte weiterhin nicht. Deshalb laufen Writes auf diese
  /// Entitaeten ueber die Outbox, wo jede Op ein voller Upsert auf die
  /// Client-UUID ist ([_syncOrQueue]) — das REPARIERT die Entitaet, statt sie
  /// (die Alternative) aus dem lokalen Zustand zu loeschen.
  ///
  /// Bewusst NICHT persistiert: nach einem Kaltstart ersetzt der Server-Load
  /// die Mahlzeitenliste ohnehin komplett, die verwaiste Zeile ist dann aus
  /// dem Zustand verschwunden und es gibt nichts mehr zu reparieren. Der
  /// Merker gilt genau fuer die Sitzung, in der der Verlust gemeldet wurde.
  final Set<String> _orphanedEntities = <String>{};

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
  ///
  /// Dasselbe gilt fuer Entitaeten, deren Op einmal VERWORFEN wurde
  /// ([_orphanedEntities], A6): auch die existieren serverseitig womoeglich
  /// nicht, und der Live-Pfad (PATCH auf 0 Zeilen = 204 = „Erfolg") wuerde das
  /// nie bemerken.
  void _syncOrQueue(
    String operation,
    Future<void> Function() action,
    SyncOp Function() buildOp,
  ) {
    if (sync == null) return;
    final op = buildOp();
    if (_orphanedEntities.contains(op.entityKey) ||
        _outbox.any((o) => o.entityKey == op.entityKey)) {
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
    // Cap NUR ausserhalb eines laufenden Replays: der Replay-Loop laeuft ueber
    // Indizes: ein Kopf-Trim wuerde seinen Cursor unter ihm wegziehen. Die
    // Queue kann waehrend eines Replays hoechstens um die paar Ops ueber den
    // Cap wachsen, die der User in dieser Zeit erzeugt — der naechste Enqueue
    // danach zieht sie wieder gerade.
    if (!_outboxReplayInFlight) {
      final capped = capOutbox(_outbox);
      if (capped.dropped.isNotEmpty) {
        dev.log(
            'Outbox-Cap erreicht: ${capped.dropped.length} aelteste Op(s) '
            'verworfen (Queue > $kOutboxMaxOps)',
            name: 'eatova_sync');
        // Nur technische Angaben ins Reporting — NIE op.payload (Mahlzeiten,
        // Gewichte = Gesundheitsdaten, s. crash_reporter.dart).
        CrashReporter.breadcrumb(
            'outbox-cap: ${capped.dropped.length} ops dropped');
        _outbox = capped.queue;
        _notifyOutboxLoss();
      }
    }
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

  /// Meldet ENDGUELTIG verworfene Ops — anders als [_notifyQueued] ist das
  /// echter Datenverlust und keine Warteschleife. Der Text kommt aus dem puren
  /// Mapping und traegt bewusst KEINE technischen Details (kein SQLSTATE, kein
  /// Tabellen-/Constraint-Name, kein Exception-Typ); die Roh-Exception geht
  /// nur an dev.log + CrashReporter. Einmal pro Episode.
  void _notifyOutboxLoss() {
    if (_disposed || _outboxLossNotified) return;
    _outboxLossNotified = true;
    _emitSnack(
      outboxLossHint,
      icon: Icons.sync_problem_rounded,
      accent: danger,
      duration: kSnackError,
    );
  }

  /// Nach einem erfolgreichen Sync-Write: Fehler-Episode beenden, Backoff
  /// zuruecksetzen und liegengebliebene Ops direkt nachspielen.
  void _onSyncSuccess() {
    if (_disposed) return;
    _syncHintShown = false;
    _outboxLossNotified = false;
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
  ///
  /// Fehlschlaege werden ueber [_verdictFor] (= [classifyOutboxFailure] plus
  /// die beiden zustandsabhaengigen Regeln aus dem Review 2026-08-08)
  /// einsortiert:
  ///  * [OutboxVerdict.drop] — die Op wird endgueltig verworfen (sonst wuerde
  ///    sie ewig retryt und, weil [_syncOrQueue] ihre Entitaet vom Server
  ///    abschneidet, diese Entitaet dauerhaft blockieren). Ihre Entitaet
  ///    landet dabei in [_orphanedEntities].
  ///  * [OutboxVerdict.retryCounted] — bleibt liegen, verbraucht aber einen
  ///    Zustellversuch.
  ///  * [OutboxVerdict.retryFree] — bleibt liegen, ohne Budget zu verbrauchen
  ///    (Netzfehler; offline duerfen Boot + Flush + Timer nicht das Budget
  ///    leerlaufen lassen).
  Future<void> _replayOutbox() async {
    final s = sync;
    if (s == null || _outboxReplayInFlight || _outbox.isEmpty) return;
    _outboxReplayInFlight = true;
    final blocked = <String>{};
    var anySuccess = false;
    var anyDropped = false;
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
          // Die Liste kann sich waehrend des await geaendert haben (ein
          // appendOnly-Enqueue ersetzt sie) — deshalb die Op ueber Identitaet
          // wiederfinden statt dem Index zu trauen.
          final at = _outbox.indexWhere((o) => identical(o, op));
          final verdict = _verdictFor(e, op);
          if (verdict == OutboxVerdict.drop) {
            dev.log(
                'Outbox-Replay: ${op.kind.name} endgueltig verworfen '
                '(Versuch ${op.attempts + 1})',
                error: e,
                name: 'eatova_sync');
            // NUR Kind + Roh-Exception ins Reporting — niemals op.payload:
            // der traegt Mahlzeiten-Namen und Gewichte, also Gesundheitsdaten
            // (Regel dokumentiert in crash_reporter.dart).
            unawaited(CrashReporter.capture(e, st,
                context: 'outbox-drop-${op.kind.name}'));
            anyDropped = true;
            // A6: die Entitaet ist ab jetzt potenziell verwaist (lokal da,
            // serverseitig nicht). Kuenftige Writes muessen deshalb ueber die
            // Outbox laufen, wo sie als voller Upsert ankommen.
            _orphanedEntities.add(op.entityKey);
            if (at >= 0) {
              _outbox = [..._outbox]..removeAt(at);
              _persistOutbox();
              // Die nachgerueckte Op steht jetzt an dieser Position und muss
              // als naechste geprueft werden.
              i = at;
            } else {
              i++;
            }
            continue;
          }
          if (verdict == OutboxVerdict.retryCounted && at >= 0) {
            _outbox = [..._outbox]..[at] = op.incrementAttempt();
            _persistOutbox();
          }
          dev.log('Outbox-Replay: ${op.kind.name} bleibt liegen',
              error: e, name: 'eatova_sync');
          unawaited(CrashReporter.capture(e, st,
              context: 'outbox-replay-${op.kind.name}'));
          blocked.add(op.entityKey);
          i++;
          continue;
        }
        anySuccess = true;
        // Die Entitaet ist wieder serverseitig vorhanden — der Live-Pfad darf
        // sie wieder anfassen (A6).
        _orphanedEntities.remove(op.entityKey);
        _outbox = [..._outbox]..removeAt(i);
        _persistOutbox();
      }
    } finally {
      _outboxReplayInFlight = false;
    }
    if (_disposed) return;
    if (anyDropped) _notifyOutboxLoss();
    // Eine leere Queue ist „fertig", auch wenn Ops blockiert WAREN: sie sind
    // dann alle verworfen worden, und ein Backoff-Timer haette nichts mehr zu
    // tun.
    if (blocked.isEmpty || _outbox.isEmpty) {
      _outboxRetryAttempt = 0;
      _outboxRetryTimer?.cancel();
      if (anySuccess) {
        _syncHintShown = false;
        _outboxLossNotified = false;
      }
    } else {
      _scheduleOutboxRetry();
    }
  }

  /// Entscheidet, was mit einer fehlgeschlagenen Op passiert. Duennes Vorwerk
  /// um [classifyOutboxFailure] — die reine Klassifizierung bleibt dort, hier
  /// kommen die zwei Regeln dazu, die den Op-Zustand brauchen:
  ///
  ///  * A8 — eine nicht lesbare Payload ist unzustellbar. Sie laeuft ueber den
  ///    VERWURFS-Pfad (Snack + Crash-Report), nicht mehr ueber den Erfolgspfad.
  ///  * A4 — ein Verwurf, der nur am aufgebrauchten Versuchs-Budget haengt,
  ///    braucht zusaetzlich Wanduhrzeit ([kOutboxMinAgeBeforeDrop]). Ob das
  ///    Budget der Grund war, verraet die Gegenprobe mit `attempts: 0`: sagt
  ///    die Klassifizierung auch ohne verbrauchtes Budget „drop", kam der
  ///    Verwurf aus dem Fehler selbst (Gift-Op) und bleibt sofort wirksam.
  OutboxVerdict _verdictFor(Object error, SyncOp op) {
    if (error is _CorruptOpPayload) return OutboxVerdict.drop;
    final verdict = classifyOutboxFailure(error, op.attempts, kind: op.kind);
    if (verdict != OutboxVerdict.drop) return verdict;
    if (classifyOutboxFailure(error, 0, kind: op.kind) == OutboxVerdict.drop) {
      return OutboxVerdict.drop;
    }
    return DateTime.now().difference(op.queuedAt) >= kOutboxMinAgeBeforeDrop
        ? OutboxVerdict.drop
        : OutboxVerdict.retryCounted;
  }

  /// Fuehrt EINE Outbox-Op gegen den Server aus. Wirft bei Sync-Fehler (der
  /// Replay-Loop behaelt die Op dann) und bei nicht lesbarer Payload
  /// ([_CorruptOpPayload] — die Op wird dann verworfen, A8). Nachgelagerte
  /// Zaehler laufen wie im jeweiligen Online-Erfolgspfad.
  Future<void> _performOp(EatovaSync s, SyncOp op) async {
    switch (op.kind) {
      case SyncOpKind.mealInsert:
        final meal = op.meal;
        if (meal == null) throw _CorruptOpPayload(op.kind);
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
        if (meal == null) throw _CorruptOpPayload(op.kind);
        await s.meals.insertLoggedMeal(meal);
      case SyncOpKind.mealDelete:
        await s.meals.deleteLoggedMeal(op.entityId);
      case SyncOpKind.weightInsert:
        final kg = op.weightKg;
        final ts = op.recordedAt;
        if (kg == null || ts == null) throw _CorruptOpPayload(op.kind);
        await s.tracking.insertWeight(kg, ts, id: op.entityId);
        _queueStatsDelta(weightLogs: 1);
      case SyncOpKind.favoriteUpsert:
        final fav = op.favorite;
        if (fav == null) throw _CorruptOpPayload(op.kind);
        await s.meals.upsertFavorite(fav);
      case SyncOpKind.favoriteDelete:
        await s.meals.deleteFavorite(op.entityId);
      case SyncOpKind.recipeUpsert:
        final recipe = op.recipe;
        if (recipe == null) throw _CorruptOpPayload(op.kind);
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
    // D9: geplante Erinnerungen liegen im OS, nicht in unserem Cache — ohne
    // diesen Aufruf feuern sie nach der Löschung weiter, während der Dialog
    // „unwiderruflich gelöscht" verspricht.
    await notificationService.cancelAll();
    // B3: derselbe Grund — der Health-Zustand lebt im Service-Objekt, nicht im
    // namensraumgetrennten Cache, und überlebt sonst die Kontolöschung.
    _resetHealthConnection();
    // Kein preserveOutbox: das Konto ist weg, es gibt kein Ziel mehr, gegen
    // das die Ops je zugestellt werden könnten.
    await _clearCache();
    return true;
  }

  /// Räumt den lokalen PII-Cache (Profil, Lifetime-Stats, Tagebuch,
  /// Favoriten, Gewicht, Notification-Flag) beim Sign-Out — anders als
  /// [deleteAccount] OHNE Server-RPC. Ohne diesen Schritt überlebten
  /// Gesundheits-/Profildaten den Logout in den SharedPreferences (Audit
  /// 2026-06-09, M-1). Muss VOR dem eigentlichen `signOut()` laufen, solange
  /// der User noch der aktuelle ist — der defensive Pfad braucht dessen ID.
  ///
  /// Ungesyncte Writes werden dabei NICHT mehr mitvernichtet (Review
  /// 2026-08-08, A2). Vorher hieß Ausloggen: sechs im Flugzeug geloggte
  /// Mahlzeiten sind weg — nicht eingereiht, nicht wiederherstellbar, nie
  /// erwähnt. Jetzt läuft zuerst ein Zustellversuch; bleibt danach etwas
  /// liegen, überlebt die Outbox (und mit ihr die pendenden Stats-Deltas) den
  /// Logout und spielt beim nächsten Login desselben Users nach.
  ///
  /// Die alte Begründung (PII darf den Logout nicht überleben) trägt für
  /// diesen einen Slot nicht mehr: der Cache ist seit `7f895f9`
  /// AES-256-GCM-verschlüsselt, und JEDER Slot-Schlüssel trägt die User-ID
  /// (`eatova.v1.outbox.<uid>`, siehe local_cache.dart) — ein anderer Nutzer
  /// auf demselben Gerät liest seinen eigenen, leeren Namensraum, nie diesen.
  Future<void> signOutCleanup() async {
    // Zustellversuch VOR dem Verwerfen: online ist die Queue danach leer und
    // es bleibt beim vollständigen Räumen wie bisher.
    await _replayOutbox();
    // Nur was die Zustellung nicht losgeworden ist, rechtfertigt einen
    // überlebenden Slot. Maßgeblich ist die Queue des Stores — sie ist der
    // Spiegel des persistierten Blobs, sobald der Boot gelaufen ist.
    final remaining = _outbox.length;
    // D9: die geplanten Erinnerungen sind OS-Zustand und kennen keinen User.
    // Ohne diesen Aufruf zeigt das Familien-Tablet der neu angemeldeten
    // Person abends die Streak-Erinnerung der vorherigen.
    await notificationService.cancelAll();
    // B3: der Health-Zustand ist prozesslokal und kennt keinen User. Ohne
    // diesen Aufruf zeigt Bs Profilkarte weiter As „Synchronisiert".
    _resetHealthConnection();
    await _clearCache(preserveOutbox: remaining > 0);
  }

  /// Trennt Apple Health beim Nutzerwechsel — Service UND Store-Feld.
  ///
  /// Beides ist nötig: `health.reset()` räumt Verifier und gecachtes
  /// `authState` im Service, `healthAuthState` ist die Kopie, die die
  /// Profilkarte rendert. Ohne die zweite Zuweisung bliebe die grüne
  /// „Synchronisiert"-Karte bis zum nächsten `refreshHealthSteps()` stehen.
  void _resetHealthConnection() {
    health.reset();
    healthAuthState = health.authState;
  }

  /// Löscht den lokalen Cache. Bevorzugt den bereits gebooteten [_cache], im
  /// Test den injizierten [debugCache]; kommt der Logout vor dem Boot-Ende
  /// (noch kein _cache), wird er defensiv aus der aktuellen Session-User-ID
  /// gebaut, damit auch dann nichts liegen bleibt.
  ///
  /// [preserveOutbox] hält `_outboxKey`/`_pendingStatsKey` zurück (A2) — alles
  /// andere fällt so oder so.
  Future<void> _clearCache({bool preserveOutbox = false}) async {
    final cache = _cache ?? debugCache ?? await _resolveCacheForCurrentUser();
    await cache?.clear(preserveOutbox: preserveOutbox);
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
  // Entprellt (G9b): eine Fuenfer-Serie verschluesselte den ganzen Blob sonst
  // fuenfmal — bei 210 Mahlzeiten sind das 5x91 ms AES-GCM. Ausstehende Writes
  // gehen nicht verloren: flushPendingWrites() haengt am Lifecycle und
  // erzwingt sie, clear() verwirft sie bewusst (sonst schriebe ein laufender
  // Timer die beim Logout geraeumte PII zurueck).
  void _cacheLoggedMeals() {
    _cache?.writeLoggedMealsDebounced(_cacheableLoggedMeals());
  }

  void _cacheFavorites() {
    _cache?.writeFavoritesDebounced(favorites);
  }

  void _cacheWeightLog() {
    _cache?.writeWeightLogDebounced(weightLog);
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
    // Vor dem sync-Guard: die entprellten Cache-Writes (G9b) haengen nicht am
    // Sync-Client. Ohne diese Zeile verliert ein Backgrounding waehrend des
    // 400-ms-Fensters den letzten Tagebuch-Stand.
    unawaited(_cache?.flush() ?? Future<void>.value());
    final s = sync;
    if (s == null) return;
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce = null;
    unawaited(_flushStatsDelta());
    unawaited(_replayOutbox());
  }
}
