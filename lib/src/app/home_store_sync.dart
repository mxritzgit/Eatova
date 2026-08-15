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

/// Dasselbe fuer LOESCH-Ops ([SyncOp.isDelete]) — nur viel laenger, und ohne
/// die Ausnahme fuer den Sofort-Verwurf.
///
/// Ein Delete kennt keinen „strukturell unmoeglichen" Fehler: seine Payload ist
/// LEER, eine Datenverletzung (Klasse 22/23) kann sie gar nicht ausloesen, und
/// PGRST20x/404 beschreiben einen kalten Schema-Cache bzw. eine Route waehrend
/// eines Deploys — beides geht vorbei. Deshalb ist fuer Deletes JEDER
/// Server-Fehler behandelbar wie ein transienter, und begrenzt wird nur ueber
/// Zeit: verworfen wird erst, wenn [kOutboxDeleteMaxAttempts] aktive
/// Ablehnungen verbucht sind UND die Op seit mindestens dieser Spanne liegt.
///
/// Warum 7 Tage: laenger als jedes Migrations-/Ausfallfenster, das ein Retry
/// ueberdauern soll, und deutlich laenger als die 24 h der Schreib-Ops — der
/// Verlust ist hier ja der schwerere. Kuerzer als „unendlich" muss es sein,
/// siehe [kOutboxDeleteMaxAttempts]. Offline-Zeit kostet dabei nichts: ein
/// Netzfehler ist retryFree und laeuft nie in diese Pruefung.
const Duration kOutboxDeleteMinAge = Duration(days: 7);

