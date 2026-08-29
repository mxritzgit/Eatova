import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Audit 2026-08-14: `LocalCache.readOutbox` could not throw — `_readJson`
// swallowed every error and returned `null`. The boot hydration's read-error
// flag stayed false, `_repairOutboxHydration` was dead code, and a real read
// error caused exactly the data loss the guard was written against: the next
// enqueue overwrote up to [kOutboxMaxOps] undelivered writes with a fresh
// single-element queue. The deltas slot had the same flaw, and logout hangs
// off it (`preserveOutbox`).
//
// These tests drive the real HomeStore against a KeyValueStore whose reads
// fail on demand: a transient read error costs no ops, a structurally broken
// slot is a read error rather than "empty", the deltas slot survives logout, a
// recovered TODAY meal also counts in the day total and macro rings, and the
// healthy slot pays no extra reads.

const String _uid = 'user-lesefehler';
const String _outboxSlot = 'eatova.v1.outbox.$_uid';
const String _deltaSlot = 'eatova.v1.pending_stats.$_uid';

/// [KeyValueStore] whose reads fail per slot on demand, counting reads.
///
/// Models the real case: a platform/channel error hits ONE read while the blob
/// is intact. The write paths stay real — only they can lose the blob.
class _ProbenStore implements KeyValueStore {
  _ProbenStore([Map<String, String>? initial]) : blobs = {...?initial};

  final Map<String, String> blobs;

  /// Slot -> how many of the NEXT reads should throw.
  final Map<String, int> fehlschlaege = <String, int>{};

  /// Slot -> number of reads, failed ones included.
  final Map<String, int> lesezugriffe = <String, int>{};

