import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart'
    show kOutboxRepairMaxAttempts, kOutboxRepairMinSpacing;
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../outbox/outbox_test_helpers.dart';

// Review 2026-08-31, B: the repair budget for a slot that is present but
// merely unreadable RIGHT NOW (P3-02b) promised `kOutboxRepairMaxAttempts`
// attempts and delivered something else — twice over.
//
//  * The bound was `attempts < kOutboxRepairMaxAttempts` AFTER the `++`, so
//    only two of the documented three attempts ever protected the blob.
//  * The counter hung on the wrong quantity: EVERY machine-triggered persist
//    ran through the brake (enqueue, dequeue after delivery, one per replayed
//    op), so a handful of taps in the same second spent the whole budget on a
//    single moment of memory pressure — and the overwrite then destroyed up to
//    `kOutboxMaxOps` undelivered writes of the previous session.
//
// Nothing pinned either number down: the existing suites only asked whether
// the session eventually wins, never how many chances the blob got or how far
// apart they were.

const String _uid = 'user-outbox';
const String _outboxKey = 'eatova.v1.outbox.$_uid';
const String _deltaKey = 'eatova.v1.pending_stats.$_uid';

/// Pinned wall clock; the suites move it by hand.
final DateTime _jetzt = DateTime(2026, 8, 31, 9);

