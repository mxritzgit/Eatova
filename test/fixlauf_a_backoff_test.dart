import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/sync_outbox.dart';

import 'fixlauf_a_helpers.dart';

// Review 2026-08-27, F1-03: `_scheduleOutboxRetry` cancelled and re-armed the
// backoff timer on EVERY failure and escalated the stage each time. Four
// offline meals in two minutes restarted the timer at 30 -> 60 -> 120 -> 240 s,
// so the first replay came four minutes after the last log.
//
// Contract: arm only while no timer is active; escalate only when a replay
// pass ends with ops still blocked.

FixlaufSetup _bootOnline(FakeAsync async) {
  // No client dispose: the teardown would run outside the fake zone.
  final s = fixlaufSetup(disposeClient: false);
  s.server.profileRow = serverProfileRow(completedProfile);
  s.store.start();
  async.flushMicrotasks();
  async.elapse(Duration.zero);
  async.flushMicrotasks();
  expect(s.store.profile.onboardingCompleted, isTrue, reason: 'Vorbedingung');
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('zwei Fehlschlaege kurz nacheinander: der Timer bleibt bei 30 s ab dem '
      'ERSTEN Fehlschlag', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      s.server.offline = true;

      s.store.addResultToDailyTotal(mealResult('Eins'));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20));
      s.store.addResultToDailyTotal(mealResult('Zwei'));
      async.flushMicrotasks();
      // Two meal inserts (plus their recents upserts) sit in the queue.
      expect(s.store.pendingOutbox.where((o) => o.kind == SyncOpKind.mealInsert),
          hasLength(2),
          reason: 'Vorbedingung');

      // t = 25 s: network is back.
      async.elapse(const Duration(seconds: 5));
      s.server.offline = false;
      // t = 31 s: the timer armed at t = 0 fires at 30 s.
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();

      expect(s.store.pendingOutbox, isEmpty,
          reason: 'der zweite Fehlschlag darf den 30-s-Timer weder neu starten '
              'noch auf 60 s eskalieren');
      expect(s.server.requestsTo('/logged_meals', method: 'POST'), hasLength(2));
    });
  });

  test('Eskalation nur am Replay-Ende: 30 s, dann 60 s, dann 120 s', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      s.server.offline = true;
      s.store.addResultToDailyTotal(mealResult('Eins'));
      async.flushMicrotasks();

      // t = 30 s: first replay fails -> stage 2 (60 s) is armed -> t = 90.
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      // t = 60 s: another offline write must not touch the armed timer.
      async.elapse(const Duration(seconds: 30));
      s.store.addResultToDailyTotal(mealResult('Zwei'));
      async.flushMicrotasks();
      s.server.offline = false;
      // t = 89 s: not yet.
      async.elapse(const Duration(seconds: 29));
      async.flushMicrotasks();
      expect(s.store.pendingOutbox.where((o) => o.kind == SyncOpKind.mealInsert),
          hasLength(2),
          reason: 'der Timer der zweiten Stufe steht bei 60 s (t = 90 s)');
      // t = 91 s.
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(s.store.pendingOutbox, isEmpty);
    });
  });

  test('nach einem Erfolg beginnt die Leiter wieder bei 30 s', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      s.server.offline = true;
      s.store.addResultToDailyTotal(mealResult('Eins'));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30)); // fails -> stage 60 s
      async.flushMicrotasks();
      s.server.offline = false;
      async.elapse(const Duration(seconds: 60)); // replayed at t = 90
      async.flushMicrotasks();
      expect(s.store.pendingOutbox, isEmpty, reason: 'Vorbedingung');

      s.server.offline = true;
      s.store.addResultToDailyTotal(mealResult('Zwei'));
      async.flushMicrotasks();
      s.server.offline = false;
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();

      expect(s.store.pendingOutbox, isEmpty,
          reason: 'die Stufe wurde beim Erfolg zurueckgesetzt');
    });
  });

  test('ein Resume-/Backgrounding-Flush erhoeht die Stufe NICHT', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      s.server.offline = true;
      s.store.addResultToDailyTotal(mealResult('Eins'));
      async.flushMicrotasks(); // armed at 30 s (t = 30), stage 0

      // t = 10 s: the app goes to the background -> flush -> replay fails.
      async.elapse(const Duration(seconds: 10));
      s.store.flushPendingWrites();
      async.flushMicrotasks();

      // t = 30 s: the timer pass fails -> stage 1 -> armed at 60 s (t = 90).
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      s.server.offline = false;
      async.elapse(const Duration(seconds: 59)); // t = 89
      async.flushMicrotasks();
      expect(s.store.pendingOutbox.where((o) => o.kind == SyncOpKind.mealInsert),
          hasLength(1),
          reason: 'Vorbedingung: der 60-s-Timer steht noch');
      async.elapse(const Duration(seconds: 2)); // t = 91
      async.flushMicrotasks();

      expect(s.store.pendingOutbox, isEmpty,
          reason: 'haette der Resume-Flush die Stufe erhoeht, staende der '
              'Timer bei 120 s (t = 150)');
    });
  });

  test('nur Stats-Deltas offen: der Timer eskaliert ueber den Tick und '
      'liefert nach, sobald das Netz zurueck ist', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      // Delivered meal -> pending delta -> the debounced flush hits an
      // outage.
      s.store.addResultToDailyTotal(mealResult('Eins'));
      async.flushMicrotasks();
      s.server.offline = true;
      async.elapse(const Duration(seconds: 1)); // debounce 600 ms -> fails
      async.flushMicrotasks();
      expect(s.server.mealsCounted, 0, reason: 'Vorbedingung');
      expect(s.store.debugOutboxRetryStage, 0,
          reason: 'Vorbedingung: der Wecker steht auf der ersten Stufe');

      // t = 31 s: the tick has no replay end to escalate at (the outbox is
      // empty, the meal went live), so it climbs the ladder itself before the
      // flush — which fails again and arms at 60 s.
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(s.store.debugOutboxRetryStage, 1,
          reason: 'ohne die Eskalation im Tick tickte der Delta-Kanal ewig im '
              '30-s-Takt');

      s.server.offline = false;
      async.elapse(const Duration(seconds: 61)); // t = 92 s
      async.flushMicrotasks();

      expect(s.server.mealsCounted, 1,
          reason: 'der Timer bedient auch den Stats-Kanal');
      // The reset that _onSyncSuccess owns: no replay pass runs here (empty
      // outbox), so the end-of-pass reset cannot cover for it. Without it the
      // next delta would wait 60 s instead of 30 s, and after four outages
      // 4 min.
      expect(s.store.debugOutboxRetryStage, 0,
          reason: 'der Erfolg setzt die Leiter zurueck');
    });
  });
}
