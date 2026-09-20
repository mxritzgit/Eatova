import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// The two RPC-backed families: increment_lifetime_stats (additive, so every
// retry needs the SAME request id) and record_tracking_day (the streak day,
// which used to be pure fire-and-forget).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      HomeStore store,
    ) async {
      final heute = DateUtils.dateOnly(clock.now());
      final id = await store.addResultToDailyTotal(
        mealResult('Nachtrag'),
        foodDate: heute.subtract(const Duration(days: 1)),
      );
      await settle();
      return (id: id, heute: heute);
    }

    test(
      'live: die RPC erreicht den Server erst NACH dem Source-Upsert und wird beim '
      'ersten Versuch angenommen',
      () => anTag(() async {
        final s = setup();
        s.server.enforceTrackingDaySourceProof = true;
        await boot(s.store);
        final vor = await nachtragVonGestern(s.store);
        expect(s.server.trackedDay, isNull, reason: 'Vorbedingung: heute leer');
        final abHier = s.server.requests.length;

        await s.store.updateLoggedMealDetails(vor.id, day: clock.now());
        await settle();

        final danach = s.server.requests.skip(abHier).toList();
        final patch = danach.indexWhere(
          (r) =>
              r.url.path.endsWith('/rpc/apply_sync_operation') &&
              (jsonDecode(r.body) as Map)['p_kind'] == 'mealUpsert',
        );
        final rpc = danach.indexWhere(
          (r) =>
              r.url.path.endsWith('/rpc/apply_sync_operation') &&
              (jsonDecode(r.body) as Map)['p_kind'] == 'trackingDay',
        );
        expect(
          patch,
          isNonNegative,
          reason: 'der Upsert muss rausgegangen sein',
        );
        expect(rpc, isNonNegative, reason: 'der Tag muss gebucht worden sein');
        expect(
          patch,
          lessThan(rpc),
          reason:
              'die Streak-Buchung vor dem Upsert trifft auf eine '
              'Zeile, die es fuer heute noch gar nicht gibt',
        );
        expect(
          s.server.trackingDayRejections,
          isEmpty,
          reason:
              'jede Ablehnung ist ein verbrannter Zustellversuch plus '
              'ein Sentry-Sync-Ereignis',
        );
        expect(s.server.trackedDay, localDayKey(vor.heute));
        expect(
          s.store.pendingOutbox,
          isEmpty,
          reason: 'live zugestellt heisst: nichts bleibt liegen',
        );
      }),
    );

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
        await s.store.updateLoggedMealDetails(vor.id, day: clock.now());

        // KEIN settle: hier ist noch kein einziger Microtask gelaufen.
        expect(
          s.store.pendingOutbox.map((o) => o.kind).toList(),
          <SyncOpKind>[SyncOpKind.mealUpsert, SyncOpKind.trackingDay],
          reason:
              'zwei Zusagen in einer Zeile: FIFO (steht der Tag '
              'vorn, scheitert der erste Pass zwangslaeufig an '
              'EX_DAY_NOT_LOGGED) UND unabhaengig vom Netz — ein Tag, '
              'der erst durch eine Fehlerantwort entsteht, existiert '
              'im haengenden und im gekillten Fall nie',
        );
        await settle();
        expect(
          (await s.cache.readOutbox())!.map((o) => o.kind),
          contains(SyncOpKind.trackingDay),
          reason: 'und kill-sicher, nicht nur im Speicher',
        );

        s.server.offline = false;
        s.store.flushPendingWrites();
        await settle();

        expect(s.server.trackingDayRejections, isEmpty);
        expect(s.server.trackedDay, localDayKey(vor.heute));
        expect(s.store.pendingOutbox, isEmpty);
      }),
    );

    // P1-05b, Loch 2a: der Fall, fuer den der Fix eigentlich gutgeschrieben
    // ist. PostgREST kennt keinen Timeout — ein Source-Upsert, der nie antwortet,
    // feuert weder `then` noch `catchError`. Der alte Pfad lief hier nie, also
    // deckte ihn auch kein Test.
    test(
      'haengender Source-Upsert: der Tag liegt kill-sicher in der Queue, und die '
      'RPC trifft nie auf die noch leere Zeile',
      () => anTag(() async {
        final s = setup();
        s.server.enforceTrackingDaySourceProof = true;
        await boot(s.store);
        final vor = await nachtragVonGestern(s.store);

        s.server.holdMealWrites();
        await s.store.updateLoggedMealDetails(vor.id, day: clock.now());
        await settle();

        expect(
          s.server.trackingDayRejections,
          isEmpty,
          reason:
              'die Buchung vor dem Upsert trifft hier auf eine '
              'Zeile, die noch auf gestern steht — P0001, ein '
              'verbrannter Zustellversuch plus ein Sentry-Ereignis',
        );
        expect(
          s.server.trackedDay,
          isNull,
          reason:
              'Vorbedingung: der Upsert haengt, live ist nichts '
              'gebucht',
        );
        expect(
          (await s.cache.readOutbox())!.map((o) => o.kind),
          contains(SyncOpKind.trackingDay),
          reason:
              'nur der eingereihte Zwilling haelt den Tag fest — '
              'ein Pfad, der erst an einer Antwort haengt, bekommt '
              'hier nie eine',
        );

        // Aufraeumen: die Antwort kommt doch noch.
        s.server.releaseMealWrites();
        await settle();
        expect(s.server.trackedDay, localDayKey(vor.heute));
      }),
    );

    // P1-05b, Loch 2b: der Kill zwischen Bearbeitung und RPC-Antwort. Der
    // Source-Upsert ist durch, die Buchung fliegt — und die App stirbt. Auch hier
    // laeuft weder `then` noch `catchError`.
    test(
      'Kill zwischen Bearbeitung und RPC-Antwort: der Tag ueberlebt im '
      'eingereihten Zwilling und wird beim naechsten Start gebucht',
      () => anTag(() async {
        final kv = InMemoryKeyValueStore();
        final server = FakeServer()..enforceTrackingDaySourceProof = true;

        final a = setup(kv: kv, geteilterServer: server, disposeStore: false);
        await boot(a.store);
        final vor = await nachtragVonGestern(a.store);

        server.hangTrackingDay = true;
        await a.store.updateLoggedMealDetails(vor.id, day: clock.now());
        await settle();
        a.store.flushPendingWrites();
        await settle();

        expect(
          server.mealRows[vor.id]!['local_day'],
          localDayKey(vor.heute),
          reason: 'Vorbedingung: der Source-Upsert ist durch',
        );
        expect(
          server.trackedDay,
          isNull,
          reason: 'Vorbedingung: die Antwort der Buchung steht aus',
        );
        expect(
          (await a.cache.readOutbox())!.map((o) => o.kind),
          contains(SyncOpKind.trackingDay),
          reason:
              'nur was VOR dem Absenden persistiert wurde, kann '
              'einen Kill in diesem Fenster ueberleben',
        );

        // Neustart auf demselben Geraet, gegen denselben Server. Die
        // schon abgesetzte Anfrage der toten Sitzung bleibt haengen —
        // nur neue bekommen wieder eine Antwort.
        a.store.dispose();
        server.hangTrackingDay = false;
        final b = setup(kv: kv, geteilterServer: server);
        await boot(b.store);

        expect(
          server.trackedDay,
          localDayKey(vor.heute),
          reason:
              'sonst sieht der Server eine Luecke und die Streak '
              'reisst beim naechsten Log',
        );
        expect(
          b.store.pendingOutbox.where((o) => o.kind == SyncOpKind.trackingDay),
          isEmpty,
          reason: 'zugestellt heisst: die Op ist wieder raus',
        );
      }),
    );

    test(
      'Streak bleibt sichtbar, solange der Tag nur in der Queue liegt',
      () => anTag(() async {
        final s = setup();
        await boot(s.store);
        final vor = await nachtragVonGestern(s.store);

        s.server.offline = true;
        await s.store.updateLoggedMealDetails(vor.id, day: clock.now());
        await settle();

        expect(
          s.store.lifetimeStats.lastTrackedDate,
          vor.heute,
          reason:
              'die optimistische Buchung darf nicht verschwinden, '
              'nur weil die Zustellung wartet',
        );
      }),
    );
  });
}