/// An undelivered meal from a previous session, as the persisted outbox holds
/// it.
LoggedMeal _alteMahlzeit() => LoggedMeal(
      id: 'm-alt',
      result: mealResult('Alt-Bowl'),
      loggedAt: DateTime(2026, 8, 30, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-30',
    );

/// Cache whose OUTBOX read cannot EXECUTE — the transient case (P3-02b): the
/// storage still holds the bytes, only the decryption fails to run (isolate
/// spawn, OOM). Writes stay real, so an overwrite really is possible here.
class _BlockierterOutboxCache extends LocalCache {
  _BlockierterOutboxCache(super.store, super.userId);

  bool blockiert = true;
  int leseversuche = 0;

  @override
  Future<List<SyncOp>?> readOutboxOrThrow() {
    leseversuche++;
    if (!blockiert) return super.readOutboxOrThrow();
    return Future<List<SyncOp>?>.error(
        const UnreadableCacheSlot('outbox', 'IsolateSpawnException'));
  }
}

/// Same for the deltas slot (W7b).
class _BlockierterDeltaCache extends LocalCache {
  _BlockierterDeltaCache(super.store, super.userId);

  bool blockiert = true;
  int leseversuche = 0;

  @override
  Future<({int meals, int weightLogs, String? requestId})?>
      readPendingStatsDeltasOrThrow() {
    leseversuche++;
    if (!blockiert) return super.readPendingStatsDeltasOrThrow();
    return Future<({int meals, int weightLogs, String? requestId})?>.error(
        const UnreadableCacheSlot('pending_stats', 'IsolateSpawnException'));
  }
}

/// One undelivered op of a previous session in the persisted outbox.
Future<InMemoryKeyValueStore> _mitOffenerOp() async {
  final kv = InMemoryKeyValueStore();
  await LocalCache(kv, _uid)
      .writeOutbox(<SyncOp>[SyncOp.mealInsert(_alteMahlzeit(), trackDay: false)]);
  return kv;
}

/// Three never-booked meals in the persisted deltas slot.
Future<InMemoryKeyValueStore> _mitOffenenDeltas() async {
  final kv = InMemoryKeyValueStore();
  await LocalCache(kv, _uid).writePendingStatsDeltas(
      meals: 3, weightLogs: 0, requestId: 'rid-alt');
  return kv;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Outbox-Reparaturbudget', () {
    test(
        'ein Schwall Ereignisse im SELBEN Moment verbraucht hoechstens einen '
        'Versuch', () async {
      await withClock(Clock.fixed(_jetzt), () async {
        final kv = await _mitOffenerOp();
        final vorher = kv.snapshot[_outboxKey];

        final cache = _BlockierterOutboxCache(kv, _uid);
        final a = setup(injizierterCache: cache);
        a.server.offline = true;
        await boot(a.store);
        expect(a.store.pendingOutbox, isEmpty,
            reason: 'Vorbedingung: die Hydration hat den Blob nicht gesehen');
        final nachBoot = cache.leseversuche;

        // Deutlich mehr maschinelle Persist-Ereignisse als das Budget
        // Versuche kennt — und alle in derselben Sekunde, weil die Uhr steht.
        for (var i = 0; i < kOutboxRepairMaxAttempts + 3; i++) {
          a.store.addResultToDailyTotal(mealResult('Bowl-$i'));
          await settle();
        }

        expect(cache.leseversuche - nachBoot,
            greaterThan(kOutboxRepairMaxAttempts),
            reason: 'Vorbedingung des Befunds: es gab mehr Reparatur-Lese'
                'vorgaenge als das Budget Versuche hat — genau die haben '
                'frueher heimlich mitgezaehlt');
        expect(kv.snapshot[_outboxKey], vorher,
            reason: 'mehrere Lesevorgaenge im selben Moment sind EINE Chance, '
                'nicht mehrere: der Ausloeser (kein Isolate, kein Speicher) '
                'hatte keine Sekunde Zeit zu vergehen. Wer hier ueber'
                'schreibt, nimmt bis zu $kOutboxMaxOps nie zugestellte Writes '
                'der Vorsitzung mit');
      });
    });

    test(
        'die dokumentierten Versuche schuetzen den Blob wirklich alle — erst '
        'der Versuch danach gibt den Slot frei', () async {
      var jetzt = _jetzt;
      await withClock(Clock(() => jetzt), () async {
        final kv = await _mitOffenerOp();
        final vorher = kv.snapshot[_outboxKey];

        final cache = _BlockierterOutboxCache(kv, _uid);
        final a = setup(injizierterCache: cache);
        a.server.offline = true;
        await boot(a.store);

        // Pro Durchlauf genau EIN gezaehlter Fehlversuch: die Uhr steht
        // waehrend der Mahlzeit und rueckt erst danach weiter, egal wie viele
        // Persist-Aufrufe dabei anfallen.
        for (var i = 0; i < kOutboxRepairMaxAttempts; i++) {
          a.store.addResultToDailyTotal(mealResult('Bowl-$i'));
          await settle();
          expect(kv.snapshot[_outboxKey], vorher,
              reason: 'Versuch ${i + 1} von $kOutboxRepairMaxAttempts muss '
                  'noch schuetzen — mit `attempts < kOutboxRepairMaxAttempts` '
                  'nach dem ++ schuetzten nur zwei, und der dritte '
                  'ueberschrieb den intakten Blob');
          jetzt = jetzt.add(kOutboxRepairMinSpacing);
        }

        // Der Versuch NACH dem Budget: ab hier gewinnt die Haltbarkeit dieser
        // Sitzung, sonst stuende sie dauerhaft ohne Persistenz da.
        a.store.addResultToDailyTotal(mealResult('Bowl-danach'));
        await settle();

        expect(kv.snapshot[_outboxKey], isNot(vorher),
            reason: 'ein Slot, der den vollen Bremsweg lang nicht aufgeht, '
                'darf die Sitzung nicht dauerhaft ohne Persistenz lassen — '
                'sonst nimmt ein Kill ALLE neuen Writes mit');
      });
    });

    test('eine rueckwaerts springende Wanduhr friert die Bremse nicht ein',
        () async {
      var jetzt = _jetzt;
      await withClock(Clock(() => jetzt), () async {
        final kv = await _mitOffenerOp();
        final vorher = kv.snapshot[_outboxKey];

        final cache = _BlockierterOutboxCache(kv, _uid);
        final a = setup(injizierterCache: cache);
        a.server.offline = true;
        await boot(a.store);

        // Zeitzonenwechsel oder NTP-Korrektur: die Wanduhr geht zurueck.
        for (var i = 0; i < kOutboxRepairMaxAttempts + 1; i++) {
          jetzt = jetzt.subtract(const Duration(minutes: 5));
          a.store.addResultToDailyTotal(mealResult('Bowl-$i'));
          await settle();
        }

        expect(kv.snapshot[_outboxKey], isNot(vorher),
            reason: 'eine Uhr, die zurueckspringt, ist kein Beleg dafuer, '
                'dass keine Zeit verging — wer das als „zu frueh" liest, '
                'haelt die Bremse, bis die Uhr aufgeholt hat, und die Sitzung '
                'legt bis dahin gar nichts mehr kill-sicher ab');
      });
    });

    test(
        'die nie zugestellten Ops der Vorsitzung sind nach dem Schutz noch da',
        () async {
      await withClock(Clock.fixed(_jetzt), () async {
        final kv = await _mitOffenerOp();

        final cache = _BlockierterOutboxCache(kv, _uid);
        final a = setup(injizierterCache: cache);
        a.server.offline = true;
        await boot(a.store);

        for (var i = 0; i < kOutboxRepairMaxAttempts + 3; i++) {
          a.store.addResultToDailyTotal(mealResult('Bowl-$i'));
          await settle();
        }

        // Der Engpass ist vorbei: der naechste Write liest den Slot wieder
        // und legt beide Schlangen zusammen.
        cache.blockiert = false;
        final zuletzt = a.store.addResultToDailyTotal(mealResult('Letzte'));
        await settle();

        final blob = await LocalCache(kv, _uid).readOutbox();
        expect(blob!.map((o) => o.entityId),
            containsAll(<String>['m-alt', zuletzt]),
            reason: 'geschuetzt heisst nicht verloren: was die Vorsitzung nie '
                'zugestellt hat, muss nach dem Engpass wieder auftauchen — '
                'sonst war der Schutz nur ein aufgeschobener Verlust');
      });
    });
  });

  group('Deltas-Reparaturbudget', () {
    test(
        'ein Schwall Fluesse im SELBEN Moment verbraucht hoechstens einen '
        'Versuch', () async {
      await withClock(Clock.fixed(_jetzt), () async {
        final kv = await _mitOffenenDeltas();
        final vorher = kv.snapshot[_deltaKey];

        final cache = _BlockierterDeltaCache(kv, _uid);
        final a = setup(injizierterCache: cache);
        await boot(a.store);
        final nachBoot = cache.leseversuche;

        // Die Mahlzeit geht durch, nur increment_lifetime_stats scheitert:
        // genau die Lage, die ein Delta bucht und den Slot neu schreibt.
        a.server.statsOffline = true;
        for (var i = 0; i < kOutboxRepairMaxAttempts + 3; i++) {
          a.store.addResultToDailyTotal(mealResult('Bowl-$i'));
          await settle();
          a.store.flushPendingWrites();
          await settle();
        }

        expect(cache.leseversuche - nachBoot,
            greaterThan(kOutboxRepairMaxAttempts),
            reason: 'Vorbedingung: jeder Flush lief durch die Bremse und hat '
                'frueher einen Versuch verbraucht');
        expect(kv.snapshot[_deltaKey], vorher,
            reason: 'derselbe Fehler wie bei der Outbox: die nie verbuchten '
                'Mahlzeiten der Vorsitzung duerfen nicht an einem einzigen '
                'Speicherengpass haengen bleiben');
      });
    });

    test('die dokumentierten Versuche schuetzen die Zahlen wirklich alle',
        () async {
      var jetzt = _jetzt;
      await withClock(Clock(() => jetzt), () async {
        final kv = await _mitOffenenDeltas();
        final vorher = kv.snapshot[_deltaKey];

        final cache = _BlockierterDeltaCache(kv, _uid);
        final a = setup(injizierterCache: cache);
        await boot(a.store);
        a.server.statsOffline = true;

        for (var i = 0; i < kOutboxRepairMaxAttempts; i++) {
          a.store.addResultToDailyTotal(mealResult('Bowl-$i'));
          await settle();
          a.store.flushPendingWrites();
          await settle();
          expect(kv.snapshot[_deltaKey], vorher,
              reason: 'Versuch ${i + 1} von $kOutboxRepairMaxAttempts muss '
                  'noch schuetzen — `_statsRepairAttempts < '
                  'kOutboxRepairMaxAttempts` schuetzte nur zwei');
          jetzt = jetzt.add(kOutboxRepairMinSpacing);
        }

        a.store.addResultToDailyTotal(mealResult('Bowl-danach'));
        await settle();
        a.store.flushPendingWrites();
        await settle();

        expect(kv.snapshot[_deltaKey], isNot(vorher),
            reason: 'auch hier ist der Bremsweg begrenzt: sonst faellt jede '
                'Mahlzeit dieser Sitzung dauerhaft aus dem kill-sicheren '
                'Slot');
      });
    });
  });
}
