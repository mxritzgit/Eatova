import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../outbox/outbox_test_helpers.dart';

// K2-Nachlauf (Review 2026-08-31) — die Tages-Op muss auch waehrend eines
// laufenden Replays koaleszieren.
//
// `_enqueueOp` schaltet auf reines Anhaengen, solange ein Replay-Durchlauf
// die Queue abgeht: er koennte gerade die Op zustellen, deren Nutzlast beim
// Zusammenfuehren verloren ginge. Eine `trackingDay`-Op HAT keine Nutzlast —
// sie ist nichts als ihr Entitaets-Schluessel `tracking:<Tag>`, der RPC ist
// pro Tag idempotent, und sie bucht keinen Zaehler. Zwei Ops desselben Tages
// sind austauschbar, nicht zwei Zustaende einer Entitaet.
//
// Das Fenster ist keine Theorie: `_onSyncSuccess` startet nach JEDEM fremden
// Live-Write ein Replay, und der `catchError` von `_recordTrackingDay` faellt
// genau dort hinein. Ohne die Ausnahme wuchs die Queue deshalb pro Log um eine
// voellig identische Op — bis der Queue-Deckel echte Writes verdraengt.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Fester Zeitpunkt (K-02): der Test haengt sonst am Kalender.
  final jetzt = DateTime(2026, 5, 14, 12, 30);
  Future<void> anTag(Future<void> Function() koerper) =>
      withClock(Clock.fixed(jetzt), koerper);

  /// Wie viele record_tracking_day-Anfragen den Server ab [ab] erreicht haben.
  int buchungen(FakeServer server, [int ab = 0]) => server.requests
      .skip(ab)
      .where((r) => r.url.path.contains('/rpc/record_tracking_day'))
      .length;

  List<SyncOp> tagesOps(HomeStore store) => store.pendingOutbox
      .where((o) => o.kind == SyncOpKind.trackingDay)
      .toList();

  test(
      'K2-Nachlauf: acht Logs am selben Tag hinterlassen EINE Tages-Op — die '
      'Queue waechst nicht mit, obwohl jeder Log ein Replay startet',
      () => anTag(() async {
            final s = setup();
            await boot(s.store);
            s.server.rejectTrackingDay = true;

            for (var i = 1; i <= 8; i++) {
              s.store.addResultToDailyTotal(mealResult('Bowl $i'));
              await settle();
            }

            expect(tagesOps(s.store), hasLength(1),
                reason: 'die Op ist durch ihren Schluessel vollstaendig '
                    'beschrieben — ein zweites Exemplar traegt nichts und '
                    'kostet einen Platz im Queue-Deckel');
            expect(s.store.pendingOutbox, hasLength(1),
                reason: 'und sonst darf gar nichts liegen bleiben: Mahlzeiten '
                    'und Favoriten sind live durchgegangen');
            expect(
                (await s.cache.readOutbox())!
                    .where((o) => o.kind == SyncOpKind.trackingDay),
                hasLength(1),
                reason: 'der persistierte Blob ist die Queue, die der naechste '
                    'Start erbt — dort waere das Wachstum dauerhaft');
          }));

  test(
      'K2-Nachlauf: die zusammengefuehrte Tages-Op wird danach genau EINMAL '
      'zugestellt und verlaesst die Queue',
      () => anTag(() async {
            final s = setup();
            await boot(s.store);
            s.server.rejectTrackingDay = true;

            for (var i = 1; i <= 3; i++) {
              s.store.addResultToDailyTotal(mealResult('Bowl $i'));
              await settle();
            }
            expect(tagesOps(s.store), hasLength(1), reason: 'Vorbedingung');

            // Nur der Replay, kein neuer Log: was jetzt an Buchungen kommt,
            // kommt aus der Queue.
            final abHier = s.server.requests.length;
            s.server.rejectTrackingDay = false;
            s.store.flushPendingWrites();
            await settle();

            expect(buchungen(s.server, abHier), 1,
                reason: 'zusammengefuehrt heisst EIN Vorgang — mehrere Ops '
                    'waeren mehrere identische RPCs');
            expect(s.server.trackedDay, localDayKey(jetzt),
                reason: 'und der Tag muss serverseitig wirklich ankommen, '
                    'sonst haette das Zusammenfuehren ihn verschluckt');
            expect(tagesOps(s.store), isEmpty,
                reason: 'zugestellt heisst: die Op ist wieder raus');
          }));
}
