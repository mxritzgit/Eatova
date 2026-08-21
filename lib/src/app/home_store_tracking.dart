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

  /// Tages-Aktivitaet: Schritte + daraus geschaetzte "Verbrannt"-kcal pro
  /// lokalem Kalendertag (Key: [localDayKey]).
  ///
  /// Der HEUTIGE Eintrag wird bei jedem verifizierten Health-Refresh
  /// upsertet — der letzte Refresh eines Tages IST damit sein Endwert, und
  /// die VERBRANNT-Kachel eines Archivtags zeigt ihn statt einer erfundenen
  /// 0 ([burnedKcalForFoodDate]). Vergangene Tage ohne (oder mit womoeglich
  /// unvollstaendigem) Eintrag holt [_maybeBackfillDailyActivity] einmal pro
  /// Sitzung aus dem Health-Store nach — der kennt die volle Historie.
  ///
  /// Bei Mutation wird die Map ERSETZT statt veraendert: die Slice-Selectors
  /// der Schale vergleichen per Identitaet (G11-Muster, s. eatova_home_page).
  Map<String, ({int steps, int kcal})> dailyActivity =
      <String, ({int steps, int kcal})>{};

  /// Tage, fuer die diese Sitzung schon einen Backfill versucht hat — ein
  /// Archivtag soll nicht bei jedem Antippen eine neue Health-Query kosten.
  final Set<String> _dailyActivityBackfillAttempted = <String>{};

  /// Aeltere Eintraege fallen beim Upsert aus der Map — laenger als ein Jahr
  /// zurueckblaettern ist den dauerhaft wachsenden Blob nicht wert.
  static const Duration _dailyActivityRetention = Duration(days: 400);

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
        // Tageswert festschreiben — der Tag des SNAPSHOTS, nicht "heute":
        // laeuft der Refresh in der Mitternachts-Sekunde, gehoeren die
        // Schritte noch zum Abfrage-Zeitpunkt.
        _recordDailyActivity(snapshot.fetchedAt, snapshot.stepsToday);
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

  /// "Verbrannt"-kcal fuer [date]: heute live aus [dailySteps] (wie bisher),
  /// fuer vergangene Tage der festgeschriebene Tageswert aus [dailyActivity].
  /// 0 heisst "kein Eintrag" — die Kachel zeigt dann „—" statt einer Zahl.
  ///
  /// Jeder Schritt zaehlt (Kalorien-Review 2026-08-21): das Tagesziel rechnet
  /// mit einer PAL-Leiter OHNE Gehen (`ActivityLevel.palFactor`), deshalb ist
  /// die volle Schrittsumme hier keine Doppelzaehlung.
  int burnedKcalForFoodDate(DateTime date) {
    if (_isSameFoodDate(date, clock.now())) {
      return estimateKcalBurnedFromSteps(
        steps: dailySteps,
        weightKg: profile.weightKg,
        heightCm: profile.heightCm,
        sex: profile.sex,
      );
    }
    return dailyActivity[localDayKey(date)]?.kcal ?? 0;
  }

  /// Upsert des Kalendertags von [day] mit [steps]; die kcal werden mit dem
  /// AKTUELLEN Profil eingefroren (das damalige Gewicht laege hoechstens
  /// wenige kg daneben — die Schaetzung selbst ist groeber). Muss innerhalb
  /// eines _mutate-Blocks laufen (kein eigener Notify); der Cache-Write ist
  /// fire-and-forget wie bei allen Spiegel-Slots.
  void _recordDailyActivity(DateTime day, int steps) {
    if (steps <= 0) return;
    final key = localDayKey(day);
    final kcal = estimateKcalBurnedFromSteps(
      steps: steps,
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
      sex: profile.sex,
    );
    // Unveraendert -> raus, OHNE die Map zu ersetzen: die Slice-Selectors
    // vergleichen per Identitaet, und ein Resume ohne neue Schritte darf
    // weder einen Heute-Tab-Rebuild noch einen AES-GCM-Cache-Write kosten
    // (Perf-Guard: home_page_rebuild_test "ein Health-Refresh baut den
    // Heute-Tab nicht mehr neu").
    if (dailyActivity[key] == (steps: steps, kcal: kcal)) return;
    // YYYY-MM-DD vergleicht lexikografisch chronologisch — der Cutoff ist
    // ein String-Vergleich, kein Datums-Parsing.
    final cutoff = localDayKey(clock.now().subtract(_dailyActivityRetention));
    dailyActivity = <String, ({int steps, int kcal})>{
      for (final e in dailyActivity.entries)
        if (e.key.compareTo(cutoff) >= 0) e.key: e.value,
      key: (steps: steps, kcal: kcal),
    };
    unawaited(_cache?.writeDailyActivity(dailyActivity) ?? Future<void>.value());
  }

  /// Holt fuer einen VERGANGENEN Tag die volle Tagessumme aus dem Health-
  /// Store nach — einmal pro Tag und Sitzung, angestossen von
  /// [HomeStore.setFoodDate]. Auch ein VORHANDENER Eintrag wird einmal
  /// aufgefrischt: er kann vom letzten Refresh VOR Tagesende stammen, die
  /// Health-Historie kennt dagegen die volle Summe. Liefert der Service
  /// nichts (Android/Noop, keine Berechtigung, echter Ruhetag), bleibt der
  /// gespeicherte Stand unangetastet.
  Future<void> _maybeBackfillDailyActivity(DateTime day) async {
    if (_disposed || _isSameFoodDate(day, clock.now())) return;
    final key = localDayKey(day);
    if (!_dailyActivityBackfillAttempted.add(key)) return;
    final steps = await health.readStepsOnDay(day);
    if (_disposed || steps == null || steps <= 0) return;
    _mutate(() => _recordDailyActivity(day, steps));
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
    // Locale-bewusst ueber NumberFormat (Paket 7/Nachzuegler-Muster, s.
    // target_bmi_hint.dart): unter `de` byte-gleich zum vorherigen
    // `toStringAsFixed(1).replaceAll('.', ',')` (CLDR liefert fuer `de`
    // ebenfalls das Komma), unter `en` jetzt der Punkt.
    final label = NumberFormat('0.0', _l10n.localeName).format(kg);
    _emitSnack(
      _l10n.commonHealthWeightOfferMessage(label),
      icon: Icons.monitor_weight_outlined,
      tone: SnackTone.positive,
      // Unaufgefordertes Angebot beim Resume/Kaltstart: etwas laenger sichtbar
      // als Standard-Action-Snacks (kSnackAction), damit der Tap realistisch
      // treffbar ist, bevor der Toast von selbst verschwindet.
      duration: const Duration(milliseconds: 3500),
      action: SnackBarAction(
        label: _l10n.commonHealthWeightOfferAction,
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
    if (sync == null) return;
    // Client-UUID fuer die Server-Zeile: Live-Write und ein spaeterer
    // Outbox-Retry teilen dieselbe id -> Upsert statt Insert, ein Retry nach
    // unklarem Timeout erzeugt kein Duplikat (DATA-7-Idempotenz).
    final rowId = uuidV4();
    // Kein Rollback: das Gewicht bleibt geloggt (damit bleibt auch der
    // Health-Import-Dedup-Marker korrekt gesetzt) und wird per Outbox
    // nachgeholt. Luecke B: die Op liegt dafuer schon VOR dem Write in der
    // Queue — ein haengender Request erzeugte sonst nie eine.
    _syncOrQueue(
      'Gewicht',
      () => sync!.tracking.insertWeight(kg, ts, id: rowId),
      () => SyncOp.weightInsert(id: rowId, weightKg: kg, recordedAt: ts),
      // Wie beim Mahlzeiten-Insert: das Lifetime-Delta bucht sonst _performOp
      // beim Nachspielen.
      onDelivered: () => _queueStatsDelta(weightLogs: 1),
    );
  }

  // --- Streak ---------------------------------------------------------------

  /// Schreibt einen Logging-Tag serverseitig in die Streak
  /// (record_tracking_day, idempotent pro Tag) und adoptiert die frische
  /// Server-Zeile. Default ist "heute"; ein Outbox-Replay uebergibt den Tag
  /// der nachgeholten Mahlzeit.
  ///
  /// **Zweitpruefung 2026-08-10:** Fehler blieben hier bis eben still — und
  /// das war die letzte Nutzer-Groesse mit NULL Sicherungsnetzen. Der
  /// Kommentar behauptete, der optimistische lokale Stand gelte „bis zum
  /// naechsten Load/Log weiter"; tatsaechlich hielt er keine Sekunde: der auf
  /// 600 ms entprellte [_flushStatsDelta] adoptierte gleich danach die frische
  /// Serverzeile, die den Tag naturgemaess nicht kennt, und
  /// [_cacheLifetimeStats] schrieb den Verlust in den Cache. Der Nutzer hatte
  /// geloggt, die Mahlzeit war angekommen — und seine Streak war trotzdem
  /// gerissen, ohne Hinweis und ohne jede Stelle, die es je repariert haette.
  /// Jetzt landet der Tag in derselben persistierten Outbox wie jeder andere
  /// Write ([_queueTrackingDay]).
  @override
  void _recordTrackingDay({DateTime? day}) {
    final s = sync;
    if (s == null) return;
    final tag = day ?? clock.now();
    s.lifetimeStats.recordTrackingDay(tag).then((fresh) {
      if (_disposed) return;
      // Eine aeltere, gescheiterte Op fuer denselben Tag ist damit erledigt.
      _clearQueuedTrackingDay(localDayKey(tag));
      _mutate(() {
        lifetimeStats = fresh;
        // Andere, noch nicht zugestellte Tage bleiben sichtbar — die gerade
        // gelesene Serverzeile kennt sie nicht.
        _overlayPendingTrackingDays();
      });
      _cacheLifetimeStats();
    }).catchError((Object e, StackTrace st) {
      dev.log('recordTrackingDay failed — Tag bleibt in der Outbox liegen',
          error: e, name: 'home_store');
      unawaited(CrashReporter.capture(e, st, context: 'record-tracking-day'));
      _queueTrackingDay(tag);
    });
  }
}
