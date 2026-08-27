// Offline logging and replay (DATA-7), end to end through the UI: a meal
// logged while the server is unreachable stays in the diary, sits in the
// persisted outbox, and is delivered EXACTLY ONCE when the app resumes with
// the network back — no duplicate row, no lost line, no double-counted meal.
//
// The unit suites pin the store's outbox in isolation; this one drives the
// same path through the real shell (add sheet -> store -> EatovaSync ->
// PostgREST) over the stateful fake server from test/fixlauf_a_helpers.dart.
// EatovaApp cannot carry a sync (it builds one from `Supabase.instance`), so
// the shell is composed here. Runs in English.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../fixlauf_a_helpers.dart';
import 'flow_test_helpers.dart';

/// What `WidgetsBinding` does on a resume, without the state-machine prelude.
/// This is the shell's only caller of `flushPendingWrites()`.
void _resume(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as WidgetsBindingObserver)
        .didChangeAppLifecycleState(AppLifecycleState.resumed);

/// The outbox as it lies in the STORE — the blob an app kill would leave
/// behind, as opposed to `HomeStore.pendingOutbox`, which is only
/// `List.unmodifiable(_outbox)` over RAM (home_store_sync.dart).
List<SyncOp> _persistierteOutbox(InMemoryKeyValueStore kv) {
  final blob = kv.snapshot['eatova.v1.outbox.$kFixlaufUser'];
  if (blob == null) return const <SyncOp>[];
  final items = (jsonDecode(blob) as Map<String, dynamic>)['items'] as List;
  return items
      .map((e) => SyncOp.tryFromJson((e as Map).cast<String, dynamic>()))
      .whereType<SyncOp>()
      .toList();
}

/// Switches to the Heute tab and reads the eaten tile of the calorie hero.
Future<void> _expectDayTotal(WidgetTester tester, String kcal) async {
  await tester.tap(find.byKey(const ValueKey('nav-Heute')));
  await settleFrames(tester);
  expect(
    find.descendant(
      of: find.byKey(const ValueKey('today-stat-eaten')),
      matching: find.text(kcal),
    ),
    findsOneWidget,
    reason: 'der Heute-Hero nennt nicht $kcal gegessene kcal',
  );
}

void main() {
  testWidgetsRobust(
      'Offline geloggt: UI hält die Zeile, Outbox trägt sie, Replay stellt sie '
      'genau einmal zu',
      (WidgetTester tester) async {
    final server = FixlaufServer()
      ..profileRow = serverProfileRow(completedProfile);
    // Kept, so the assertions below can read the CACHE SLOT, not just the
    // store's in-memory view of it.
    final kv = InMemoryKeyValueStore();
    final store = await pumpSignedIn(tester, server, store: kv);
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget,
        reason: 'ein fertiges Profil darf nicht ins Onboarding führen');

    // ---- 1. The network drops ----------------------------------------------
    server.offline = true;

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await settleFrames(tester);
    await logSalami(tester, 'lunch');

    // ---- 2. The UI keeps the meal although nothing reached the server ------
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget,
        reason: 'ein Serverfehler darf die optimistische Zeile nicht '
            'zurückrollen');
    expect(find.text('252 kcal · 1 entry'), findsOneWidget);
    expect(store.loggedMeals.length, 1);
    final mealId = store.loggedMeals.single.id;
    expect(server.mealRows, isEmpty);
    // GET is the boot load, which ran while the server was still reachable —
    // no WRITE may have arrived.
    expect(server.requestsTo('logged_meals', method: 'POST'), isEmpty,
        reason: 'offline darf kein Write ankommen');

    // ---- 3. The outbox holds the write -------------------------------------
    final queued = store.pendingOutbox
        .where((op) => op.entityKey == 'meal:$mealId')
        .toList();
    expect(queued, hasLength(1),
        reason: 'die fehlgeschlagene Mahlzeit liegt nicht in der Outbox');
    expect(queued.single.kind, SyncOpKind.mealInsert);
    expect(queued.single.trackDay, isTrue,
        reason: 'ein Log für heute muss den Streak-Tag mittragen');

    // …and it is PERSISTED, not merely in RAM. Without this the claim of the
    // suite header ("sits in the persisted outbox") rests on a getter that
    // only wraps a list; an app kill right here would be the loss DATA-7
    // exists against.
    final aufPlatte = _persistierteOutbox(kv);
    expect(aufPlatte.map((op) => op.entityKey).toList(),
        contains('meal:$mealId'),
        reason: 'der Slot eatova.v1.outbox.$kFixlaufUser traegt die Mahlzeit '
            'nicht — ein App-Kill an dieser Stelle verloere sie');
    final persistiert =
        aufPlatte.singleWhere((op) => op.entityKey == 'meal:$mealId');
    expect(persistiert.kind, SyncOpKind.mealInsert);
    expect(persistiert.trackDay, isTrue,
        reason: 'auch der Streak-Tag muss den Kaltstart ueberleben');

    // ---- 4. The network comes back, the resume replays ---------------------
    server.offline = false;
    _resume(tester);
    await pumpUntil(
      tester,
      () => store.pendingOutbox.isEmpty,
      'der Replay leert die Outbox',
    );
    expect(_persistierteOutbox(kv), isEmpty,
        reason: 'der geleerte Replay muss auch den Slot leeren, sonst spielt '
            'der naechste Kaltstart dieselbe Mahlzeit erneut ab');

    expect(server.mealRows.length, 1,
        reason: 'die Mahlzeit fehlt oder liegt doppelt auf dem Server');
    expect(server.mealRows.values.single['id'], mealId);
    expect(server.requestsTo('logged_meals', method: 'POST').length, 1,
        reason: 'der Replay hat dieselbe Mahlzeit mehrfach geschickt');
    expect(server.mealsCounted, 1,
        reason: 'der Lifetime-Zähler hat die Mahlzeit doppelt gebucht');

    // ---- 5. Diary and day total are unchanged: one row, no duplicate -------
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-history-entry-1')), findsNothing,
        reason: 'der Replay hat eine zweite Zeile in das Tagebuch gespiegelt');
    expect(store.loggedMeals.length, 1);
    await _expectDayTotal(tester, '252');
  });
}
