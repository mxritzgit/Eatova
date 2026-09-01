import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/trend_service.dart';

import 'outbox/outbox_test_helpers.dart';

// M1 (Review 2026-09-01) — die Trend-Verwerfung muss am SERVER-Schreibvorgang
// haengen, nicht nur am lokalen Store.
//
// TrendService liest logged_meals direkt vom Server. Die optimistische
// Verwerfung in HomeStore feuert, BEVOR der Schreibvorgang rausgeht — wer in
// genau dem Fenster den Trends-Tab oeffnet, holt sich den Stand VOR dem
// Schreibvorgang und pinnt ihn fuer die volle TTL. Vor diesem PR gab es keinen
// Cache, der Tab war also immer frisch; die Optimierung haette ihn hier
// schlechter gemacht.
//
// Zwei Loecher, beide hier gepinnt:
//  (a) LIVE: nach der Zustellung wird ein ZWEITES Mal verworfen.
//  (b) REPLAY: ein Outbox-Lauf, der Tage spaeter landet, hatte gar keinen
//      Haken — offline geloggt, Trends geoeffnet, wieder online: die Kurve
//      blieb falsch.
//
// Beide Tests fuellen den Cache erst NACH der lokalen Mutation. Damit kann die
// optimistische Verwerfung sie nicht gruen machen: gruen wird nur, wer wirklich
// am Server-Schreibvorgang haengt.

MealAnalysisResult _meal(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 400,
      estimatedGrams: 300,
      kcalPer100G: 133,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

Future<void> _fuelleCache() async {
  TrendTotalsCache.instance.invalidate();
  await TrendTotalsCache.instance.read(
    userId: 'user-outbox',
    load: () async => const <TrendDayTotals>[],
  );
  expect(TrendTotalsCache.instance.debugHasEntry, isTrue,
      reason: 'Vorbedingung: ohne gefuellten Cache ist der Test wertlos');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(TrendTotalsCache.instance.invalidate);

  test('LIVE: die Zustellung an den Server verwirft das Trendfenster', () async {
    final s = setupOhneCache();
    await bootUntilIdle(s.store);

    s.store.addResultToDailyTotal(_meal('Bowl'));
    // ERST JETZT fuellen: die optimistische Verwerfung ist damit schon
    // vorbei, und nur der Haken an der Zustellung kann noch greifen.
    await _fuelleCache();
    await settle();

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse,
        reason: 'nach der Zustellung muss das Fenster erneut fallen');
  });

  test('REPLAY: ein spaet gelandeter Outbox-Lauf verwirft es ebenfalls', () async {
    final s = setupOhneCache();
    // Offline geloggt: der Schreibvorgang scheitert und die Op bleibt liegen.
    s.server.offline = true;
    await bootUntilIdle(s.store);
    s.store.addResultToDailyTotal(_meal('Bowl'));
    await settle();
    expect(s.store.pendingOutbox, isNotEmpty,
        reason: 'Vorbedingung: die Op muss wirklich in der Outbox liegen');

    // Der Nutzer oeffnet Trends, waehrend die Op noch haengt — der Cache haelt
    // jetzt einen Serverstand OHNE diese Mahlzeit.
    await _fuelleCache();

    // Wieder online: der Replay stellt zu.
    s.server.offline = false;
    s.store.flushPendingWrites();
    await settle();

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse,
        reason: 'der Replay schreibt die Zeile, also muss das Fenster fallen');
  });
}
