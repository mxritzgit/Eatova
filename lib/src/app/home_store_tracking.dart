part of 'home_store.dart';

/// Tracking-Part von [HomeStore]: Gewichts-Logging (manuell + Apple-Health-
/// Import), der Health-Snapshot (Schritte) und der serverseitige Streak-Tag
/// (record_tracking_day). Reine Datei-Aufteilung — Verhalten und Member sind
/// 1:1 aus home_store.dart uebernommen.
mixin _HomeStoreTrackingPart on _HomeStoreBase, _HomeStoreSyncPart {
  // healthAuthState liegt in _HomeStoreBase neben dailySteps: der Logout-Pfad
  // in _HomeStoreSyncPart muss es beim Nutzerwechsel zuruecksetzen (B3), und
  // dieser Mixin haengt VON Sync ab, nicht umgekehrt — Sync saehe ein Feld
  // hier also nie.
  DateTime? healthLastFetch;
  bool healthSyncing = false;

  /// In-Memory-Dedup fuer das HealthKit-Gewichts-Angebot: refreshHealthSteps()
  /// laeuft bei Kaltstart UND jedem App-Resume — ohne Dedup wuerde der
  /// „uebernehmen?"-Snack bei jedem Resume erneut aufpoppen. Merkt sich den
  /// zuletzt ANGEBOTENEN Wert; bewusst nicht persistiert (nach App-Neustart
  /// darf einmal erneut angeboten werden).
  double? _lastOfferedHealthWeightKg;

  // --- Health ---------------------------------------------------------------

  Future<void> connectHealth() async {
    if (_disposed) return;
    _mutate(() => healthSyncing = true);
    final state = await health.requestAuthorization();
    if (_disposed) return;
    _mutate(() => healthAuthState = state);
    if (state == HealthAuthState.granted) {
      await refreshHealthSteps();
    } else {
      _mutate(() => healthSyncing = false);
    }
  }

  Future<void> refreshHealthSteps() async {
    if (_disposed) return;
    _mutate(() => healthSyncing = true);
    final snapshot = await health.readSnapshot();
    if (_disposed) return;
    _mutate(() {
      healthSyncing = false;
      // B3 (Uebergabe W2-04): der Service verifiziert die Berechtigung bei
      // JEDEM Refresh neu und kann von granted auf unverified/denied
      // zurueckfallen. Den Zustand deshalb in BEIDEN Zweigen adoptieren statt
      // ihn nur bei Erfolg auf `granted` hochzustufen — sonst behauptet die
      // Profilkarte weiter „Synchronisiert", waehrend readSnapshot() dauerhaft
      // null liefert und der Ring mit 0 verbrannten kcal rechnet.
      healthAuthState = health.authState;
      if (snapshot != null) {
        dailySteps = snapshot.stepsToday;
        healthLastFetch = snapshot.fetchedAt;
      }
      // Kein `else { dailySteps = 0; }`: ein nicht-verifizierter Zustand
      // liefert seit B3 null statt „0 Schritte" — der zuletzt gemessene Wert
      // ist dann die bessere Auskunft als eine erfundene Null.
    });
    // Gewichts-Import-Pfad: das Snapshot-Gewicht nicht laenger wegwerfen,
    // sondern (dedupliziert) zum Uebernehmen anbieten.
    if (snapshot != null) {
      _maybeOfferHealthWeight(snapshot.latestWeightKg);
    }
  }

  /// Bietet ein aus Apple Health gelesenes Gewicht per Snack zum Uebernehmen
  /// an. Angeboten wird nur, wenn
  ///  * ueberhaupt ein Wert im Snapshot steckt,
  ///  * er sinnvoll vom letzten geloggten Gewicht abweicht (>= 0.1 kg) ODER
  ///    noch nie gewogen wurde,
  ///  * derselbe Wert nicht schon einmal angeboten wurde (In-Memory-Dedup,
  ///    siehe [_lastOfferedHealthWeightKg]).
  /// Nach einem Import greift die 0.1-kg-Schwelle von selbst, weil
  /// weightLog.latest dann == kg ist — kein erneutes Angebot.
  void _maybeOfferHealthWeight(double? kg) {
    if (_disposed || kg == null || kg <= 0) return;
    final lastLogged = weightLog.latest?.weightKg;
    if (lastLogged != null && (kg - lastLogged).abs() < 0.1) return;
    if (_lastOfferedHealthWeightKg == kg) return;
    _lastOfferedHealthWeightKg = kg;
    // Deutsche Formatierung: Komma, eine Nachkommastelle (z.B. "82,4").
    final label = kg.toStringAsFixed(1).replaceAll('.', ',');
    _emitSnack(
      'Apple Health: $label kg übernehmen?',
      icon: Icons.monitor_weight_outlined,
      tone: SnackTone.positive,
      // Unaufgefordertes Angebot beim Resume/Kaltstart: etwas laenger sichtbar
      // als Standard-Action-Snacks (kSnackAction), damit der Tap realistisch
      // treffbar ist, bevor der Toast von selbst verschwindet.
      duration: const Duration(milliseconds: 3500),
      action: SnackBarAction(
        label: 'Übernehmen',
        onPressed: () => importHealthWeight(kg),
      ),
    );
  }

  // --- Koerperdaten (Profil) ------------------------------------------------

  /// Manuelles Wiegen (User tippt den Wert ein): loggt lokal + synct + spiegelt
  /// den Wert per Write-Back nach HealthKit.
  void logWeight(double kg) => _logWeightInternal(kg, writeToHealth: true);

  /// Import AUS Apple Health (Tap auf die „Übernehmen"-Snack-Aktion): identisch
  /// zu [logWeight], aber OHNE `health.writeWeight` — der Wert stammt ja aus
  /// HealthKit, ein Write-Back wuerde dort ein Echo-Duplikat anlegen.
  void importHealthWeight(double kg) =>
      _logWeightInternal(kg, writeToHealth: false);

  /// Gemeinsamer Kern von [logWeight] und [importHealthWeight]. Die leichte
  /// Haptik laeuft bewusst in BEIDEN Pfaden: auch der Import wird durch einen
  /// User-Tap (Snack-Aktion) ausgeloest, die Bestaetigung ist also konsistent.
  void _logWeightInternal(double kg, {required bool writeToHealth}) {
    HapticFeedback.lightImpact();
    final ts = clock.now();
    _mutate(() {
      weightLog = weightLog.add(kg);
      lifetimeStats = lifetimeStats.incrementWeightLogs();
    });
    _cacheWeightLog();
    if (writeToHealth) {
      unawaited(health.writeWeight(kg, ts));
    }
    final s = sync;
    if (s == null) return;
    // Client-UUID fuer die Server-Zeile: Live-Write und ein spaeterer
    // Outbox-Retry teilen dieselbe id -> Upsert statt Insert, ein Retry nach
    // unklarem Timeout erzeugt kein Duplikat (DATA-7-Idempotenz).
    final rowId = uuidV4();
    s.tracking.insertWeight(kg, ts, id: rowId).then((_) {
      _queueStatsDelta(weightLogs: 1);
      _onSyncSuccess();
    }).catchError((Object e, StackTrace st) {
      // Kein Rollback mehr: das Gewicht bleibt geloggt (damit bleibt auch der
      // Health-Import-Dedup-Marker korrekt gesetzt) und wird per Outbox
      // nachgeholt.
      _handleSyncFailure(
        'Gewicht',
        e,
        st,
        SyncOp.weightInsert(id: rowId, weightKg: kg, recordedAt: ts),
      );
    });
  }

  // --- Streak ---------------------------------------------------------------

  /// Schreibt einen Logging-Tag serverseitig in die Streak
  /// (record_tracking_day, idempotent pro Tag) und adoptiert die frische
  /// Server-Zeile. Default ist "heute"; ein Outbox-Replay uebergibt den Tag
  /// der nachgeholten Mahlzeit. Fehler bleiben still — der optimistische
  /// lokale recordTrackedDay-Stand gilt dann bis zum naechsten Load/Log
  /// weiter.
  @override
  void _recordTrackingDay({DateTime? day}) {
    final s = sync;
    if (s == null) return;
    s.lifetimeStats.recordTrackingDay(day ?? clock.now()).then((fresh) {
      if (_disposed) return;
      _mutate(() => lifetimeStats = fresh);
      _cacheLifetimeStats();
    }).catchError((Object e, StackTrace st) {
      dev.log('recordTrackingDay failed', error: e, name: 'home_store');
      unawaited(CrashReporter.capture(e, st, context: 'record-tracking-day'));
    });
  }
}
