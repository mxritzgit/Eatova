import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// B6-Verdrahtung: TrendService liest logged_meals DIREKT vom Server, also
// ueberlebt ein gecachtes 90-Tage-Fenster einen Schreibvorgang, den der Nutzer
// gerade gemacht hat — der Balken fuer heute bleibt zu kurz. Die TTL deckelt
// das auf zwei Minuten; diese Tests pinnen, dass jeder Mahlzeit-Schreibpfad im
// HomeStore den Cache SOFORT fallen laesst.
//
// Der Cache ist ein Prozess-Singleton, deshalb wird er pro Fall frisch
// befuellt. Wichtig ist NICHT, dass irgendein Test gruen ist, sondern dass
// jeder der fuenf Pfade einzeln greift: sie wurden einzeln vergessen, als die
// Liste zum ersten Mal aufgestellt wurde (Undo und updateLoggedMealResult
// fehlten beide).

/// Faengt die Undo-Aktion ab: _restoreLoggedMeal ist privat und nur ueber den
/// Snack erreichbar, den das Loeschen ausloest.
class _SnackCapture {
  SnackBarAction? letzteAktion;

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    if (action != null) letzteAktion = action;
  }
}

({HomeStore store, _SnackCapture snacks}) _store() {
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
  );
  addTearDown(store.dispose);
  return (store: store, snacks: snacks);
}

MealAnalysisResult _meal(String name, {int kcal = 300}) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 300,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

/// Fuellt den Singleton-Cache und behauptet, dass das auch geklappt hat —
/// sonst wuerde jeder Test unten trivial gruen, weil nie etwas drin war.
Future<void> _fillCache() async {
  TrendTotalsCache.instance.invalidate();
  await TrendTotalsCache.instance.read(
    userId: 'user-1',
    load: () async => const <TrendDayTotals>[],
  );
  expect(TrendTotalsCache.instance.debugHasEntry, isTrue,
      reason: 'Vorbedingung: der Cache muss vor dem Schreibvorgang gefuellt sein');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(TrendTotalsCache.instance.invalidate);

  test('eine geloggte Mahlzeit verwirft das gecachte Trendfenster', () async {
    final s = _store();
    final store = s.store;
    await _fillCache();

    store.addResultToDailyTotal(_meal('Bowl'));

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
  });

  test('eine skalierte Portion (updateLoggedMealResult) verwirft es auch',
      () async {
    final s = _store();
    final store = s.store;
    final id = store.addResultToDailyTotal(_meal('Bowl'));
    await _fillCache();

    store.updateLoggedMealResult(id, _meal('Bowl', kcal: 600));

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
  });

  test('das Bearbeiten der Details verwirft es', () async {
    final s = _store();
    final store = s.store;
    final id = store.addResultToDailyTotal(_meal('Bowl'));
    await _fillCache();

    store.updateLoggedMealDetails(id, slot: MealSlot.snack);

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
  });

  test('das Loeschen verwirft es', () async {
    final s = _store();
    final store = s.store;
    final id = store.addResultToDailyTotal(_meal('Bowl'));
    await _fillCache();

    store.removeLoggedMeal(id);

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
  });

  test('das RUECKGAENGIG eines Loeschens verwirft es ebenfalls', () async {
    // Der Pfad, der bei der ersten Aufstellung der Hooks vergessen wurde:
    // _restoreLoggedMeal legt die Zeile wieder an, also aendert es die
    // Serversicht genauso wie das Loeschen davor.
    final s = _store();
    final store = s.store;
    final id = store.addResultToDailyTotal(_meal('Bowl'));
    store.removeLoggedMeal(id);
    final undo = s.snacks.letzteAktion;
    expect(undo, isNotNull, reason: 'das Loeschen muss einen Undo-Snack werfen');
    await _fillCache();

    undo!.onPressed();

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
  });

  test('ein Lesevorgang allein laesst den Cache stehen', () async {
    // Gegenprobe: haette ich die Verwerfung an _mutate gehaengt, waere der
    // Cache staendig weg (sieben der ~40 Aufrufer sitzen im Sync-Pfad). Ein
    // reiner Lesezugriff darf ihn nicht anfassen.
    final s = _store();
    final store = s.store;
    store.addResultToDailyTotal(_meal('Bowl'));
    await _fillCache();

    store.consumedKcalForFoodDate(DateTime.now());
    store.macroProgressForFoodDate(DateTime.now());

    expect(TrendTotalsCache.instance.debugHasEntry, isTrue);
  });
}