  @override
  Future<String?> getString(String key) async {
    lesezugriffe[key] = (lesezugriffe[key] ?? 0) + 1;
    final offen = fehlschlaege[key] ?? 0;
    if (offen > 0) {
      fehlschlaege[key] = offen - 1;
      throw StateError('Slot nicht lesbar');
    }
    return blobs[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    blobs[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    blobs.remove(key);
  }
}

MealAnalysisResult _result(String name, {int kcal = 300}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 350,
      kcalPer100G: kcal * 100 / 350,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

/// An undelivered meal from a previous session, as it sits in the persisted
/// outbox.
LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: _result('Alt-Bowl'),
      loggedAt: DateTime(2026, 8, 13, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-13',
    );

/// The same undelivered meal dated TODAY — only then does it touch the day
/// totals the repair path must bring in line.
LoggedMeal _heutigeMeal(String id) {
  final jetzt = DateTime.now();
  return LoggedMeal(
    id: id,
    result: _result('Alt-Bowl'),
    loggedAt: DateTime(jetzt.year, jetzt.month, jetzt.day, 12, 30),
    forcedSlot: MealSlot.lunch,
    localDay: localDayKey(jetzt),
  );
}

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Fully offline server: every request fails with 503, so the live write
/// reliably lands in the outbox — the state where the blob has something to
/// lose.
http.Client _offlineClient() => MockClient((req) async => http.Response(
      jsonEncode({'message': 'offline'}),
      503,
      headers: const {'Content-Type': 'application/json'},
      request: req,
    ));

HomeStore _store(LocalCache cache) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: _offlineClient(),
    // No GoTrue auto-refresh ticker in tests (see clobber_guard_test).
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final store = HomeStore(
    sync: EatovaSync.forUser(client, _uid),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return store;
}

Future<void> _settle() => pumpEventQueue(times: 60);

Future<void> _boot(HomeStore store) async {
  store.start();
  await store.profileReady;
  await _settle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'ein voruebergehender Lesefehler des Outbox-Slots ueberschreibt den Blob '
      'nicht mehr — der Reparaturpfad holt die Ops nach', () async {
    final probe = _ProbenStore();
    await LocalCache(probe, _uid)
        .writeOutbox([SyncOp.mealInsert(_meal('m-alt'), trackDay: false)]);
    // Exactly the first read fails: the blob is intact, only the hydration's
    // access misses it.
    probe.fehlschlaege[_outboxSlot] = 1;

    final store = _store(LocalCache(probe, _uid));
    await _boot(store);
    expect(store.pendingOutbox, isEmpty,
        reason: 'Vorbedingung: die Hydration hat den Blob nicht gesehen');

    final neu = store.addResultToDailyTotal(_result('Neu-Bowl'));
    await _settle();

    final blob = await LocalCache(probe, _uid).readOutbox();
    expect(blob!.map((o) => o.entityId), containsAll(<String>['m-alt', neu]),
        reason: 'ein verschluckter Lesefehler machte den naechsten Enqueue zum '
            'Ueberschreiber — die nie zugestellte Mahlzeit war danach weg, '
            'ohne dass irgendwer davon erfuhr');
    expect(store.pendingOutbox.map((o) => o.entityId), contains('m-alt'));
    expect(store.loggedMeals.map((m) => m.id), contains('m-alt'),
        reason: 'die nachgeholte Op darf nicht unsichtbar in der Queue liegen '
            '— sie gehoert wieder ins Tagebuch');
  });

  test(
      'ein strukturell kaputter Outbox-Slot ist ein Lesefehler, keine leere '
      'Queue — der Reparaturpfad laeuft', () async {
    final probe = _ProbenStore(<String, String>{
      _outboxSlot: '{"items": [ kein json',
    });

    final store = _store(LocalCache(probe, _uid));
    await _boot(store);
    final nachBoot = probe.lesezugriffe[_outboxSlot]!;

    store.addResultToDailyTotal(_result('Neu-Bowl'));
    await _settle();

    expect(probe.lesezugriffe[_outboxSlot], greaterThan(nachBoot),
        reason: 'der Enqueue muss ueber _repairOutboxHydration laufen: ohne '
            'erkannten Lesefehler schriebe er ungeprueft ueber den Slot, und '
            'genau diese Methode waere toter Code');
    expect(probe.blobs[_outboxSlot], '{"items": [ kein json',
        reason: 'P3-02b: der Slot ist noch BELEGT. Auf dieser Ebene ist '
            '„Inhalt kaputt" nicht von „gerade nicht lesbar" zu '
            'unterscheiden, also gilt erst einmal der teurere Fall und der '
            'Blob bleibt stehen');

    // Then the slot heals: after the bounded number of attempts the broken
    // blob is treated as permanently undeliverable and the normal write path
    // resumes — a slot that never opens must not cost the session its
    // durability.
    for (var i = 0; i < kOutboxRepairMaxAttempts; i++) {
      store.addResultToDailyTotal(_result('Bowl-$i'));
      await _settle();
    }
    expect((await LocalCache(probe, _uid).readOutbox())!, isNotEmpty,
        reason: 'ein dauerhaft kaputter Slot darf die Sitzung nicht dauerhaft '
            'am Persistieren hindern');
  });

  test(
      'Lesefehler im Deltas-Slot: der Logout raeumt den ungelesenen '
      'Sync-Zustand NICHT weg', () async {
    final probe = _ProbenStore();
    await LocalCache(probe, _uid)
        .writePendingStatsDeltas(meals: 3, weightLogs: 0);
    // Both reads fail (hydration + counter-check): the slot is permanently
    // unreadable but its content is intact.
    probe.fehlschlaege[_deltaSlot] = 2;

    final store = _store(LocalCache(probe, _uid));
    await _boot(store);

    await store.signOutCleanup();

    expect(probe.blobs.containsKey(_deltaSlot), isTrue,
        reason: 'ohne erkannten Lesefehler gilt der leere In-Memory-Stand als '
            'Wahrheit — und der Logout loescht drei nie verbuchte Mahlzeiten '
            'aus den Lebenszeit-Zaehlern');
  });

  test(
      'die nachgeholte HEUTIGE Mahlzeit steht nicht nur im Tagebuch, sie '
      'zaehlt auch in Tagesbilanz und Makros', () async {
    final probe = _ProbenStore();
    await LocalCache(probe, _uid).writeOutbox(
        [SyncOp.mealInsert(_heutigeMeal('m-heute'), trackDay: false)]);
    probe.fehlschlaege[_outboxSlot] = 1;

    final store = _store(LocalCache(probe, _uid));
    await _boot(store);
    expect(store.dailyConsumedKcal, 0,
        reason: 'Vorbedingung: die Hydration hat den Blob nicht gesehen');

    store.addResultToDailyTotal(_result('Neu-Bowl'));
    await _settle();

    expect(store.loggedMeals.map((m) => m.id), contains('m-heute'));
    expect(store.dailyConsumedKcal, 600,
        reason: 'der Reparaturpfad ist der einzige Aufrufer von '
            '_applyPendingOpsToState, der die Tageswerte nicht selbst neu '
            'rechnet — die zurueckgeholte Mahlzeit stand sonst im Tagebuch, '
            'fehlte aber in der Tagesbilanz');
    expect(store.macroProgress.proteinG, 60,
        reason: 'dieselbe Luecke trifft die Makro-Ringe');
  });

  test(
      'Gegenprobe: ein gesunder Slot verhaelt sich unveraendert — Hydration '
      'wie bisher, kein Reparaturpfad, kein zweiter Lesevorgang', () async {
    final probe = _ProbenStore();
    await LocalCache(probe, _uid)
        .writeOutbox([SyncOp.mealInsert(_meal('m-alt'), trackDay: false)]);

    final store = _store(LocalCache(probe, _uid));
    await _boot(store);

    expect(store.pendingOutbox.map((o) => o.entityId), contains('m-alt'));
    expect(probe.lesezugriffe[_outboxSlot], 1,
        reason: 'der gesunde Pfad darf weder die Gegenprobe noch einen '
            'Reparatur-Nachlesevorgang bezahlen — beim verschluesselten Store '
            'waere jeder davon ein zweites Entschluesseln des ganzen Blobs');

    final neu = store.addResultToDailyTotal(_result('Neu-Bowl'));
    await _settle();

    expect(probe.lesezugriffe[_outboxSlot], 1);
    final blob = await LocalCache(probe, _uid).readOutbox();
    expect(blob!.map((o) => o.entityId), containsAll(<String>['m-alt', neu]));
  });
}