/// So lange wartet ein Aufrufer hoechstens auf den Ausgang seines Writes,
/// bevor „liegt in der Warteschlange" gilt (Luecke E).
///
/// Es gibt kein Timeout auf Supabase-/PostgREST-Aufrufen (die Policies in
/// eatova_http.dart gelten nur fuer Meilisearch/OFF/analyze-meal) — ohne diese
/// Grenze bliebe die Erfolgsmeldung des Nutzers an einem haengenden Request
/// haengen und kaeme nie. Die Antwort ist auch nach Ablauf nicht falsch: die
/// Op liegt seit Luecke B VOR dem Write in der persistierten Queue, „wird noch
/// synchronisiert" stimmt also selbst dann, wenn der Request danach doch
/// ankommt (der Replay ist idempotent).
///
/// Bewusst 3 s: laenger als jeder gesunde Mobilfunk-Write, kurz genug, dass
/// eine Bestaetigung nicht als ausgeblieben empfunden wird.
const Duration kSyncDeliveryWindow = Duration(seconds: 3);

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

  /// Ob der persistierte Sync-Zustand (Outbox + Stats-Deltas) bereits in den
  /// Store uebernommen wurde. Bis dahin ist ein leeres [_outbox] KEINE Aussage
  /// ueber den Blob der Vorsession — [signOutCleanup] muss ihn dann ungesehen
  /// erhalten, sonst raeumt ein Logout in den ersten Sekunden nach App-Start
  /// nicht zugestellte Writes ohne Zustellversuch (A2-Restfenster). Bleibt
  /// auch nach einem GESCHEITERTEN Hydrationsversuch false: der Blob koennte
  /// intakt sein, nur lesbar war er gerade nicht.
  bool _syncStateHydrated = false;

  /// Luecke F: der Lesevorgang des Outbox-Slots hat GEWORFEN (nicht: der Slot
  /// war leer). Solange das gilt, ist der In-Memory-Stand keine gueltige
  /// Fassung des persistierten Blobs und darf ihn nicht ueberschreiben —
  /// [_persistOutbox] holt die Hydration stattdessen einmal nach.
  bool _outboxHydrationFailed = false;
  bool _outboxRepairInFlight = false;

  /// Dasselbe fuer den Deltas-Slot (W7b) — die zweite Haelfte desselben
  /// kill-sicheren Sync-Zustands, und derselbe Schaden:
  /// [_persistPendingStatsDeltas] schreibt den Slot IMMER komplett neu, ein
  /// verschluckter Lesefehler liesse ihn also bei 0 anfangen und die
  /// Lebenszeit-Zaehler blieben um die liegengebliebenen Mahlzeiten zu
  /// niedrig — genau der Schaden, den der Docstring von
  /// [LocalCache.readPendingStatsDeltasOrThrow] benennt. Bewusst dieselbe
  /// Mechanik wie oben (Merker + einmalige Nachhydration), kein zweiter,
  /// abweichender Weg.
  bool _statsHydrationFailed = false;
  bool _statsRepairInFlight = false;

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

  /// Wie [_outboxLossNotified], aber fuer den Verlust einer LOESCHUNG. Bewusst
  /// ein zweiter Merker: die beiden Meldungen sagen Gegenteiliges („etwas
  /// fehlt" vs. „etwas ist wieder da") und haben unterschiedliche Folgen fuer
  /// den Nutzer. Mit nur einem Merker haette die erste die zweite
  /// verschluckt — und die Mahlzeit waere kommentarlos wieder aufgetaucht.
  bool _outboxDeleteLossNotified = false;

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

  /// Entitaeten mit gerade LAUFENDEM Live-Write, samt der Op, die dafuer schon
  /// in der Queue liegt (Luecke B: Op zuerst, dann zustellen).
  ///
  /// Drei Aufgaben:
  ///  * [_syncOrQueue] unterscheidet damit „belegt, weil etwas gescheitert
  ///    ist" (Warteschlangen-Hinweis) von „belegt, weil gerade geschrieben
  ///    wird" (kein Hinweis — es ist nichts schiefgegangen).
  ///  * [_enqueueOp] haengt eine zaehlende Op nicht weg-koaleszieren zu lassen
  ///    (s. [_koaleszenzUnsicher]).
  ///  * [_replayOutbox] ueberspringt sie: sonst schriebe der Replay dieselbe
  ///    Zeile ein zweites Mal, waehrend der erste Write noch unterwegs ist —
  ///    und ein mealInsert zaehlte die Mahlzeit doppelt.
  ///
  /// Bewusst NICHT persistiert: nach einem Kaltstart laeuft kein Write mehr,
  /// und die Op liegt ohnehin in der persistierten Queue.
  final Map<String, SyncOp> _inFlightOps = <String, SyncOp>{};

  int _pendingMealsDelta = 0;
  int _pendingWeightLogsDelta = 0;

  /// Idempotenz-Schluessel des AKTUELL pendenden Delta-Buendels — dieselbe Id,
  /// die `increment_lifetime_stats(p_request_id)` serverseitig 30 Tage lang
  /// festhaelt (Migration 20260814120000_audit_rls_guard.sql).
  ///
  /// Invariante: nicht-`null` genau dann, wenn Deltas pendieren. Er entsteht
  /// mit dem ersten Delta eines Buendels ([_queueStatsDelta]), wandert mit den
  /// Zahlen in den Cache-Slot ([_persistPendingStatsDeltas]) und ueberlebt
  /// damit den Kaltstart. Eine NEUE Id gibt es erst, wenn ein Buendel
  /// nachweislich verbucht ist und ein frisches beginnt — genau darin liegt der
  /// Schutz: nur ein Retry mit derselben Id kann serverseitig als Wiederholung
  /// erkannt werden.
  ///
  /// Seit Fix 3 traegt das Buendel ausschliesslich LIVE-Deltas: was der Replay
  /// nachholt, zaehlt ueber seinen eigenen
  /// [SyncOpKind.statsIncrement]-Eintrag mit abgeleiteter Id. Ein
  /// Replay-Rueckstau kann ein in-flight-Buendel damit nicht mehr aufblaehen.
  String? _pendingStatsRequestId;

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
  ///
  /// [message] ersetzt NUR den Snack-Text — fuer Aufrufer, die ueber den
  /// Fehler mehr wissen als die generische Klassifikation (Kontoloeschung:
  /// [deleteAccountErrorMessage] kennt die serverseitige Reauth-Ablehnung).
  /// Log und CrashReporter bleiben bewusst unberuehrt: eine Meldung, die der
  /// Aufrufer praeziser fassen kann, ist deshalb nicht weniger meldenswert.
  void _reportSyncError(String operation, Object error, StackTrace stack,
      {String? message}) {
    dev.log('$operation failed', error: error, name: 'eatova_sync');
    unawaited(CrashReporter.capture(error, stack, context: operation));
    if (_disposed) return;
    _emitSnack(
      message ?? directSyncErrorMessage(error, _l10n),
      icon: Icons.error_outline_rounded,
      tone: SnackTone.error,
      duration: kSnackError,
    );
  }

  /// Fire-and-forget Sync-Write OHNE Rollback (DATA-7): der optimistische
  /// lokale State bleibt stehen, und die Operation liegt als persistierter
  /// Outbox-Eintrag in der Retry-Queue, bis der Server sie quittiert hat.
  /// Frueher wurde hier zurueckgerollt — der Eintrag des Nutzers war dann bei
  /// jedem Netz-Schluckauf weg.
  ///
  /// Luecke B — Reihenfolge: die Op wird ZUERST angelegt und persistiert, dann
  /// zugestellt, und bei Erfolg wieder entfernt. Vorher entstand sie erst im
  /// `catchError`, und das riss zwei Loecher:
  ///  * zwischen Tap und Fehler existierte der Eintrag nur im RAM — ein Kill
  ///    in diesem Fenster kostete ihn ersatzlos;
  ///  * ein Request, der HAENGT statt zu scheitern, feuert weder `then` noch
  ///    `catchError`. Supabase-/PostgREST-Aufrufe tragen kein Timeout (die
  ///    Policies in eatova_http.dart gelten nur fuer Meilisearch/OFF/
  ///    analyze-meal), also entstand nie eine Op — still, ohne Log.
  ///
  /// Haengt fuer dieselbe Entitaet bereits eine GESCHEITERTE Op in der Outbox,
  /// wird die neue Operation direkt dahinter eingereiht statt live zu
  /// schreiben: ein Live-Write wuerde die pendende Op ueberholen (z.B. ein
  /// Update, dessen Insert noch aussteht, traefe serverseitig 0 Zeilen und der
  /// Replay schriebe danach den alten Stand).
  ///
  /// Dasselbe gilt fuer Entitaeten, deren Op einmal VERWORFEN wurde
  /// ([_orphanedEntities], A6): auch die existieren serverseitig womoeglich
  /// nicht, und der Live-Pfad (PATCH auf 0 Zeilen = 204 = „Erfolg") wuerde das
  /// nie bemerken.
  ///
  /// [onDelivered] laeuft NUR nach einer erfolgreichen LIVE-Zustellung — fuer
  /// die Zaehler-Seiteneffekte, die der Replay-Pfad selbst erledigt
  /// (Streak-Tag in [_performOp], Lebenszeit-Zaehler seit Fix 3 ueber den
  /// [SyncOpKind.statsIncrement]-Folgeeintrag). Wird die Op stattdessen
  /// eingereiht, bleibt der Callback bewusst aus, sonst zaehlte der Wert
  /// doppelt.
  ///
  /// Der Rueckgabewert sagt, was WIRKLICH passiert ist (Luecke E). Aufrufer,
  /// die ihn auswerten, setzen [aufruferMeldetAusgang] und uebernehmen damit
  /// die Meldung an den Nutzer: der generische Warteschlangen-Hinweis bleibt
  /// dann aus (er wuerde die praezisere Meldung des Aufrufers sofort wieder
  /// abraeumen, [showAppSnack] laesst nur einen Toast stehen), und die Antwort
  /// kommt spaetestens nach [kSyncDeliveryWindow] — sonst haengt die
  /// Erfolgsmeldung des Nutzers an einem Request ohne Timeout (Luecke B).
  /// Fire-and-forget-Aufrufer ignorieren den Wert einfach; fuer sie bleibt
  /// alles wie bisher.
  Future<SyncDelivery> _syncOrQueue(
    String operation,
    Future<void> Function() action,
    SyncOp Function() buildOp, {
    VoidCallback? onDelivered,
    bool aufruferMeldetAusgang = false,
  }) {
    // Ohne Sync gibt es nichts zuzustellen (Vorschau/Test-Schale) — „wird
    // synchronisiert" waere hier die Luege.
    if (sync == null) return Future<SyncDelivery>.value(SyncDelivery.delivered);
    final op = buildOp();
    final entitaetBelegt = _orphanedEntities.contains(op.entityKey) ||
        _outbox.any((o) => o.entityKey == op.entityKey);
    // Belegt, weil fuer die Entitaet GERADE EIN LIVE-WRITE laeuft, ist etwas
    // anderes als belegt, weil einer gescheitert ist: gescheitert ist der
    // Grund fuer den Warteschlangen-Hinweis, laufend ist keiner. Ohne diese
    // Unterscheidung toastete seit der Umstellung jede zweite Aenderung
    // derselben Entitaet ein „wird automatisch erneut versucht", obwohl nichts
    // schiefgegangen war.
    final nurLaufenderWrite = _inFlightOps.containsKey(op.entityKey);
    _enqueueOp(op);
    if (entitaetBelegt) {
      if (!nurLaufenderWrite) {
        if (!aufruferMeldetAusgang) _notifyQueued(null);
        _scheduleOutboxRetry();
      }
      // Kein Live-Write: der laufende bzw. der Replay stellt der Reihe nach zu
      // (FIFO pro Entitaet).
      return Future<SyncDelivery>.value(SyncDelivery.queuedRetry);
    }
    _inFlightOps[op.entityKey] = op;
    final zustellung = action().then<SyncDelivery>((_) {
      _inFlightOps.remove(op.entityKey);
      _dequeueDeliveredOp(op);
      onDelivered?.call();
      _onSyncSuccess();
      return SyncDelivery.delivered;
    }).onError<Object>((e, st) {
      _inFlightOps.remove(op.entityKey);
      _handleSyncFailure(operation, e, st,
          aufruferMeldetAusgang: aufruferMeldetAusgang);
      return queuedDelivery(e);
    });
    if (!aufruferMeldetAusgang) return zustellung;
    // Nur fuer wartende Aufrufer: der Timer haengt sonst an JEDEM Write, und
    // die Zusicherung braucht ihn nur, wenn jemand auf die Antwort schaut.
    // Die Op liegt in dem Moment laengst in der persistierten Queue — „liegt
    // in der Warteschlange" ist also auch nach einem Timeout die Wahrheit,
    // selbst wenn der Request danach doch noch durchkommt.
    return zustellung.timeout(kSyncDeliveryWindow,
        onTimeout: () => SyncDelivery.queuedRetry);
  }

  /// Sync-Write fehlgeschlagen: dezent hinweisen, Retry planen. KEIN Rollback,
  /// KEIN roter Fehler-Toast. Die Op liegt seit Luecke B schon vor dem Write in
  /// der (persistierten) Queue und bleibt dort einfach stehen — hier wird
  /// bewusst NICHT erneut eingereiht: sie koennte inzwischen legitim
  /// verschwunden sein (koalesziert, am Cap gefallen, vom Replay zugestellt),
  /// und ein Wiedereinreihen wuerde genau das rueckgaengig machen.
  void _handleSyncFailure(
    String operation,
    Object error,
    StackTrace stack, {
    bool aufruferMeldetAusgang = false,
  }) {
    dev.log('$operation failed — Op bleibt in der Outbox liegen',
        error: error, name: 'eatova_sync');
    // `captureSyncFailure` statt `capture`: ein reiner Netzausfall ist hier
    // der vorgesehene Ablauf, kein Vorfall — die Op liegt in der Queue, der
    // Nutzer hat den Hinweis. Vorher erzeugte jeder Offline-Write ein
    // Sentry-Issue mit Prioritaet „hoch" (Feed-Befund 2026-08-10).
    unawaited(CrashReporter.captureSyncFailure(error, stack,
        context: operation));
    if (_disposed) return;
    // Der Aufrufer sagt es praeziser (mit dem Namen des Eintrags) und in EINEM
    // Toast. [_syncHintShown] bleibt bewusst unberuehrt: eine spaetere,
    // ANDERE Aktion soll ihren Hinweis weiterhin bekommen.
    if (!aufruferMeldetAusgang) _notifyQueued(error);
    _scheduleOutboxRetry();
  }

  /// Entfernt die LIVE zugestellte Op wieder aus der Queue — ueber Identitaet,
  /// nicht ueber den Entitaets-Schluessel.
  ///
  /// Der Unterschied traegt: waehrend der Write lief, kann fuer dieselbe
  /// Entitaet eine juengere Op koalesziert (also an ihre Stelle getreten) sein.
  /// Die beschreibt einen Stand, den der Server noch NICHT hat — sie muss
  /// liegen bleiben. Findet sich die eigene Op nicht mehr, ist ohnehin nichts
  /// zu tun (koalesziert, am Cap gefallen oder vom Replay bereits zugestellt).
  void _dequeueDeliveredOp(SyncOp op) {
    final at = _outbox.indexWhere((o) => identical(o, op));
    if (at < 0) return;
    _outbox = [..._outbox]..removeAt(at);
    _persistOutbox();
  }

  /// Darf [op] eine bereits eingereihte Op derselben Entitaet ERSETZEN
  /// (koaleszieren)? Nicht, solange fuer diese Entitaet ein Live-Write laeuft,
  /// dessen Nachspielen einen ZAEHLER bucht.
  ///
  /// Konkret der mealInsert: sein Replay verbucht +1 Mahlzeit (und ggf. den
  /// Streak-Tag). Koalesziert ein nachfolgendes Update ihn weg, verschwindet
  /// die Op, deren Live-Erfolg gleich selbst zaehlt — die zusammengefuehrte Op
  /// bleibt aber ein mealInsert und zaehlt beim Replay ein zweites Mal. Also
  /// in diesem Fall anhaengen statt ersetzen; die Reihenfolge pro Entitaet
  /// bleibt dabei erhalten (FIFO), nur die Queue ist um einen Eintrag laenger.
  ///
  /// Die Regel traegt nach Fix 3 unveraendert weiter — und sie ist weiterhin
  /// load-bearing: die Live-Zaehlung laeuft ueber die Buendel-Id, die
  /// Replay-Zaehlung ueber die aus der Quell-UUID abgeleitete Id des
  /// [SyncOpKind.statsIncrement]-Eintrags. Das sind fuer den Server ZWEI
  /// verschiedene Vorgaenge, sie dedupen sich also nicht gegenseitig; die
  /// Exklusivitaet der beiden Pfade bleibt die Schutzmauer.
  bool _koaleszenzUnsicher(SyncOp op) {
    final laufend = _inFlightOps[op.entityKey];
    return laufend != null &&
        (laufend.kind == SyncOpKind.mealInsert ||
            laufend.kind == SyncOpKind.weightInsert);
  }

  void _enqueueOp(SyncOp op) {
    // Waehrend eines laufenden Replays nur anhaengen — der Replay koennte
    // gerade genau die Op abspielen, deren Payload sonst koalesziert (und beim
    // Entfernen verworfen) wuerde. Dieselbe Ueberlegung gilt seit Luecke B fuer
    // eine Op, deren LIVE-Write gerade laeuft (s. _koaleszenzUnsicher).
    _outbox = enqueueCoalesced(_outbox, op,
        appendOnly: _outboxReplayInFlight || _koaleszenzUnsicher(op));
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
        // Der Cap kappt Deletes zuletzt, aber er kappt sie (harte Obergrenze,
        // s. capOutbox) — dann gilt derselbe Weg wie im Replay: Eintraege
        // zurueckholen, beide Verlust-Arten getrennt melden.
        final lostDeletes = capped.dropped.where((o) => o.isDelete).toList();
        if (lostDeletes.isNotEmpty) {
          unawaited(_restoreDroppedDeletes(lostDeletes));
        }
        _notifyDroppedOps(capped.dropped);
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
      queuedSyncHint(error, _l10n),
      icon: offline ? Icons.cloud_off_rounded : Icons.sync_problem_rounded,
      tone: SnackTone.neutral,
    );
  }

  /// Meldet ENDGUELTIG verworfene Ops — anders als [_notifyQueued] ist das
  /// echter Datenverlust und keine Warteschleife. Der Text kommt aus dem puren
  /// Mapping und traegt bewusst KEINE technischen Details (kein SQLSTATE, kein
  /// Tabellen-/Constraint-Name, kein Exception-Typ); die Roh-Exception geht
  /// nur an dev.log + CrashReporter. Einmal pro Episode.
  ///
  /// [deletesLost] waehlt den Text fuer den umgekehrten Fall: bei einem
  /// verworfenen Write FEHLT etwas, bei einer verworfenen Loeschung ist etwas
  /// WIEDER DA. Die beiden Meldungen zaehlen getrennt — steht beides an, sagt
  /// die Episode beides genau einmal. Ein gemeinsamer Merker haette die
  /// Loeschung verschluckt, sobald im selben Replay auch ein Write starb, und
  /// die Mahlzeit waere kommentarlos wieder aufgetaucht.
  /// Meldet die Verluste EINES Cap-Ereignisses getrennt nach Art — wie es der
  /// Replay-Verwurf schon immer tat. Ein einzelner
  /// `_notifyOutboxLoss(deletesLost: dropped.any(isDelete))` verschluckte im
  /// Misch-Fall den Write-Verlust: fallen Deletes, sind per capOutbox-
  /// Reihenfolge ALLE Writes schon gefallen, und der Nutzer verlor sie mit
  /// der falschen Meldung („der Eintrag ist wieder da").
  void _notifyDroppedOps(List<SyncOp> dropped) {
    final deletes = dropped.where((o) => o.isDelete).length;
    // statsIncrement-Eintraege sind Zaehler, kein Nutzer-Inhalt — fuer sie
    // waere „ein Eintrag fehlt" die falsche Meldung (s. Verwurfs-Zweig des
    // Replays). Geloggt sind sie ueber den Cap-Breadcrumb so oder so.
    final inhalte = dropped
        .where((o) => !o.isDelete && o.kind != SyncOpKind.statsIncrement)
        .length;
    if (inhalte > 0) _notifyOutboxLoss();
    if (deletes > 0) _notifyOutboxLoss(deletesLost: true);
  }

  void _notifyOutboxLoss({bool deletesLost = false}) {
    if (_disposed) return;
    if (deletesLost) {
      if (_outboxDeleteLossNotified) return;
      _outboxDeleteLossNotified = true;
    } else {
      if (_outboxLossNotified) return;
      _outboxLossNotified = true;
    }
    _emitSnack(
      deletesLost ? outboxDeleteLossHint(_l10n) : outboxLossHint(_l10n),
      icon: Icons.sync_problem_rounded,
      tone: SnackTone.error,
      duration: kSnackError,
    );
  }

  /// Holt die Eintraege verworfener LOESCH-Ops in den lokalen Zustand zurueck
  /// (A5, Wiedereinblendung).
  ///
  /// Warum ueberhaupt: ein verworfener Delete ist der einzige Verlust, der sich
  /// von selbst RUECKGAENGIG macht. Lokal ist die Zeile weg, serverseitig
  /// nicht — und weil danach kein weiterer Write auf diese Entitaet kommt,
  /// greift auch [_orphanedEntities] nicht. Ohne diesen Schritt merkt der
  /// Nutzer nichts, bis Tage spaeter ein Kaltstart die geloeschte
  /// 1800-kcal-Mahlzeit wieder mitzaehlt. GENAU das macht die endliche Frist
  /// aus [kOutboxDeleteMinAge] ueberhaupt vertretbar: der Verwurf endet
  /// sichtbar und reparierbar (der Nutzer loescht erneut, mit frischem Budget
  /// und frischer Frist) statt still.
  ///
  /// Der Inhalt liegt nur noch auf dem Server — eine Delete-Op traegt eine
  /// leere Payload —, also kostet das einen Read pro betroffener Sammlung.
  /// Vertretbar: der Pfad feuert erst, wenn eine Loeschung tage- und
  /// dutzendfach abgelehnt wurde. Findet der Read die Zeile NICHT, war die
  /// Loeschung serverseitig laengst angekommen und es gibt nichts
  /// einzublenden — der Read ist damit zugleich die Gegenprobe.
  ///
  /// Jede Sammlung laeuft in ihrem eigenen try: ein fehlgeschlagener Read darf
  /// die anderen nicht mitreissen.
  Future<void> _restoreDroppedDeletes(List<SyncOp> ops) async {
    final s = sync;
    if (s == null || _disposed) return;
    final mealIds = <String>{}, favoriteIds = <String>{}, recipeSlugs = <String>{};
    for (final op in ops) {
      switch (op.kind) {
        case SyncOpKind.mealDelete:
          mealIds.add(op.entityId);
        case SyncOpKind.favoriteDelete:
          favoriteIds.add(op.entityId);
        case SyncOpKind.recipeDelete:
          recipeSlugs.add(op.entityId);
        default:
          break;
      }
    }
    if (mealIds.isNotEmpty) {
      try {
        // Gezielt per Id, NICHT ueber den Fenster-Load: die Zeile kann aelter
        // als das Boot-Fenster sein (Delete via Archiv-Tag-Picker), und der
        // „wieder da"-Hinweis muss auch dann stimmen.
        final rows = await s.meals.loadLoggedMealsByIds(mealIds);
        final back = rows.where((m) => mealIds.contains(m.id)).toList();
        if (back.isNotEmpty && !_disposed) {
          _mutate(() {
            final known = loggedMeals.map((m) => m.id).toSet();
            loggedMeals = <LoggedMeal>[
              ...loggedMeals,
              ...back.where((m) => !known.contains(m.id)),
            ]..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
            final today = clock.now();
            dailyConsumedKcal = consumedKcalForFoodDate(today);
            macroProgress = macroProgressForFoodDate(today);
          });
          _cacheLoggedMeals();
        }
      } catch (e, st) {
        _reportRestoreFailure('meals', e, st);
      }
    }
    if (favoriteIds.isNotEmpty) {
      try {
        final rows = await s.meals.loadFavorites();
        final back = rows.where((f) => favoriteIds.contains(f.id)).toList();
        if (back.isNotEmpty && !_disposed) {
          _mutate(() {
            final known = favorites.map((f) => f.id).toSet();
            favorites = <FavoriteMeal>[
              ...favorites,
              ...back.where((f) => !known.contains(f.id)),
            ];
          });
          _cacheFavorites();
        }
      } catch (e, st) {
        _reportRestoreFailure('favorites', e, st);
      }
    }
    if (recipeSlugs.isNotEmpty) {
      try {
        final rows = await s.userRecipes.load();
        final back = rows.where((r) => recipeSlugs.contains(r.slug)).toList();
        if (back.isNotEmpty && !_disposed) {
          _mutate(() {
            final known = _userRecipes.map((r) => r.slug).toSet();
            _userRecipes = <FitnessRecipe>[
              ..._userRecipes,
              ...back.where((r) => !known.contains(r.slug)),
            ];
          });
          // Wie bei Mahlzeiten/Favoriten: die Wiedereinblendung muss auch im
          // Cache stehen, sonst ist das Rezept beim naechsten Kaltstart ohne
          // Netz wieder verschwunden (Luecke A).
          _cacheUserRecipes();
        }
      } catch (e, st) {
        _reportRestoreFailure('recipes', e, st);
      }
    }
  }

  /// Die Wiedereinblendung ist selbst nur best effort: schlaegt der Read fehl
  /// (offline im selben Moment), bleibt der Eintrag bis zum naechsten Boot
  /// unsichtbar — der holt ihn dann ohnehin vom Server. Gemeldet ist der
  /// Verlust so oder so, der Snack laeuft unabhaengig davon.
  void _reportRestoreFailure(String what, Object e, StackTrace st) {
    dev.log('Outbox: Wiedereinblendung nach verworfenem Delete '
        'fehlgeschlagen ($what)', error: e, name: 'eatova_sync');
    unawaited(CrashReporter.capture(e, st, context: 'outbox-restore-$what'));
  }

  /// Nach einem erfolgreichen Sync-Write: Fehler-Episode beenden, Backoff
  /// zuruecksetzen und liegengebliebene Ops direkt nachspielen.
  void _onSyncSuccess() {
    if (_disposed) return;
    _syncHintShown = false;
    _outboxLossNotified = false;
    _outboxDeleteLossNotified = false;
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
    var droppedWrites = false;
    final droppedDeletes = <SyncOp>[];
    try {
      var i = 0;
      while (i < _outbox.length) {
        final op = _outbox[i];
        // Laeuft fuer die Entitaet gerade ein Live-Write, gehoert ihre Op ihm
        // (Luecke B) — sie jetzt zusaetzlich abzuspielen hiesse: dieselbe Zeile
        // zweimal schreiben, und ein mealInsert zaehlte die Mahlzeit zweimal.
        // Sie bleibt liegen; ihr Ausgang stoesst den naechsten Lauf selbst an
        // (Erfolg -> _onSyncSuccess, Fehler -> _scheduleOutboxRetry). Bleibt
        // die Antwort ganz aus, wartet sie bis zum naechsten App-Start —
        // persistiert, also nicht verloren. Kein `blocked`-Eintrag: sonst
        // haengt an einem stummen Request dauerhaft der Backoff-Timer.
        if (blocked.contains(op.entityKey) ||
            _inFlightOps.containsKey(op.entityKey)) {
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
            // A5: ein verworfener Delete darf nicht still bleiben — der
            // Eintrag existiert serverseitig weiter und wird nach dem Replay
            // lokal wieder eingeblendet. Getrennt gezaehlt, weil die beiden
            // Verluste dem Nutzer Gegenteiliges bedeuten.
            if (op.isDelete) {
              droppedDeletes.add(op);
            } else if (op.kind != SyncOpKind.statsIncrement) {
              droppedWrites = true;
            }
            // A6: die Entitaet ist ab jetzt potenziell verwaist (lokal da,
            // serverseitig nicht). Kuenftige Writes muessen deshalb ueber die
            // Outbox laufen, wo sie als voller Upsert ankommen.
            //
            // Beides gilt NUR fuer Inhalts-Ops: auf 'stats:<uuid>' schreibt nie
            // wieder jemand, und der Verlust ist ein Zaehler, kein Eintrag —
            // der „etwas fehlt"-Snack waere hier gelogen (die Mahlzeit ist
            // laengst zugestellt). dev.log + Crash-Report laufen fuer ihn
            // weiter ueber den gemeinsamen Pfad oberhalb.
            if (op.kind != SyncOpKind.statsIncrement) {
              _orphanedEntities.add(op.entityKey);
            }
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
        // Wie im Fehlerzweig ueber Identitaet statt ueber den Laufindex: der
        // konnte waehrend des await veralten, und dann entfernte `removeAt(i)`
        // eine FREMDE Op. Zwei Pfade kuerzen die Queue genau in diesem
        // Fenster — _clearQueuedTrackingDay (feuert _performOp fuer jede
        // nachgeholte Mahlzeit selbst, ungeawaitet) und _dequeueDeliveredOp
        // eines parallel zugestellten Live-Writes. Der Preis war entweder eine
        // still verworfene, nie zugestellte Mahlzeit (waehrend die zugestellte
        // liegenblieb und beim naechsten Replay doppelt zaehlte) oder ein
        // RangeError, der ausserhalb des inneren try liegt: der riss
        // signOutCleanup VOR _clearCache ab, der PII-Cache blieb liegen und
        // der Logout kam nie zustande.
        final at = _outbox.indexWhere((o) => identical(o, op));
        // Fix 3: Entfernung der Op und Erzeugung ihres Zaehler-Folgeeintrags
        // sind EIN Listenupdate und damit EIN persistierter Blob-Write — ein
        // Kill trifft entweder den Zustand davor (Op da, kein Eintrag; der
        // naechste Replay wiederholt idempotent und erzeugt den Eintrag mit
        // DERSELBEN abgeleiteten Id neu) oder danach (Eintrag da, Op weg).
        // Das Fenster „Delta persistiert, Op noch da" existiert nicht mehr.
        // Angehaengt wird ans Ende: der Loop erreicht den Eintrag noch im
        // selben Lauf (die while-Bedingung liest die Laenge frisch). Der
        // Duplikat-Check ist Queue-Hygiene, keine Korrektheitsbedingung —
        // auch ein doppelter Eintrag waere dank identischer Id serverseitig
        // ein No-op.
        final followUp = _statsFollowUpFor(op);
        final followUpId = followUp?.entityId;
        bool traegtFollowUp(List<SyncOp> q) =>
            followUpId != null &&
            q.any((o) =>
                o.kind == SyncOpKind.statsIncrement &&
                o.entityId == followUpId);
        if (at >= 0) {
          final next = [..._outbox]..removeAt(at);
          if (followUp != null && !traegtFollowUp(next)) next.add(followUp);
          _outbox = next;
          _persistOutbox();
          // Die nachgerueckte Op steht jetzt an dieser Position.
          i = at;
        } else {
          // Schon anderswo entfernt — an dieser Position steht eine andere Op.
          // Der Folgeeintrag entsteht trotzdem: sollte ein koaleszierter
          // Zwilling (Reparatur-Merge) spaeter erneut spielen, erzeugt er
          // dieselbe Id — lokal faengt ihn der Check, serverseitig der Dedup.
          if (followUp != null && !traegtFollowUp(_outbox)) {
            _outbox = [..._outbox, followUp];
            _persistOutbox();
          }
          i++;
        }
      }
    } finally {
      _outboxReplayInFlight = false;
    }
    if (_disposed) return;
    // Erst die Eintraege zurueckholen, DANN melden: der Snack behauptet „der
    // Eintrag ist wieder da", und wenn der Nutzer hinsieht, soll er das auch
    // sein. Der Server ist der einzige Ort, an dem der Inhalt noch liegt (die
    // Delete-Op traegt eine leere Payload), also kostet das einen Read.
    if (droppedDeletes.isNotEmpty) await _restoreDroppedDeletes(droppedDeletes);
    if (_disposed) return;
    // Beide Meldungen, wenn beides passiert ist — sie widersprechen sich nicht,
    // sie beschreiben zwei verschiedene Verluste.
    if (droppedWrites) _notifyOutboxLoss();
    if (droppedDeletes.isNotEmpty) _notifyOutboxLoss(deletesLost: true);
    // Eine leere Queue ist „fertig", auch wenn Ops blockiert WAREN: sie sind
    // dann alle verworfen worden, und ein Backoff-Timer haette nichts mehr zu
    // tun.
    if (blocked.isEmpty || _outbox.isEmpty) {
      _outboxRetryAttempt = 0;
      _outboxRetryTimer?.cancel();
      if (anySuccess) {
        _syncHintShown = false;
        _outboxLossNotified = false;
        _outboxDeleteLossNotified = false;
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
  ///  * A5 — fuer [SyncOp.isDelete] gibt es keinen Sofort-Verwurf (die
  ///    Klassifizierung liefert fuer sie „drop" ausschliesslich am Ende des
  ///    Delete-Budgets), und die Frist ist die lange [kOutboxDeleteMinAge].
  ///    Beide Bedingungen muessen erfuellt sein — das Budget allein waere von
  ///    Lifecycle-Churn in Sekunden verbrannt, die Wanduhr allein wuerde eine
  ///    lange offline liegende Op an der ersten Server-Ablehnung verwerfen.
  ///
  /// Die Wanduhr laeuft ueber `clock.now()`: die Frist ist damit mit einer
  /// injizierten Uhr pruefbar, und ein Rueckwaertssprung der Systemzeit macht
  /// keine Op mehr unverwerfbar.
  OutboxVerdict _verdictFor(Object error, SyncOp op) {
    if (error is _CorruptOpPayload) return OutboxVerdict.drop;
    final verdict = classifyOutboxFailure(error, op.attempts, kind: op.kind);
    if (verdict != OutboxVerdict.drop) return verdict;
    if (op.isDelete) {
      return _agedOut(op, kOutboxDeleteMinAge)
          ? OutboxVerdict.drop
          : OutboxVerdict.retryCounted;
    }
    if (classifyOutboxFailure(error, 0, kind: op.kind) == OutboxVerdict.drop) {
      return OutboxVerdict.drop;
    }
    return _agedOut(op, kOutboxMinAgeBeforeDrop)
        ? OutboxVerdict.drop
        : OutboxVerdict.retryCounted;
  }

  bool _agedOut(SyncOp op, Duration minAge) =>
      clock.now().difference(op.queuedAt) >= minAge;

  /// Fuehrt EINE Outbox-Op gegen den Server aus. Wirft bei Sync-Fehler (der
  /// Replay-Loop behaelt die Op dann) und bei nicht lesbarer Payload
  /// ([_CorruptOpPayload] — die Op wird dann verworfen, A8).
  ///
  /// Der LEBENSZEIT-Zaehler einer zaehlenden Op wird hier bewusst NICHT mehr
  /// gebucht (Fix 3): er lief bis dahin ueber [_queueStatsDelta], also ueber
  /// einen zweiten, SOFORT persistierten Slot — waehrend die Op selbst erst
  /// einen Blob-Write spaeter aus der Outbox fiel. Ein Kill dazwischen zaehlte
  /// beim naechsten Boot ein zweites Mal. Stattdessen erzeugt der Replay-Loop
  /// beim Entfernen der Op ihren [SyncOpKind.statsIncrement]-Folgeeintrag,
  /// atomar im selben Blob-Write (s. [_statsFollowUpFor], [_replayOutbox]).
  /// Der Streak-Tag bleibt hier: [_recordTrackingDay] ist serverseitig pro Tag
  /// idempotent, ihn doppelt zu senden kostet nichts.
  Future<void> _performOp(EatovaSync s, SyncOp op) async {
    switch (op.kind) {
      case SyncOpKind.mealInsert:
        final meal = op.meal;
        if (meal == null) throw _CorruptOpPayload(op.kind);
        await s.meals.insertLoggedMeal(meal);
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
      case SyncOpKind.profileUpsert:
        // Luecke D. Der Save ist ein voller Zeilen-Upsert auf die User-Id, also
        // idempotent wiederholbar. Eine unlesbare/unvollstaendige Payload geht
        // NICHT durch (A8-Pfad): sonst schriebe der Replay halb erfundene
        // Zahlen ueber eine echte Profilzeile — genau der Clobber, gegen den
        // _hydratedFromRealSource ueberhaupt existiert.
        final p = op.profile;
        if (p == null) throw _CorruptOpPayload(op.kind);
        await s.profile.save(p);
      case SyncOpKind.statsIncrement:
        final meals = op.statsMeals;
        final weightLogs = op.statsWeightLogs;
        // Leeres Increment oder eine entityId ohne UUID-Form koennen nie
        // sinnvoll zugestellt werden (der RPC-Parameter ist uuid) — A8-Pfad,
        // wie jede unlesbare Payload.
        if ((meals <= 0 && weightLogs <= 0) || !isUuidShape(op.entityId)) {
          throw _CorruptOpPayload(op.kind);
        }
        // entityId IST die Request-Id: jede Wiederholung sendet dieselbe,
        // der Server addiert einen bereits verbuchten Eintrag nicht erneut
        // und liefert nur die aktuelle Zeile — der Eintrag verlaesst die
        // Queue dann als normaler Erfolg.
        final frischeZeile = await s.lifetimeStats.increment(
          meals: meals,
          weightLogs: weightLogs,
          requestId: op.entityId,
        );
        if (_disposed) return;
        _mutate(() {
          lifetimeStats = frischeZeile;
          // Wie in _flushStatsDelta: die Serverzeile ist fuer die Zaehler
          // autoritativ, fuer einen noch nicht zugestellten Streak-Tag nicht.
          _overlayPendingTrackingDays();
        });
        _cacheLifetimeStats();
      case SyncOpKind.trackingDay:
        // Der Tag steckt im entityId (YYYY-MM-DD), nicht in der Payload — ein
        // unlesbarer Wert ist trotzdem der A8-Fall: er wird nie zustellbar.
        final tag = DateTime.tryParse(op.entityId);
        if (tag == null) throw _CorruptOpPayload(op.kind);
        final fresh = await s.lifetimeStats.recordTrackingDay(tag);
        if (_disposed) return;
        _mutate(() {
          lifetimeStats = fresh;
          _overlayPendingTrackingDays();
        });
        _cacheLifetimeStats();
    }
  }

  /// Der Zaehler-Folgeeintrag einer erfolgreich nachgespielten Op — oder
  /// null, wenn die Op nicht zaehlt. Ersetzt das fruehere
  /// `_queueStatsDelta` in [_performOp]: das persistierte sein +1 SOFORT in
  /// den Deltas-Slot, waehrend die Op erst einen zweiten Write spaeter aus
  /// der Outbox fiel — ein App-Kill dazwischen liess den naechsten Boot die
  /// Op erneut spielen und ein zweites +1 buchen, unter frischer Buendel-Id
  /// und damit am Server-Dedup vorbei. Der Folgeeintrag entsteht stattdessen
  /// ATOMAR mit der Entfernung (derselbe Blob-Write, s. [_replayOutbox]) und
  /// traegt eine aus der Quell-UUID ABGELEITETE Request-Id — jede
  /// Wiederholung ist fuer den Server derselbe Vorgang.
  SyncOp? _statsFollowUpFor(SyncOp op) {
    final zaehltMeal = op.kind == SyncOpKind.mealInsert;
    final zaehltWeight = op.kind == SyncOpKind.weightInsert;
    if (!zaehltMeal && !zaehltWeight) return null;
    final requestId = deriveStatsRequestId(op.entityId);
    if (requestId == null) {
      // entityId ist keine UUID — aus unseren Factories unmoeglich
      // (uuidV4 in home_store_meals / home_store_tracking), also nur ueber
      // einen manipulierten/fremden Blob erreichbar. Der Zaehler entfaellt
      // fuer diese eine Op (derselbe bewusste Preis wie beim capOutbox-
      // Kopf-Trim: ein Zaehler, kein Nutzer-Inhalt). NUR das Op-Kind ins
      // Reporting, nie die Payload.
      dev.log('Outbox: Stats-Request-Id nicht ableitbar (${op.kind.name}) — '
          'Zaehler-Folgeeintrag entfaellt', name: 'eatova_sync');
      CrashReporter.breadcrumb('stats-rid underivable: ${op.kind.name}');
      return null;
    }
    return SyncOp.statsIncrement(
      requestId: requestId,
      meals: zaehltMeal ? 1 : 0,
      weightLogs: zaehltWeight ? 1 : 0,
    );
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
        case SyncOpKind.profileUpsert:
          // Luecke D, zweite Haelfte: das ist der Schutz des BOOTS. Der
          // Server-Load setzt `profile` auf die (alte) Serverzeile — hier
          // kommt die noch nicht zugestellte Aenderung wieder obenauf.
          // Danach schreibt `_writeCacheSnapshot` genau diesen Stand, der
          // Cache erbt den Schutz also mit.
          final pendingProfile = op.profile;
          if (pendingProfile == null) break;
          profile = pendingProfile;
          // Eine Profil-Op entsteht nur aus einem echten, hydrierten Profil
          // (applySettings gibt sie ohne _hydratedFromRealSource gar nicht
          // aus, completeOnboarding setzt das Flag selbst). Sie IST damit eine
          // echte Quelle — ohne diese Zeile bliebe der A1-Guard zu und
          // `_writeCacheSnapshot` liesse die Aenderung wieder aus dem Cache
          // fallen, sobald weder Cache-Profil noch Server-Zeile lesbar waren.
          _hydratedFromRealSource = true;
        case SyncOpKind.trackingDay:
          // Damit ueberlebt auch der optimistische Streak-Stand den Kaltstart:
          // der Server-Load liefert die Zeile OHNE den Tag (der RPC ist ja nie
          // durchgekommen), hier kommt er wieder obenauf. recordTrackedDay ist
          // lokal pro Tag idempotent und fuer Tage VOR dem zuletzt gezaehlten
          // ein No-op — mehrfaches Anwenden aendert also nichts.
          final tag = DateTime.tryParse(op.entityId);
          if (tag == null) break;
          lifetimeStats = lifetimeStats.recordTrackedDay(tag);
        case SyncOpKind.statsIncrement:
          // Kein State-Effekt: die Anzeige der Lebenszeit-Zaehler folgt der
          // Serverzeile — exakt wie bei den pendenden Buendel-Deltas, deren
          // Anzeige-Grenzfaelle dokumentiert offen sind. Der Eintrag wirkt
          // ausschliesslich beim Replay.
          break;
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
      tone: SnackTone.error,
      action: SnackBarAction(label: _l10n.commonUndo, onPressed: onUndo),
    );
  }

  /// DSGVO Art. 17: löscht Konto + alle Daten serverseitig (RPC). Liefert true,
  /// wenn die Löschung durchlief (dann darf die Schale ausloggen). Bei Fehler
  /// false (kein Logout, damit der User es erneut versuchen kann).
  Future<bool> deleteAccount() async {
    try {
      await sync?.deleteAccount();
    } catch (e, st) {
      // Die serverseitige Reauth-Ablehnung (Migration 20260815120000,
      // EX_REAUTH_REQUIRED) braucht einen eigenen Satz: „bitte spaeter
      // erneut" waere falsch — spaeter erneut zu tippen hilft nicht, der
      // Mail-Code muss neu angefordert werden.
      _reportSyncError('Konto-Löschung', e, st,
          message: deleteAccountErrorMessage(e, _l10n));
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
  /// liegen, überleben Outbox UND pendende Stats-Deltas den Logout und spielen
  /// beim nächsten Login desselben Users nach.
  ///
  /// „Etwas" heißt ausdrücklich BEIDE Kanäle. Die Deltas hängen nicht an der
  /// Outbox: der Mahlzeiten-Write kann gelingen, während
  /// `increment_lifetime_stats` (eigener RPC, [_flushStatsDelta]) scheitert —
  /// dann ist die Queue leer und die Zähler stehen trotzdem aus. Hinge
  /// `preserveOutbox` allein an `_outbox.length`, nähme genau diese
  /// Kombination dem Nutzer die Lebenszeit-Zähler und damit die
  /// Streak-Grundlage (kein Mahlzeiteninhalt, aber auch nicht nichts).
  ///
  /// Die alte Begründung (PII darf den Logout nicht überleben) trägt für
  /// diesen einen Slot nicht mehr: der Cache ist seit `7f895f9`
  /// AES-256-GCM-verschlüsselt, und JEDER Slot-Schlüssel trägt die User-ID
  /// (`eatova.v1.outbox.<uid>`, siehe local_cache.dart) — ein anderer Nutzer
  /// auf demselben Gerät liest seinen eigenen, leeren Namensraum, nie diesen.
  ///
  /// Seit Luecke D kann in dem erhaltenen Slot auch eine Profil-Op liegen
  /// (Gewicht, Ziele, Diät). Dieselbe Begründung trägt: verschlüsselt, nach
  /// User-ID getrennt, und der Preis für den Gegenfall wäre, dem Nutzer seine
  /// letzte Profiländerung beim Ausloggen wegzunehmen. Der Cache-Slot
  /// `eatova.v1.profile.<uid>` fällt wie bisher.
  Future<void> signOutCleanup() async {
    // Zustellversuch VOR dem Verwerfen: online ist die Queue danach leer und
    // es bleibt beim vollständigen Räumen wie bisher.
    await _replayOutbox();
    // Die pendenden Lifetime-Deltas sind ein EIGENER Zustand, kein Teil der
    // Outbox: der Mahlzeiten-Write kann gelingen, während
    // `increment_lifetime_stats` (eigener RPC) scheitert. Dann ist die Queue
    // leer und die Deltas stehen — also braucht auch dieser Kanal seinen
    // Zustellversuch, sonst zieht der Logout die Streak-Grundlage weg.
    // Nach dem Replay: der holt seit Fix 3 zwar keine Buendel-Deltas mehr nach
    // (er zaehlt ueber eigene statsIncrement-Eintraege, die er im selben Lauf
    // mit zustellt), aber ein waehrend des Replays fertig werdender Live-Write
    // kann noch ein Delta buchen — und ein hier bereits pendendes Buendel muss
    // so oder so vor dem Raeumen seinen Zustellversuch bekommen.
    await _flushStatsDelta();
    // Nur was die Zustellung nicht losgeworden ist, rechtfertigt einen
    // überlebenden Slot. Maßgeblich ist der Store-Zustand — er ist der
    // Spiegel des persistierten Blobs, sobald der Boot gelaufen ist. Beide
    // Kanäle zählen: `preserveOutbox` hält _outboxKey UND _pendingStatsKey.
    final remaining = _outbox.length +
        _pendingMealsDelta.abs() +
        _pendingWeightLogsDelta.abs();
    // D9: die geplanten Erinnerungen sind OS-Zustand und kennen keinen User.
    // Ohne diesen Aufruf zeigt das Familien-Tablet der neu angemeldeten
    // Person abends die Streak-Erinnerung der vorherigen.
    await notificationService.cancelAll();
    // B3: der Health-Zustand ist prozesslokal und kennt keinen User. Ohne
    // diesen Aufruf zeigt Bs Profilkarte weiter As „Synchronisiert".
    _resetHealthConnection();
    // Vor Abschluss der Hydration ist `remaining == 0` keine Aussage — der
    // Blob der Vorsession haengt dann noch unbesehen im Store. Konservativ
    // erhalten: ein faelschlich behaltener leerer Slot kostet nichts, ein
    // faelschlich geraeumter kostet bis zu 500 nicht quittierte Writes (A2).
    await _clearCache(preserveOutbox: remaining > 0 || !_syncStateHydrated);
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
    // Die Fotos eigener Rezepte liegen NICHT im LocalCache, sondern als
    // Dateien im App-Verzeichnis — ohne diesen Aufruf ueberlebte ein
    // Kuechenfoto den Logout auf dem Geraet. Es faellt unter dieselbe
    // M-1-Begruendung wie die Rezeptzeile selbst (Audit 2026-06-09) und
    // deshalb auch bei `preserveOutbox: true`: die Outbox traegt Zeilen,
    // keine Bytes.
    //
    // Folge, bewusst in Kauf genommen: Spielt nach einem Re-Login ein noch
    // offener Rezept-Upsert nach, traegt die Zeile weiter ihren
    // `local:`-Marker ohne Bytes — die Anzeige faellt dann sauber auf den
    // Platzhalter zurueck. Ein zurueckgelassenes Foto waere der schlechtere
    // Tausch.
    await RecipeImageStore.instance.clear();
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
    // Sentinel-Rest A1: ohne echte Hydrationsquelle (Cache unlesbar UND
    // Server-Boot leer) besteht der Zustand aus reinen Ctor-Defaults. Die zu
    // schreiben hiesse, den vorhandenen (nur gerade unlesbaren) Bestand mit
    // Fantasie zu ueberschreiben — und der NAECHSTE Boot laese sie als echte
    // Quelle, womit die Clobber-Sperre von applySettings aufginge und die
    // Defaults auf den Server wanderten. Kein Wissen -> kein Snapshot.
    if (!_hydratedFromRealSource) return;
    await cache.writeProfile(profile);
    await cache.writeLifetimeStats(lifetimeStats);
    await cache.writeLoggedMeals(_cacheableLoggedMeals());
    await cache.writeFavorites(favorites);
    await cache.writeWeightLog(weightLog);
    // Luecke A: ohne diese Zeile lag NUR das gerade angelegte Rezept im Cache
    // (Write-Through), die vom Server geladenen dagegen nie — ein Kaltstart
    // ohne Netz zeigte dann eine leere Eigen-Rezept-Liste.
    await cache.writeUserRecipes(_userRecipes);
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

  void _cacheUserRecipes() {
    _cache?.writeUserRecipesDebounced(_userRecipes);
  }

  void _persistOutbox() {
    // Luecke F: der In-Memory-Stand ist NUR dann eine gueltige Fassung des
    // Blobs, wenn die Hydration ihn lesen konnte. Sonst ist `_outbox` eine
    // frische Queue aus dieser Sitzung, und sie hier zu schreiben vernichtet
    // bis zu [kOutboxMaxOps] fremde, nie zugestellte Writes.
    if (_outboxHydrationFailed) {
      unawaited(_repairOutboxHydration());
      return;
    }
    unawaited(_cache?.writeOutbox(_outbox) ?? Future<void>.value());
  }

  /// Holt eine gescheiterte Outbox-Hydration nach, bevor zum ersten Mal
  /// geschrieben wird.
  ///
  /// Warum ein zweiter Versuch statt einer dauerhaften Schreibsperre: eine
  /// Sperre auf Lebenszeit der Sitzung waere bei einem DAUERHAFT unlesbaren
  /// Blob der schlimmere Fehler — die Sitzung koennte dann nie mehr etwas
  /// kill-sicher ablegen, und zwar in jeder folgenden Sitzung wieder. Der
  /// zweite Lesevorgang trennt genau die beiden Faelle:
  ///
  ///  * er GELINGT -> der erste Fehler war voruebergehend. Die gelesenen Ops
  ///    sind die aelteren und kommen vor die der Sitzung; danach schreibt der
  ///    normale Pfad die vereinigte Queue.
  ///  * er scheitert erneut -> der Blob ist mit diesem Code nicht lesbar und
  ///    damit auch nie zustellbar. Er ist bereits verloren, und ihn stehen zu
  ///    lassen wuerde nur die Writes DIESER Sitzung mit in den Abgrund ziehen.
  ///    Ab hier gilt wieder der normale Schreibpfad.
  ///
  /// Gelesen wird ueber die WERFENDE Variante (W7b): mit dem toleranten
  /// [LocalCache.readOutbox] liefen die beiden Faelle, die dieser Pfad gerade
  /// trennen soll, wieder zusammen — ein kaputter Blob kam als `null` an,
  /// also ununterscheidbar von „Slot leer", und der zweite Fehlschlag lief
  /// still an Log und Crash-Report vorbei.
  ///
  /// Laeuft hoechstens einmal gleichzeitig; danach ist [_outboxHydrationFailed]
  /// in beiden Faellen false, der Pfad also einmalig.
  Future<void> _repairOutboxHydration() async {
    if (_outboxRepairInFlight) return;
    _outboxRepairInFlight = true;
    List<SyncOp>? blob;
    try {
      blob = await _cache?.readOutboxOrThrow();
    } catch (e, st) {
      dev.log('Outbox-Nachhydration fehlgeschlagen — der persistierte Blob '
          'ist unlesbar und damit ohnehin unzustellbar',
          error: e, stackTrace: st, name: 'eatova_sync');
      unawaited(CrashReporter.capture(e, st, context: 'outbox-rehydrate'));
    } finally {
      _outboxRepairInFlight = false;
      _outboxHydrationFailed = false;
    }
    if (_disposed) return;
    if (blob != null && blob.isNotEmpty) {
      CrashReporter.breadcrumb('outbox-rehydrate: ${blob.length} ops restored');
      // Die Ops der Sitzung auf die nachgelesenen legen — dieselbe Mechanik
      // wie beim regulaeren Einreihen (Koaleszenz pro Entitaet, FIFO), damit
      // aus dem Zusammenfuehren keine Doppelbuchung entsteht.
      var vereint = blob;
      for (final op in _outbox) {
        vereint = enqueueCoalesced(vereint, op);
      }
      final capped = capOutbox(vereint);
      _outbox = capped.queue;
      if (capped.dropped.isNotEmpty) {
        // Wie beim regulaeren Cap in [_enqueueOp] — und anders als beim Cap
        // waehrend der Hydration: dort raeumt der unmittelbar folgende
        // Boot-Load die Sache ohnehin auf, hier ist der Boot laengst durch.
        final lostDeletes = capped.dropped.where((o) => o.isDelete).toList();
        if (lostDeletes.isNotEmpty) {
          unawaited(_restoreDroppedDeletes(lostDeletes));
        }
        _notifyDroppedOps(capped.dropped);
      }
      // Die nachgeholten Writes sind dem Zustand bisher unbekannt (die
      // Hydration hat sie nie gesehen) — ohne diesen Schritt laege z.B. eine
      // offline geloggte Mahlzeit in der Queue, waere im Tagebuch aber nicht
      // zu sehen.
      _mutate(_applyPendingOpsToState);
      _scheduleOutboxRetry();
    }
    _persistOutbox();
  }

  void _persistPendingStatsDeltas() {
    // W7b, exakt die Bremse aus [_persistOutbox]: der In-Memory-Stand ist NUR
    // dann eine gueltige Fassung des Slots, wenn die Hydration ihn lesen
    // konnte. Sonst sind `_pendingMealsDelta`/`_pendingWeightLogsDelta` die
    // Zahlen dieser Sitzung, und sie hier zu schreiben vernichtet die
    // liegengebliebenen Deltas der Vorsession samt ihrer Anfrage-Id.
    if (_statsHydrationFailed) {
      unawaited(_repairStatsHydration());
      return;
    }
    unawaited(_cache?.writePendingStatsDeltas(
          meals: _pendingMealsDelta,
          weightLogs: _pendingWeightLogsDelta,
          requestId: _pendingStatsRequestId,
        ) ??
        Future<void>.value());
  }

  /// Holt eine gescheiterte Deltas-Hydration nach, bevor zum ersten Mal
  /// geschrieben wird — die Entsprechung zu [_repairOutboxHydration], mit
  /// derselben Begruendung und demselben Ablauf (zweiter Lesevorgang statt
  /// dauerhafter Schreibsperre; gelingt er, sind die nachgelesenen Zahlen die
  /// aelteren und werden addiert; scheitert er erneut, war der Slot ohnehin
  /// verloren und der normale Schreibpfad uebernimmt wieder).
  ///
  /// Ebenfalls ueber die werfende Lesevariante, sonst kaeme ein kaputter Slot
  /// als „ist halt leer" an und der Fehlschlag bliebe unsichtbar.
  ///
  /// Laeuft hoechstens einmal gleichzeitig; danach ist [_statsHydrationFailed]
  /// in beiden Faellen false, der Pfad also einmalig.
  Future<void> _repairStatsHydration() async {
    if (_statsRepairInFlight) return;
    _statsRepairInFlight = true;
    ({int meals, int weightLogs, String? requestId})? blob;
    try {
      blob = await _cache?.readPendingStatsDeltasOrThrow();
    } catch (e, st) {
      dev.log('Deltas-Nachhydration fehlgeschlagen — der persistierte Slot '
          'ist unlesbar und damit ohnehin nicht mehr verbuchbar',
          error: e, stackTrace: st, name: 'eatova_sync');
      unawaited(
          CrashReporter.capture(e, st, context: 'pending-stats-rehydrate'));
    } finally {
      _statsRepairInFlight = false;
      _statsHydrationFailed = false;
    }
    if (_disposed) return;
    if (blob != null && (blob.meals != 0 || blob.weightLogs != 0)) {
      // Nur die Tatsache, keine Zahlen: der Slot fuehrt Mahlzeiten- und
      // Gewichts-Zaehler, und dieser Text geht ins Reporting.
      CrashReporter.breadcrumb('pending-stats-rehydrate: deltas restored');
      _pendingMealsDelta += blob.meals;
      _pendingWeightLogsDelta += blob.weightLogs;
      // Die Id des NACHGELESENEN Buendels gewinnt, nicht die der Sitzung: von
      // beiden kann nur sie serverseitig schon verbucht sein (sie gehoert zu
      // einem Flush, der gescheitert sein KANN, nachdem der Server committet
      // hat). Dieselbe Abwaegung wie in [_flushStatsDelta]: lieber ein
      // begrenzter Ausfall im Abbruchfenster als eine dauerhafte
      // Ueberzaehlung, die kein Pfad je wieder korrigiert. Der Boot-Pfad kommt
      // mit `??=` zum selben Ergebnis — dort ist die Sitzungs-Id noch nie
      // gesetzt.
      final wiedergefunden = blob.requestId;
      if (wiedergefunden != null) _pendingStatsRequestId = wiedergefunden;
      _scheduleOutboxRetry();
    }
    _persistPendingStatsDeltas();
  }

  // --- Streak-Tage (Zweitpruefung 2026-08-10) -------------------------------

  /// Reiht einen getrackten Logging-Tag in die Outbox ein, dessen RPC gerade
  /// gescheitert ist.
  ///
  /// Warum ueberhaupt: bis hierher war [_recordTrackingDay] ein reines
  /// fire-and-forget. Sein Fehler ging an dev.log + CrashReporter und war
  /// damit erledigt — kein Retry, kein Cache-Merker, keine Op. Der
  /// optimistische lokale Stand hielt nicht einmal eine Sekunde: der auf 600 ms
  /// entprellte [_flushStatsDelta] adoptierte danach die frische Serverzeile,
  /// die den Tag naturgemaess nicht kennt, und [_cacheLifetimeStats] schrieb
  /// den Verlust anschliessend fest. Die Streak war gerissen, obwohl der
  /// Nutzer geloggt hatte und die Mahlzeit angekommen war.
  ///
  /// Bewusst KEIN zweiter Persistenz-Kanal neben der Outbox: der haette sich
  /// jede Eigenschaft, die die Outbox schon hat (Kill-Sicherheit, FIFO,
  /// Koaleszenz, Queue-Cap, Versuchs-Budget, Backoff, Verlust-Meldung,
  /// Erhalt beim Logout), noch einmal selbst bauen muessen — und genau solche
  /// halbfertigen Zweitmechaniken sind der Stoff, aus dem der naechste Befund
  /// gemacht ist. Der Tag ist idempotent nachspielbar, also gehoert er in die
  /// vorhandene Queue.
  void _queueTrackingDay(DateTime day) {
    if (sync == null || _disposed) return;
    _enqueueOp(SyncOp.trackingDay(localDayKey(day)));
    _scheduleOutboxRetry();
  }

  /// Nimmt einen Tag wieder aus der Queue, dessen RPC LIVE durchgekommen ist.
  ///
  /// Ohne diesen Schritt bliebe eine aeltere, gescheiterte Op fuer denselben
  /// Tag liegen und wuerde spaeter ein zweites Mal abgespielt. Das waere
  /// schadlos (der RPC ist pro Tag idempotent), aber es ist ein Request, den
  /// niemand braucht — und eine Op, die die Queue beim Logout festhaelt.
  /// Legt noch nicht zugestellte Streak-Tage wieder ueber eine frisch
  /// adoptierte Serverzeile. Muss innerhalb eines `_mutate`-Blocks laufen.
  ///
  /// Ohne diesen Schritt haette [_queueTrackingDay] nur den halben Weg
  /// gemacht: der Tag laege zwar kill-sicher in der Queue, die ANZEIGE spraenge
  /// aber trotzdem sofort auf „Streak gerissen" — [_flushStatsDelta] adoptiert
  /// 600 ms nach dem Log die frische Serverzeile, und die kennt den
  /// gescheiterten Tag naturgemaess nicht. Genau dasselbe Muster wie
  /// [_applyPendingOpsToState] beim Boot, hier bewusst auf den einen Kanal
  /// beschraenkt: der Stats-Flush laeuft entprellt bei JEDER Mutation, und die
  /// volle Ueberlagerung ueber bis zu [kOutboxMaxOps] Ops (inklusive
  /// Neusortierung des Tagebuchs) gehoert nicht in diesen heissen Pfad.
  ///
  /// [LifetimeStats.recordTrackedDay] ist pro Tag idempotent und fuer Tage vor
  /// dem zuletzt gezaehlten ein No-op — die Reihenfolge in der Queue (FIFO,
  /// also chronologisch) traegt damit von selbst.
  void _overlayPendingTrackingDays() {
    for (final op in _outbox) {
      if (op.kind != SyncOpKind.trackingDay) continue;
      final tag = DateTime.tryParse(op.entityId);
      if (tag != null) lifetimeStats = lifetimeStats.recordTrackedDay(tag);
    }
  }

  void _clearQueuedTrackingDay(String localDay) {
    final gefiltert = _outbox
        .where((o) =>
            !(o.kind == SyncOpKind.trackingDay && o.entityId == localDay))
        .toList();
    if (gefiltert.length == _outbox.length) return;
    _outbox = gefiltert;
    _persistOutbox();
  }

  // --- Lifetime-Stats-Deltas ------------------------------------------------

  /// Bucht ein Lebenszeit-Delta ins pendende Buendel.
  ///
  /// Seit Fix 3 ist das exklusiv der LIVE-Pfad (`onDelivered` in
  /// home_store_meals/home_store_tracking). Der Replay zaehlt ueber seinen
  /// eigenen [SyncOpKind.statsIncrement]-Eintrag — nicht hierueber: dieser
  /// Slot committet SOFORT, die Op fiel erst einen Write spaeter aus der
  /// Outbox, und ein Kill dazwischen zaehlte beim naechsten Boot doppelt.
  void _queueStatsDelta({
    int meals = 0,
    int weightLogs = 0,
  }) {
    if (sync == null) return;
    _pendingMealsDelta += meals;
    _pendingWeightLogsDelta += weightLogs;
    // Ein frisches Buendel bekommt seine Anfrage-Id hier — und NUR hier.
    // `??=` ist der ganze Punkt: solange das Buendel offen ist (also bis es
    // verbucht wurde), behaelt es seine Id, egal wie viele Deltas noch
    // dazukommen und wie oft der Flush scheitert.
    _pendingStatsRequestId ??= uuidV4();
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
    // Bestandsdaten: ein Buendel, das ein aelterer Build persistiert hat (oder
    // das die Boot-Hydration ohne Id vorgefunden hat), traegt keine — es wird
    // hier nachtraeglich eine vergeben, statt an `null` zu scheitern oder das
    // Buendel zu verwerfen. Ab diesem Moment gilt fuer es dieselbe Regel wie
    // fuer jedes andere: sie bleibt, bis es verbucht ist.
    final requestId = _pendingStatsRequestId ?? uuidV4();
    _pendingMealsDelta = 0;
    _pendingWeightLogsDelta = 0;
    // Die Id wird MIT den Zahlen zurueckgesetzt: was waehrend des Fluges neu
    // eingereiht wird, gehoert zu einem anderen Buendel und bekommt in
    // [_queueStatsDelta] seine eigene Id. Wuerde es diese hier erben, koennte
    // der Server es als Wiederholung abtun und es waere still verloren.
    _pendingStatsRequestId = null;
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
        requestId: requestId,
      );
      if (!_disposed) {
        _mutate(() {
          lifetimeStats = fresh;
          // Die Serverzeile ist fuer die ZAEHLER autoritativ, fuer einen noch
          // nicht zugestellten Streak-Tag nicht — genau hier verschwand er.
          _overlayPendingTrackingDays();
        });
      }
      _cacheLifetimeStats();
      _onSyncSuccess();
    } catch (e, st) {
      // DATA-7: kein roter Fehler-Toast, kein Rollback — die Deltas gehen
      // zurueck in die (persistierte) Queue und laufen ueber die Retry-Pfade.
      //
      // Frueher war genau das der Preis (Audit 2026-08-14, Befund B): der RPC
      // war rein additiv, ein Abbruch NACH dem Commit liess das Wiedereinreihen
      // ein zweites Mal zaehlen, und `meals_logged` stand dauerhaft zu hoch —
      // ohne Neuberechnungspfad. Seit der Server `p_request_id` kennt
      // (Migration 20260814120000_audit_rls_guard.sql) traegt das Buendel
      // seinen Idempotenz-Schluessel mit: der Retry sendet DIESELBE Id, eine
      // bereits verbuchte wird serverseitig erkannt und nicht noch einmal
      // addiert. Deshalb geht hier auch die Id zurueck in den pendenden Stand —
      // mit einer frisch erzeugten waere der Retry fuer den Server ein neuer
      // Vorgang und der Schutz eine Fassade.
      //
      // Bleibt ein enger Rest: wurde WAEHREND des Fluges ein neues Buendel
      // eroeffnet, verschmelzen beide hier zu einem, und dessen Id ist die des
      // gescheiterten (nur die kann serverseitig schon verbucht sein). Kam der
      // gescheiterte Aufruf doch durch, zaehlt die Handvoll waehrend des Fluges
      // geloggter Deltas nicht mit. Das ist ein begrenzter AUSFALL im seltenen
      // Abbruchfenster statt einer dauerhaften Ueberzaehlung — und der weit
      // haeufigere Fall (Offline-Flush, der den Server nie erreicht hat) bleibt
      // vollstaendig korrekt.
      dev.log('Statistik-Sync failed — Deltas bleiben gequeued',
          error: e, name: 'eatova_sync');
      unawaited(CrashReporter.capture(e, st, context: 'lifetime-stats-flush'));
      _pendingMealsDelta += meals;
      _pendingWeightLogsDelta += weightLogs;
      _pendingStatsRequestId = requestId;
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
