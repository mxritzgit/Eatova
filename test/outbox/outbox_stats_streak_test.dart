import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_error_messages.dart'
    show outboxDeleteLossHint, outboxLossHint;
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/uuid.dart' show deriveStatsRequestId;

import 'outbox_test_helpers.dart';

// The two RPC-backed families: increment_lifetime_stats (additive, so every
// retry needs the SAME request id) and record_tracking_day (the streak day,
// which used to be pure fire-and-forget).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Pendende Stats-Deltas ueberleben den App-Neustart', () async {
    final kv = InMemoryKeyValueStore();

    // Session 1: meal sync fine, stats RPC fails, so the delta stays.
    final a = setup(kv: kv);
    await boot(a.store);
    a.server.statsOffline = true;
    a.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();
    a.store.flushPendingWrites();
    await settle();

    expect(a.server.mealsCounted, 0);
    final pending = await a.cache.readPendingStatsDeltas();
    expect(pending, isNotNull);
    expect(pending!.meals, 1);

    final b = setup(kv: kv);
    await boot(b.store);

    expect(b.server.mealsCounted, 1);
    final after = await b.cache.readPendingStatsDeltas();
    expect(after!.meals, 0, reason: 'Delta wurde verbucht, nicht dupliziert');
  });

  // --- Finding B: idempotency key of the stats deltas -----------------------
  //
  // `increment_lifetime_stats` ADDS, so a drop after the commit re-queues the
  // same delta. The server tracks consumed `p_request_id`, which only helps if
  // the client resends the SAME id.

  test(
      'Retry des Stats-Deltas sendet DIESELBE Anfrage-Id — auch ueber einen '
      'Kaltstart hinweg; erst ein verbuchtes Buendel bekommt eine neue',
      () async {
    final kv = InMemoryKeyValueStore();

    final a = setup(kv: kv);
    await boot(a.store);
    a.server.statsOffline = true;
    a.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();
    a.store.flushPendingWrites();
    await settle();

    expect(a.server.statsRequestIds, isNotEmpty,
        reason: 'der Flush muss den Server ueberhaupt erreicht haben');
    final id = a.server.statsRequestIds.first;
    expect(id, isNotNull, reason: 'ohne Id ist der Aufruf rein additiv');
    expect(a.server.statsRequestIds.toSet(), <String?>{id},
        reason: 'mehrere Versuche desselben Buendels sind EIN Vorgang');

    // The id lives with the bundle, or an app kill makes the retry a new op.
    expect((await a.cache.readPendingStatsDeltas())!.requestId, id);

    // Session 2 (cold start): the boot flush is the retry, with the FIRST id.
    final b = setup(kv: kv);
    b.server.statsOffline = true;
    await boot(b.store);
    b.store.flushPendingWrites();
    await settle();

    expect(b.server.statsRequestIds, isNotEmpty);
    expect(b.server.statsRequestIds.toSet(), <String?>{id},
        reason: 'eine frisch erzeugte Id koennte der Server nicht als '
            'Wiederholung erkennen — er wuerde ein zweites Mal addieren');

    b.server.statsOffline = false;
    b.store.flushPendingWrites();
    await settle();
    expect(b.server.statsRequestIds.last, id);
    expect(b.server.mealsCounted, 1);
    expect((await b.cache.readPendingStatsDeltas())!.meals, 0);

    // Counter-check: a NEW bundle needs a new id, else the server dismisses it.
    b.store.addResultToDailyTotal(mealResult('Zweite Bowl'));
    await settle();
    b.store.flushPendingWrites();
    await settle();
    expect(b.server.statsRequestIds.last, isNot(id));
    expect(b.server.mealsCounted, 2);
  });

  test(
      'Bestandsdaten: ein persistiertes Buendel OHNE Anfrage-Id (aelterer '
      'Build) geht nicht verloren — es bekommt eine nachtraeglich, und die '
      'haelt', () async {
    final kv = InMemoryKeyValueStore();
    // The old wire form: numbers, no 'request_id'.
    await LocalCache(kv, 'user-outbox')
        .writePendingStatsDeltas(meals: 2, weightLogs: 1);

    final s = setup(kv: kv);
    s.server.statsOffline = true;
    await boot(s.store);
    s.store.flushPendingWrites();
    await settle();

    // Neither tripped up by `null` nor dropped: sent with a retrofitted id …
    expect(s.server.statsRequestIds, isNotEmpty);
    final id = s.server.statsRequestIds.first;
    expect(id, isNotNull);
    expect(s.server.statsRequestIds.toSet(), <String?>{id});

    // … which now lives with the bundle, keeping further attempts one op.
    final pending = await s.cache.readPendingStatsDeltas();
    expect(pending!.requestId, id);
    expect(pending.meals, 2);
    expect(pending.weightLogs, 1);

    s.server.statsOffline = false;
    s.store.flushPendingWrites();
    await settle();
    expect(s.server.mealsCounted, 2);
    expect(s.server.weightLogsCounted, 1);
  });

  // --- Fix 3: exactly-once counters for replayed ops ------------------------
  //
  // The replay was idempotent for CONTENT but not for its COUNTER: the +1 was
  // persisted before the op left the outbox, so an app kill made the next boot
  // count the meal twice. Fix 3 creates a statsIncrement entry ATOMICALLY with
  // removing the source op, keyed on an id DERIVED from the source UUID.

  test(
      'Fix 3: Kill nach der Replay-Zustellung, VOR der Op-Entfernung — der '
      'naechste Boot zaehlt die Mahlzeit NICHT ein zweites Mal', () async {
    const mealId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final abgeleitet = deriveStatsRequestId(mealId)!;
    final kv = InMemoryKeyValueStore();
    // ONE server for both sessions: its dedup state must survive the restart.
    final server = FakeServer();
    // The previous session's blob: one stranded meal, UUID-shaped so a request
    // id can be derived.
    await seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.mealInsert(
        LoggedMeal(
            id: mealId,
            result: mealResult('Kill-Bowl'),
            loggedAt: DateTime.now()),
        trackDay: false,
      ).toJson(),
    ]);

    // Session A: delivery and increment land, the OUTBOX write does not.
    final a = setup(
      kv: kv,
      geteilterServer: server,
      injizierterCache: EingefrorenerOutboxCache(kv, 'user-outbox'),
    );
    await boot(a.store);
    // Short-circuit the bundle-flush debounce, else the +1 never leaves memory.
    a.store.flushPendingWrites();
    await settle();

    expect(server.mealRows.keys, contains(mealId),
        reason: 'Vorbedingung: die Mahlzeit ist zugestellt');
    expect(server.mealsCounted, 1,
        reason: 'Vorbedingung: sie ist genau einmal gezaehlt');
    expect(kv.snapshot['eatova.v1.outbox.user-outbox'],
        contains('"entity_id":"$mealId"'),
        reason: 'Vorbedingung: der persistierte Blob traegt die Op WEITERHIN '
            '— sonst prueft dieser Test gar nichts');
    // No explicit dispose(): the "kill" is just the state left on storage.

    final b = setup(kv: kv, geteilterServer: server);
    await boot(b.store);
    b.store.flushPendingWrites();
    await settle();

    expect(server.mealsCounted, 1,
        reason: 'DER Befund: vorher buchte der Boot-Replay ein zweites +1 — '
            'unter frischer Buendel-Id, also fuer den Server ein neuer '
            'Vorgang, den nichts deduplizieren konnte');
    expect(
        server.statsRequestIds
            .whereType<String>()
            .where((id) => id == abgeleitet),
        hasLength(greaterThanOrEqualTo(2)),
        reason: 'Sitzung A verbucht, Sitzung B wiederholt — und beide senden '
            'DIESELBE, aus der Meal-UUID abgeleitete Id');
    expect(server.verbrauchteStatsIds, <String>{abgeleitet},
        reason: 'serverseitig ist das EIN Vorgang, kein zweiter');
    expect(server.mealRows, hasLength(1),
        reason: 'Beifang: der Inhalt war schon immer idempotent');
    expect(b.store.pendingOutbox, isEmpty);
    expect(await b.cache.readOutbox(), isEmpty,
        reason: 'nach dem zweiten Lauf ist der Blob wirklich leer');
  });

  test(
      'Fix 3: ein serverseitig bereits verbuchter statsIncrement-Eintrag '
      'verlaesst die Queue als ERFOLG, ohne erneut zu addieren', () async {
    const rid = '6561746f-7661-6d73-f461-74732d726964';
    final kv = InMemoryKeyValueStore();
    // The previous session delivered it; only the ANSWER was lost.
    await seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.statsIncrement(requestId: rid, meals: 1).toJson(),
    ]);

    final s = setup(kv: kv);
    s.server.verbrauchteStatsIds.add(rid);
    s.server.mealsCounted = 1;
    await boot(s.store);

    expect(s.server.statsRequestIds, contains(rid),
        reason: 'Vorbedingung: der Retry hat den Server erreicht');
    expect(s.server.mealsCounted, 1,
        reason: 'FOUND-Zweig der Migration: eine verbrauchte Id addiert nicht '
            'noch einmal, sie liefert nur die aktuelle Zeile');
    expect(s.store.pendingOutbox, isEmpty,
        reason: 'der Eintrag ist kein Gift — das Server-Verhalten macht den '
            'Retry gruen, er wird als Erfolg abgeraeumt');
    expect(await s.cache.readOutbox(), isEmpty);
  });

  test(
      'Fix 3: faellt increment_lifetime_stats aus, bleibt NUR der '
      'Zaehler-Eintrag liegen — mit stabiler Id ueber Versuche und Neustarts',
      () async {
    final kv = InMemoryKeyValueStore();
    final server = FakeServer();

    final a = setup(kv: kv, geteilterServer: server);
    await boot(a.store);
    server.offline = true;
    final mealId = a.store.addResultToDailyTotal(mealResult('Nachhol-Bowl'));
    await settle();
    expect(a.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert),
        reason: 'Vorbedingung');

    server.offline = false;
    server.statsOffline = true;
    a.store.flushPendingWrites();
    await settle();

    final abgeleitet = deriveStatsRequestId(mealId)!;
    expect(server.mealRows.keys, contains(mealId),
        reason: 'der Inhalt ist durch — nur sein Zaehler nicht');
    expect(a.store.pendingOutbox.map((o) => o.kind).toList(),
        <SyncOpKind>[SyncOpKind.statsIncrement],
        reason: 'Mahlzeit, Favorit und Streak-Tag sind zugestellt; liegen '
            'bleibt genau der Zaehler');
    expect(a.store.pendingOutbox.single.entityId, abgeleitet,
        reason: 'die entityId IST die Request-Id');
    expect((await a.cache.readPendingStatsDeltas())?.meals ?? 0, 0,
        reason: 'DER Beweis, dass der alte Pfad tot ist: der Replay fasst das '
            'Buendel nicht mehr an (vorher stand hier 1)');
    expect(server.statsRequestIds, contains(abgeleitet));

    // Cold start, RPC still broken: the boot replay retries.
    final b = setup(kv: kv, geteilterServer: server);
    await boot(b.store);
    b.store.flushPendingWrites();
    await settle();

    expect(b.store.pendingOutbox.map((o) => o.kind).toList(),
        <SyncOpKind>[SyncOpKind.statsIncrement]);
    expect(server.statsRequestIds.whereType<String>().toSet(),
        <String>{abgeleitet},
        reason: 'eine pro Versuch neu erzeugte Id koennte der Server nicht als '
            'Wiederholung erkennen — er wuerde ein zweites Mal addieren');

    server.statsOffline = false;
    b.store.flushPendingWrites();
    await settle();

    expect(server.mealsCounted, 1);
    expect(server.verbrauchteStatsIds, <String>{abgeleitet});
    expect(b.store.pendingOutbox, isEmpty);
  });

  test(
      'Fix 3: dasselbe fuer das Gewicht — der nachgeholte weightInsert zaehlt '
      'ueber seinen eigenen Eintrag, nicht ueber das Buendel', () async {
    final s = setup();
    await boot(s.store);

    // Applied but answered 500, so the live path does NOT count.
    s.server.ambiguousWrites = true;
    s.store.logWeight(80.5);
    await settle();
    final op = s.store.pendingOutbox
        .singleWhere((o) => o.kind == SyncOpKind.weightInsert);
    final abgeleitet = deriveStatsRequestId(op.entityId)!;

    s.server.ambiguousWrites = false;
    s.store.flushPendingWrites();
    await settle();

    expect(s.server.weightLogsCounted, 1);
    expect(s.server.statsRequestIds, <String?>[abgeleitet],
        reason: 'genau EIN Increment, und seine Id ist aus der weight_log-UUID '
            'abgeleitet — kein Buendel beteiligt');
    expect((await s.cache.readPendingStatsDeltas())?.weightLogs ?? 0, 0);
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'Fix 3: Op-Entfernung und Zaehler-Eintrag sind EIN Blob-Schreibvorgang '
      '— es gibt keinen persistierten Zustand ohne beide', () async {
    // Genau das ist der Fix: „Created ATOMICALLY with the op's removal (same
    // blob write)". Zwei Schreibvorgaenge liessen den Zwischenstand
    // „Mahlzeit zugestellt und aus der Queue, Zaehler noch nicht eingereiht"
    // auf der Platte stehen — ein Kill dort zaehlt die Mahlzeit NIE, und der
    // naechste Boot findet nichts mehr, was es nachholen koennte. Der
    // Endzustand ist in beiden Faellen identisch, also kann ihn nur die
    // FOLGE der Schreibvorgaenge unterscheiden.
    const mealId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final abgeleitet = deriveStatsRequestId(mealId)!;
    final kv = InMemoryKeyValueStore();
    await seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.mealInsert(
        LoggedMeal(
            id: mealId,
            result: mealResult('Atom-Bowl'),
            loggedAt: DateTime.now()),
        trackDay: false,
      ).toJson(),
    ]);

    final mitschrift = OutboxSchreibMitschrift(kv, 'user-outbox');
    final s = setup(kv: kv, injizierterCache: mitschrift);
    // Nur increment_lifetime_stats faellt aus: der Folgeeintrag bleibt liegen
    // und ist damit in den persistierten Blobs sichtbar.
    s.server.statsOffline = true;
    await boot(s.store);
    await pumpUntil(() => s.store.pendingOutbox
        .any((o) => o.kind == SyncOpKind.statsIncrement));

    expect(s.server.mealRows.keys, contains(mealId),
        reason: 'Vorbedingung: die Mahlzeit ist zugestellt');
    final ohneMahlzeit = mitschrift.eintraege
        .indexWhere((keys) => !keys.contains('meal:$mealId'));
    expect(ohneMahlzeit, isNonNegative,
        reason: 'Vorbedingung: die Quell-Op hat den Blob verlassen');
    expect(mitschrift.eintraege[ohneMahlzeit], contains('stats:$abgeleitet'),
        reason: 'DER Kern: in dem Moment, in dem die Quell-Op aus dem Blob '
            'verschwindet, MUSS ihr Zaehler schon darin stehen — sonst gibt '
            'es ein Kill-Fenster, in dem die Mahlzeit zugestellt, aber fuer '
            'immer ungezaehlt ist');
  });

  test(
      'Fix 3: eine Korrektur WAEHREND des laufenden Insert-Writes wird '
      'angehaengt, nicht koalesziert — sonst zaehlt dieselbe Mahlzeit zweimal',
      () async {
    // Die Ausschliesslichkeit der beiden Zaehlwege ist die ganze Garantie:
    // live bucht `onDelivered` unter der Buendel-Id, der Replay unter der aus
    // der Meal-UUID abgeleiteten. Zwei verschiedene Vorgaenge serverseitig —
    // sie deduplizieren einander NICHT. Koalesziert die Korrektur die
    // fliegende Op weg, verschwindet die Instanz, deren Live-Erfolg zaehlt
    // (`_dequeueDeliveredOp` sucht ueber Identitaet), die verschmolzene Op ist
    // weiterhin ein mealInsert — und der Replay bucht ein zweites +1.
    final s = setup();
    await boot(s.store);

    // Der Live-Insert haengt: seine Op liegt schon in der Queue (Luecke B),
    // die Entitaet steht in _inFlightOps.
    s.server.holdMealWrites();
    final id = s.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();
    expect(s.store.pendingOutbox.map((o) => o.kind).toList(),
        <SyncOpKind>[SyncOpKind.mealInsert],
        reason: 'Vorbedingung: der Write fliegt, seine Op wartet');

    s.store.updateLoggedMealResult(id, mealResult('Bowl', kcal: 500));
    await settle();

    expect(s.store.pendingOutbox.map((o) => o.kind).toList(),
        <SyncOpKind>[SyncOpKind.mealInsert, SyncOpKind.mealUpsert],
        reason: 'die Korrektur muss ANGEHAENGT werden — eine Ersetzung nimmt '
            'die Op mit, deren Live-Zustellung gerade zaehlt');

    s.server.releaseMealWrites();
    await pumpUntil(() => s.store.pendingOutbox.isEmpty);
    s.store.flushPendingWrites(); // Buendel-Debounce abkuerzen
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows[id]!['calories_kcal'], 500,
        reason: 'der juengere Stand gewinnt trotzdem');
    expect(s.server.mealsCounted, 1,
        reason: 'DER Kern: einmal live gebucht. Ein Replay-Zaehler zusaetzlich '
            'traegt eine andere Id und kann serverseitig nicht dedupliziert '
            'werden');
    expect(s.server.statsRequestIds.whereType<String>(),
        isNot(contains(deriveStatsRequestId(id))),
        reason: 'der abgeleitete Zaehler gehoert dem Replay-Pfad — hier hat '
            'der Live-Pfad gebucht, beide zusammen waeren die Doppelzaehlung');
  });

  test(
      'Fix 3: der Verwurf eines Zaehler-Eintrags ist STILL — er ist kein '
      'Nutzer-Inhalt, „etwas fehlt" waere die falsche Meldung', () async {
    const rid = '6561746f-7661-6d73-f461-74732d726964';
    final kv = InMemoryKeyValueStore();
    // Budget spent AND older than 24 h: both are required for the drop (A4).
    await seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.statsIncrement(requestId: rid, meals: 1).toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(const Duration(hours: 25))
            .toIso8601String()
        ..['attempts'] = kOutboxMaxAttempts - 1,
    ]);

    final s = setup(kv: kv);
    s.server.statsOffline = true; // an active rejection (500) counts
    await boot(s.store);

    expect(s.store.pendingOutbox, isEmpty, reason: 'verworfen');
    expect(s.server.mealsCounted, 0);
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty,
        reason: 'die Mahlzeit ist laengst zugestellt — es fehlt kein Eintrag, '
            'nur ein Zaehler. Der Snack waere gelogen.');
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()), isEmpty);
  });

  // --- W7b: the brake for the deltas slot -----------------------------------
  //
  // The outbox has one since gap F; the deltas had none, and
  // `_persistPendingStatsDeltas` always rewrites the whole slot.

  test(
      'ein kaputter pending_stats-Slot loest die Bremse aus, statt still eine '
      'leere Menge zu liefern', () async {
    final kv = InMemoryKeyValueStore();
    // Previous session: three unbooked meals in the slot.
    await LocalCache(kv, 'user-outbox')
        .writePendingStatsDeltas(meals: 3, weightLogs: 0, requestId: 'alt-id');

    final cache = DeltaLesefehlerCache(kv, 'user-outbox');
    final s = setup(kv: kv, injizierterCache: cache);
    // The stats RPC stays down so the test really measures the slot.
    s.server.statsOffline = true;
    await boot(s.store);
    expect(cache.leseversuche, 1,
        reason: 'Vorbedingung: die Hydration hat den Slot nicht gesehen');

    // Its delta runs into _persistPendingStatsDeltas.
    s.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();

    expect(cache.leseversuche, greaterThan(1),
        reason: 'ohne Bremse schriebe der Flush den Slot ungeprueft nieder — '
            'die Nachhydration waere toter Code');
    final pending =
        await LocalCache(kv, 'user-outbox').readPendingStatsDeltas();
    expect(pending!.meals, 4,
        reason: 'ein verschluckter Lesefehler liess den Slot bei 0 anfangen: '
            'drei nie verbuchte Mahlzeiten fehlten danach dauerhaft in den '
            'Lebenszeit-Zaehlern');
    expect(pending.requestId, 'alt-id',
        reason: 'die Id des nachgelesenen Buendels gewinnt — nur sie kann '
            'serverseitig schon verbucht sein');
  });

  test(
      'ein DAUERHAFT unlesbarer pending_stats-Slot blockiert das Persistieren '
      'nicht auf Dauer — die Nachhydration laeuft genau einmal', () async {
    final kv = InMemoryKeyValueStore();
    await LocalCache(kv, 'user-outbox')
        .writePendingStatsDeltas(meals: 3, weightLogs: 0);

    final cache = DeltaLesefehlerCache(kv, 'user-outbox', kaputteVersuche: 2);
    final s = setup(kv: kv, injizierterCache: cache);
    s.server.statsOffline = true;
    await boot(s.store);

    s.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();

    expect(cache.leseversuche, 2,
        reason: 'Hydration + GENAU EIN Nachlesevorgang');
    expect(
        (await LocalCache(kv, 'user-outbox').readPendingStatsDeltas())!.meals,
        1,
        reason: 'nach dem zweiten Fehlschlag ist der Slot mit diesem Code '
            'ohnehin nicht mehr verbuchbar — ab da gilt wieder der normale '
            'Schreibpfad, sonst koennte die Sitzung nie mehr etwas ablegen');

    // And every further delta passes without a third read.
    s.store.addResultToDailyTotal(mealResult('Zweite Bowl'));
    await settle();
    expect(cache.leseversuche, 2);
    expect(
        (await LocalCache(kv, 'user-outbox').readPendingStatsDeltas())!.meals,
        2);
  });

  // --- The inventory finding: the streak day had ZERO nets -----------------
  //
  // `_recordTrackingDay` was pure fire-and-forget: no op, no marker, no retry.
  // The optimistic state held 600 ms, then `_flushStatsDelta` adopted the
  // server row that does not know the day and pinned the loss.

  test(
      'Streak-Tag: scheitert record_tracking_day, landet der Tag in der '
      'Outbox statt im Nichts — und die Anzeige haelt, obwohl der Stats-Flush '
      'gleich darauf die Serverzeile adoptiert', () async {
    final s = setup();
    await boot(s.store);
    // ONLY the streak RPC fails, which is why the loss was invisible.
    s.server.rejectTrackingDay = true;

    final id = s.store.addResultToDailyTotal(mealResult('Streak-Bowl'));
    await settle();
    expect(s.server.mealRows.keys, contains(id),
        reason: 'Vorbedingung: an der Mahlzeit selbst liegt es nicht');

    // Let the 600 ms stats-flush debounce elapse: that is when the day was lost.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await settle();

    expect(s.server.mealsCounted, 1,
        reason: 'Vorbedingung: der Zaehler-RPC ist durchgekommen — nur der '
            'Streak-RPC nicht');
    expect(s.store.lifetimeStats.lastTrackedDate, isNotNull,
        reason: 'genau hier sprang die Anzeige auf „Streak gerissen"');
    expect(s.store.lifetimeStats.currentStreak, 1);
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('tracking:${localDayKey(DateTime.now())}'),
        reason: 'ohne Op gab es keine Stelle, die den Tag je nachgeholt '
            'haette');
    expect((await s.cache.readOutbox())!.map((o) => o.kind),
        contains(SyncOpKind.trackingDay),
        reason: 'und sie muss den App-Kill ueberleben wie jeder andere Write');
  });

  test(
      'Streak-Tag: der liegengebliebene Tag ueberlebt den Kaltstart und wird '
      'beim naechsten Start nachgeholt', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(a.store);
    a.server.rejectTrackingDay = true;
    a.store.addResultToDailyTotal(mealResult('Streak-Bowl'));
    await settle();
    a.store.flushPendingWrites();
    await settle();
    expect(a.server.trackedDay, isNull, reason: 'Vorbedingung: nicht angekommen');

    final b = setup(kv: kv);
    await boot(b.store);

    expect(b.server.trackedDay, localDayKey(DateTime.now()),
        reason: 'der Boot-Replay muss den Tag serverseitig nachtragen — sonst '
            'reisst die Streak beim naechsten Log, weil der Server eine '
            'Luecke sieht');
    expect(b.store.lifetimeStats.lastTrackedDate, isNotNull);
    expect(
        b.store.pendingOutbox
            .where((o) => o.kind == SyncOpKind.trackingDay),
        isEmpty,
        reason: 'zugestellt heisst: die Op ist wieder raus');
  });

  test(
      'Streak-Tag: mehrfaches Loggen am selben Tag erzeugt EINE Op, nicht eine '
      'pro Mahlzeit', () async {
    final s = setup();
    await boot(s.store);
    s.server.rejectTrackingDay = true;

    s.store.addResultToDailyTotal(mealResult('Bowl 1'));
    await settle();
    s.store.addResultToDailyTotal(mealResult('Bowl 2'));
    await settle();
    s.store.addResultToDailyTotal(mealResult('Bowl 3'));
    await settle();

    expect(
        s.store.pendingOutbox
            .where((o) => o.kind == SyncOpKind.trackingDay)
            .length,
        1,
        reason: 'alle Ops eines Tages teilen den Entitaets-Schluessel und '
            'koaleszieren — sonst waechst die Queue mit jedem Log um eine '
            'voellig identische Op');
  });

  test(
      'Streak-Tag: kommt der RPC LIVE durch, bleibt keine alte Op liegen',
      () async {
    final s = setup();
    await boot(s.store);
    s.server.rejectTrackingDay = true;
    s.store.addResultToDailyTotal(mealResult('Bowl 1'));
    await settle();
    expect(
        s.store.pendingOutbox.where((o) => o.kind == SyncOpKind.trackingDay),
        hasLength(1),
        reason: 'Vorbedingung');

    s.server.rejectTrackingDay = false;
    s.store.addResultToDailyTotal(mealResult('Bowl 2'));
    await settle();

    expect(s.server.trackedDay, localDayKey(DateTime.now()));
    expect(
        s.store.pendingOutbox.where((o) => o.kind == SyncOpKind.trackingDay),
        isEmpty,
        reason: 'eine Op, deren Tag laengst verbucht ist, haelt sonst die '
            'Queue (und damit preserveOutbox beim Logout) unnoetig offen');
  });

  // --- P1-05: order of streak booking vs. meal upsert -----------------------
  //
  // record_tracking_day needs a logged_meals row with local_day = p_day (the
  // source proof of migration 20260811120000), else EX_DAY_NOT_LOGGED /
  // P0001. That proof is exactly what is missing when today holds nothing yet
  // and the user moves a meal from yesterday ONTO today, so the RPC may only
  // reach the server once the upsert has written the row.
  // [FakeServer.enforceTrackingDaySourceProof] mirrors the proof — without it
  // the fake would define the failure away.

  group('P1-05 — Verschieben AUF heute bucht den Tag nach dem Upsert', () {
    /// All tests of this group run under a PINNED clock: they log onto
    /// yesterday and move onto today, which across midnight would silently
    /// become a move onto TOMORROW (K-02, date-dependent tests).
    final jetzt = DateTime(2026, 5, 14, 12, 30);
    Future<void> anTag(Future<void> Function() koerper) =>
        withClock(Clock.fixed(jetzt), koerper);

    /// Logged for yesterday, today still empty — the finding's starting state.
    Future<({String id, DateTime heute})> nachtragVonGestern(
        HomeStore store) async {
      final heute = DateUtils.dateOnly(clock.now());
      final id = store.addResultToDailyTotal(mealResult('Nachtrag'),
          foodDate: heute.subtract(const Duration(days: 1)));
      await settle();
      return (id: id, heute: heute);
    }

    test(
        'live: die RPC erreicht den Server erst NACH dem PATCH und wird beim '
        'ersten Versuch angenommen', () => anTag(() async {
          final s = setup();
          s.server.enforceTrackingDaySourceProof = true;
          await boot(s.store);
          final vor = await nachtragVonGestern(s.store);
          expect(s.server.trackedDay, isNull,
              reason: 'Vorbedingung: heute leer');
          final abHier = s.server.requests.length;

          s.store.updateLoggedMealDetails(vor.id, day: clock.now());
          await settle();

          final danach = s.server.requests.skip(abHier).toList();
          final patch = danach.indexWhere((r) =>
              r.method == 'PATCH' && r.url.path.contains('/logged_meals'));
          final rpc = danach.indexWhere(
              (r) => r.url.path.contains('/rpc/record_tracking_day'));
          expect(patch, isNonNegative,
              reason: 'der Upsert muss rausgegangen sein');
          expect(rpc, isNonNegative, reason: 'der Tag muss gebucht worden sein');
          expect(patch, lessThan(rpc),
              reason: 'die Streak-Buchung vor dem Upsert trifft auf eine '
                  'Zeile, die es fuer heute noch gar nicht gibt');
          expect(s.server.trackingDayRejections, isEmpty,
              reason: 'jede Ablehnung ist ein verbrannter Zustellversuch plus '
                  'ein Sentry-Sync-Ereignis');
          expect(s.server.trackedDay, localDayKey(vor.heute));
          expect(s.store.pendingOutbox, isEmpty,
              reason: 'live zugestellt heisst: nichts bleibt liegen');
        }));

    // P1-05b, Loch 1: dieser Test blieb beim vollstaendigen Rueckbau des Fixes
    // gruen. Der alte `catchError -> _queueTrackingDay`-Pfad landet ebenfalls
    // HINTER dem synchron eingereihten Upsert, also sagte die Reihenfolge
    // allein nichts. Unterscheidend ist der ZEITPUNKT: der eifrige Zwilling
    // steht in der Queue, bevor ueberhaupt eine Antwort da sein koennte.
    test(
        'offline: der Zwilling steht SYNCHRON hinter dem Upsert — vor jeder '
        'Netzantwort; der Replay bucht dann erst die Zeile, dann den Tag',
        () => anTag(() async {
              final s = setup();
              s.server.enforceTrackingDaySourceProof = true;
              await boot(s.store);
              final vor = await nachtragVonGestern(s.store);
              expect(s.store.pendingOutbox, isEmpty, reason: 'Vorbedingung');

              s.server.offline = true;
              s.store.updateLoggedMealDetails(vor.id, day: clock.now());

              // KEIN settle: hier ist noch kein einziger Microtask gelaufen.
              expect(
                  s.store.pendingOutbox.map((o) => o.kind).toList(),
                  <SyncOpKind>[SyncOpKind.mealUpsert, SyncOpKind.trackingDay],
                  reason: 'zwei Zusagen in einer Zeile: FIFO (steht der Tag '
                      'vorn, scheitert der erste Pass zwangslaeufig an '
                      'EX_DAY_NOT_LOGGED) UND unabhaengig vom Netz — ein Tag, '
                      'der erst durch eine Fehlerantwort entsteht, existiert '
                      'im haengenden und im gekillten Fall nie');
              await settle();
              expect((await s.cache.readOutbox())!.map((o) => o.kind),
                  contains(SyncOpKind.trackingDay),
                  reason: 'und kill-sicher, nicht nur im Speicher');

              s.server.offline = false;
              s.store.flushPendingWrites();
              await settle();

              expect(s.server.trackingDayRejections, isEmpty);
              expect(s.server.trackedDay, localDayKey(vor.heute));
              expect(s.store.pendingOutbox, isEmpty);
            }));

    // P1-05b, Loch 2a: der Fall, fuer den der Fix eigentlich gutgeschrieben
    // ist. PostgREST kennt keinen Timeout — ein PATCH, der nie antwortet,
    // feuert weder `then` noch `catchError`. Der alte Pfad lief hier nie, also
    // deckte ihn auch kein Test.
    test(
        'haengender PATCH: der Tag liegt kill-sicher in der Queue, und die '
        'RPC trifft nie auf die noch leere Zeile',
        () => anTag(() async {
              final s = setup();
              s.server.enforceTrackingDaySourceProof = true;
              await boot(s.store);
              final vor = await nachtragVonGestern(s.store);

              s.server.holdMealWrites();
              s.store.updateLoggedMealDetails(vor.id, day: clock.now());
              await settle();

              expect(s.server.trackingDayRejections, isEmpty,
                  reason: 'die Buchung vor dem Upsert trifft hier auf eine '
                      'Zeile, die noch auf gestern steht — P0001, ein '
                      'verbrannter Zustellversuch plus ein Sentry-Ereignis');
              expect(s.server.trackedDay, isNull,
                  reason: 'Vorbedingung: der Upsert haengt, live ist nichts '
                      'gebucht');
              expect((await s.cache.readOutbox())!.map((o) => o.kind),
                  contains(SyncOpKind.trackingDay),
                  reason: 'nur der eingereihte Zwilling haelt den Tag fest — '
                      'ein Pfad, der erst an einer Antwort haengt, bekommt '
                      'hier nie eine');

              // Aufraeumen: die Antwort kommt doch noch.
              s.server.releaseMealWrites();
              await settle();
              expect(s.server.trackedDay, localDayKey(vor.heute));
            }));

    // P1-05b, Loch 2b: der Kill zwischen Bearbeitung und RPC-Antwort. Der
    // PATCH ist durch, die Buchung fliegt — und die App stirbt. Auch hier
    // laeuft weder `then` noch `catchError`.
    test(
        'Kill zwischen Bearbeitung und RPC-Antwort: der Tag ueberlebt im '
        'eingereihten Zwilling und wird beim naechsten Start gebucht',
        () => anTag(() async {
              final kv = InMemoryKeyValueStore();
              final server = FakeServer()
                ..enforceTrackingDaySourceProof = true;

              final a = setup(kv: kv, geteilterServer: server);
              await boot(a.store);
              final vor = await nachtragVonGestern(a.store);

              server.hangTrackingDay = true;
              a.store.updateLoggedMealDetails(vor.id, day: clock.now());
              await settle();
              a.store.flushPendingWrites();
              await settle();

              expect(server.mealRows[vor.id]!['local_day'],
                  localDayKey(vor.heute),
                  reason: 'Vorbedingung: der PATCH ist durch');
              expect(server.trackedDay, isNull,
                  reason: 'Vorbedingung: die Antwort der Buchung steht aus');
              expect((await a.cache.readOutbox())!.map((o) => o.kind),
                  contains(SyncOpKind.trackingDay),
                  reason: 'nur was VOR dem Absenden persistiert wurde, kann '
                      'einen Kill in diesem Fenster ueberleben');

              // Neustart auf demselben Geraet, gegen denselben Server. Die
              // schon abgesetzte Anfrage der toten Sitzung bleibt haengen —
              // nur neue bekommen wieder eine Antwort.
              server.hangTrackingDay = false;
              final b = setup(kv: kv, geteilterServer: server);
              await boot(b.store);

              expect(server.trackedDay, localDayKey(vor.heute),
                  reason: 'sonst sieht der Server eine Luecke und die Streak '
                      'reisst beim naechsten Log');
              expect(
                  b.store.pendingOutbox
                      .where((o) => o.kind == SyncOpKind.trackingDay),
                  isEmpty,
                  reason: 'zugestellt heisst: die Op ist wieder raus');
            }));

    test(
        'Streak bleibt sichtbar, solange der Tag nur in der Queue liegt',
        () => anTag(() async {
              final s = setup();
              await boot(s.store);
              final vor = await nachtragVonGestern(s.store);

              s.server.offline = true;
              s.store.updateLoggedMealDetails(vor.id, day: clock.now());
              await settle();

              expect(s.store.lifetimeStats.lastTrackedDate, vor.heute,
                  reason: 'die optimistische Buchung darf nicht verschwinden, '
                      'nur weil die Zustellung wartet');
            }));
  });
}
