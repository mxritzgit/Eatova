import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../outbox/outbox_test_helpers.dart';

// K2 (Review 2026-08-31) — ein verbrannter Wiederholungsversuch durch falsche
// Reihenfolge.
//
// `_applyLoggedMealDetails` reiht den Tag ABSICHTLICH hinter den Upsert ein
// (P1-05): `record_tracking_day` zaehlt einen Tag nur gegen eine
// logged_meals-Zeile mit diesem local_day (Quellnachweis der Migration
// 20260811120000), sonst P0001 / EX_DAY_NOT_LOGGED.
//
// Startet ein Replay aber, BEVOR der PATCH committet ist, greift die
// FIFO-Zusage nicht: der mealUpsert wird als „im Flug" uebersprungen, die
// Tages-Op laeuft dadurch ZUERST und faellt in den Quellnachweis. Das
// klassifiziert als retryCounted — einer von acht Zustellversuchen ist weg,
// dazu ein Sentry-Sync-Ereignis, und das fuer eine Op, die zu diesem Zeitpunkt
// gar nicht funktionieren KONNTE.
//
// Die Entitaets-Sperre kann das nicht sehen: Mahlzeit und Tag sind zwei
// Entitaeten (`meal:<uuid>` vs. `tracking:<Tag>`).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Fester Zeitpunkt (K-02): der Test bucht auf HEUTE und haengt damit am
  /// Kalender.
  final jetzt = DateTime(2026, 5, 14, 12, 30);
  Future<void> anTag(Future<void> Function() koerper) =>
      withClock(Clock.fixed(jetzt), koerper);

  /// Wie viele record_tracking_day-Anfragen den Server seit [ab] erreicht
  /// haben.
  int buchungen(FakeServer server, [int ab = 0]) => server.requests
      .skip(ab)
      .where((r) => r.url.path.contains('/rpc/record_tracking_day'))
      .length;

  /// Fuer gestern gelogged, heute noch leer — der Ausgangszustand des Befunds.
  Future<({String id, DateTime heute})> nachtragVonGestern(
      HomeStore store) async {
    final heute = DateUtils.dateOnly(clock.now());
    final id = store.addResultToDailyTotal(mealResult('Nachtrag'),
        foodDate: heute.subtract(const Duration(days: 1)));
    await settle();
    // Das Stats-Buendel des Live-Logs sofort buchen: seine 600-ms-Entprellung
    // waere sonst ein zweiter, rein zeitabhaengiger Ausloeser fuer
    // `_onSyncSuccess` — und damit fuer ein Replay — mitten im Messfenster.
    store.flushPendingWrites();
    await settle();
    return (id: id, heute: heute);
  }

  test(
      'K2: die Tages-Op geht nicht raus, solange der Mahlzeiten-Write fuer '
      'denselben Tag noch im Flug ist — und danach doch',
      () => anTag(() async {
            final s = setup();
            s.server.enforceTrackingDaySourceProof = true;
            await boot(s.store);
            final vor = await nachtragVonGestern(s.store);
            expect(s.server.trackedDay, isNull,
                reason: 'Vorbedingung: heute ist noch leer');

            // Der PATCH haengt: die Zeile fuer heute existiert noch nicht.
            s.server.holdMealWrites();
            s.store.updateLoggedMealDetails(vor.id, day: clock.now());
            await settle();
            expect(
                s.store.pendingOutbox.map((o) => o.kind).toList(),
                <SyncOpKind>[SyncOpKind.mealUpsert, SyncOpKind.trackingDay],
                reason: 'Vorbedingung: der Tag steht hinter dem Upsert in der '
                    'Queue, und der Upsert ist im Flug');

            // Ein Zeuge, den derselbe Durchlauf zustellen MUSS: ohne ihn waere
            // „keine Buchung" auch dann wahr, wenn ueberhaupt kein Replay
            // gelaufen ist.
            s.server.offline = true;
            await s.store.createUserRecipe(userRecipe('beweis'));
            await settle();
            s.server.offline = false;
            expect(
                s.store.pendingOutbox.map((o) => o.kind).toList(),
                <SyncOpKind>[
                  SyncOpKind.mealUpsert,
                  SyncOpKind.trackingDay,
                  SyncOpKind.recipeUpsert,
                ],
                reason: 'Vorbedingung: der Zeuge steht HINTER der Tages-Op');

            final abHier = s.server.requests.length;
            // Ein fremder Live-Write, der durchgeht: sein `_onSyncSuccess`
            // startet das Replay — waehrend der PATCH noch haengt.
            s.store.toggleFavorite(mealResult('Lieblingsbowl'));
            await settle();

            expect(s.server.recipeRows.keys, contains('beweis'),
                reason: 'Vorbedingung: der Durchlauf ist wirklich gelaufen und '
                    'bis hinter die Tages-Op gekommen');
            expect(buchungen(s.server, abHier), 0,
                reason: 'PostgREST kennt keinen Timeout: solange der PATCH '
                    'haengt, steht die Zeile noch auf gestern — jede Buchung '
                    'waere ein verbrannter Zustellversuch (P0001)');
            expect(s.server.trackingDayRejections, isEmpty);
            final tagesOp = s.store.pendingOutbox
                .where((o) => o.kind == SyncOpKind.trackingDay)
                .single;
            expect(tagesOp.attempts, 0,
                reason: 'kein Versuch darf auf eine Op gehen, die zu diesem '
                    'Zeitpunkt nicht funktionieren KONNTE');

            // Und die andere Richtung: uebersprungen heisst nicht liegen
            // gelassen.
            s.server.releaseMealWrites();
            await settle();

            expect(buchungen(s.server, abHier), 1,
                reason: 'nach dem PATCH muss der Tag doch noch rausgehen');
            expect(s.server.trackingDayRejections, isEmpty);
            expect(s.server.trackedDay, localDayKey(vor.heute));
            expect(s.store.pendingOutbox, isEmpty,
                reason: 'sonst haengt die Streak bis zum naechsten '
                    'Lebenszyklus-Ereignis');
          }));
}
