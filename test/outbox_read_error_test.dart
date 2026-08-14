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

// Audit 2026-08-14: `LocalCache.readOutbox` KONNTE gar nicht werfen — `_readJson`
// faengt jeden Fehler selbst ab und liefert `null`. Damit blieb der Merker
// `outboxLesefehler` der Boot-Hydration immer false, `_repairOutboxHydration`
// war toter Code, und ein echter Lesefehler des Slots endete in genau dem
// Datenverlust, gegen den der Schutz geschrieben wurde: der naechste Enqueue
// schrieb eine frische Ein-Element-Queue ueber bis zu [kOutboxMaxOps] nie
// zugestellte Writes. Der Deltas-Slot hatte denselben Mangel — dort haengt der
// Logout dran (`preserveOutbox`).
//
// Diese Tests treiben den echten HomeStore gegen einen KeyValueStore, dessen
// Lesezugriffe gezielt scheitern, und sichern:
//   1. Ein VORUEBERGEHENDER Lesefehler des Outbox-Slots kostet keine Ops mehr —
//      der Reparaturpfad holt den Blob nach, statt ihn zu ueberschreiben.
//   2. Ein strukturell kaputter Slot ist ebenfalls ein Lesefehler und kein
//      „ist halt leer" — der Reparaturpfad laeuft, danach heilt der Slot.
//   3. Derselbe Mangel im Deltas-Slot haette den Logout den ungelesenen
//      Sync-Zustand raeumen lassen.
//   4. Eine ueber den Reparaturpfad zurueckgeholte HEUTIGE Mahlzeit zaehlt
//      auch in Tagesbilanz und Makro-Ringen, nicht nur im Tagebuch.
//   5. Der gesunde Slot verhaelt sich unveraendert und zahlt nichts drauf.

const String _uid = 'user-lesefehler';
const String _outboxSlot = 'eatova.v1.outbox.$_uid';
const String _deltaSlot = 'eatova.v1.pending_stats.$_uid';

/// [KeyValueStore], dessen Lesezugriffe pro Slot gezielt scheitern — und der
/// mitzaehlt, wie oft ein Slot gelesen wurde.
///
/// Modelliert den realen Fall, gegen den der Schutz gebaut ist: ein Plattform-/
/// Kanal-Fehler trifft EINEN Lesevorgang, der Blob liegt unversehrt da. Die
/// Schreibpfade bleiben die echten — nur sie koennen den Blob verlieren.
class _ProbenStore implements KeyValueStore {
  _ProbenStore([Map<String, String>? initial]) : blobs = {...?initial};

  final Map<String, String> blobs;

  /// Slot -> wie viele der NAECHSTEN Lesezugriffe werfen sollen.
  final Map<String, int> fehlschlaege = <String, int>{};

  /// Slot -> Anzahl Lesezugriffe, gescheiterte eingeschlossen.
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

/// Eine nie zugestellte Mahlzeit der Vorsession, wie sie in der persistierten
/// Outbox liegt.
LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: _result('Alt-Bowl'),
      loggedAt: DateTime(2026, 8, 13, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-13',
    );

/// Dieselbe nie zugestellte Mahlzeit, aber auf HEUTE datiert — nur dann
/// beschreibt sie die Tageswerte, die der Reparaturpfad nachziehen muss.
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

/// Voll-offline-Server: jede Anfrage scheitert mit 503. Der Live-Write landet
/// damit zuverlaessig in der Outbox — genau der Zustand, in dem der Blob etwas
/// zu verlieren hat.
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
    // Kein GoTrue-Auto-Refresh-Ticker im Test (siehe clobber_guard_test).
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
    // GENAU der erste Lesezugriff scheitert: der Blob ist unversehrt, nur der
    // Zugriff der Hydration geht daneben.
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

    // Danach heilt der Slot: der zweite Leseversuch findet denselben kaputten
    // Blob vor, er gilt damit als endgueltig unzustellbar, und der normale
    // Schreibpfad uebernimmt wieder.
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
    // Beide Lesezugriffe scheitern (Hydration + Gegenprobe): der Slot ist
    // dauerhaft nicht lesbar, sein Inhalt aber unversehrt.
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
