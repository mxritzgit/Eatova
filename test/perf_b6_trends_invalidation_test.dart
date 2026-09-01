import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
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
//
// Gehaertet 2026-09-01 (Mutationslauf T4): drei dieser Pfade schreiben neben
// dem Cache auch die SICHTBAREN Tageswerte fort, und genau das war nirgends
// zugesichert. In `removeLoggedMeal`, `_restoreLoggedMeal` und
// `updateLoggedMealResult` liessen sich `dailyConsumedKcal` und
// `macroProgress` ersatzlos streichen, ohne dass ein einziger Fall der Suite
// rot wurde — die Kachel haette die geloeschte Mahlzeit weitergezaehlt. Die
// Faelle pruefen die Zahl deshalb jetzt mit; der Doppeltipp auf denselben
// Undo-Snack steht daneben, weil der Idempotenz-Schutz in `_restoreLoggedMeal`
// dieselbe Luecke hatte.

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

  test(
      'eine skalierte Portion (updateLoggedMealResult) verwirft es auch und '
      'zieht die Tagessumme nach', () async {
    final s = _store();
    final store = s.store;
    final id = store.addResultToDailyTotal(_meal('Bowl'));
    expect(store.dailyConsumedKcal, 300);
    await _fillCache();

    store.updateLoggedMealResult(id, _meal('Bowl', kcal: 600));

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
    expect(store.dailyConsumedKcal, 600,
        reason: 'die Kachel zeigt sonst die alte Portion weiter, obwohl die '
            'Zeile im Tagebuch schon die neue traegt');
    expect(store.macroProgress.kcal, 600);
  });

  test('das Bearbeiten der Details verwirft es', () async {
    final s = _store();
    final store = s.store;
    final id = store.addResultToDailyTotal(_meal('Bowl'));
    await _fillCache();

    store.updateLoggedMealDetails(id, slot: MealSlot.snack);

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
  });

  test('das Loeschen verwirft es und nimmt die Kalorien vom Tag', () async {
    final s = _store();
    final store = s.store;
    final id = store.addResultToDailyTotal(_meal('Bowl'));
    expect(store.dailyConsumedKcal, 300);
    await _fillCache();

    store.removeLoggedMeal(id);

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
    expect(store.dailyConsumedKcal, 0,
        reason: 'eine geloeschte Mahlzeit darf in der Tagessumme nicht '
            'stehenbleiben');
    expect(store.macroProgress, MacroProgress.empty);
  });

  test(
      'das RUECKGAENGIG eines Loeschens verwirft es ebenfalls und gibt die '
      'Kalorien zurueck — auch beim Doppeltipp nur einmal', () async {
    // Der Pfad, der bei der ersten Aufstellung der Hooks vergessen wurde:
    // _restoreLoggedMeal legt die Zeile wieder an, also aendert es die
    // Serversicht genauso wie das Loeschen davor.
    final s = _store();
    final store = s.store;
    final id = store.addResultToDailyTotal(_meal('Bowl'));
    store.removeLoggedMeal(id);
    final undo = s.snacks.letzteAktion;
    expect(undo, isNotNull, reason: 'das Loeschen muss einen Undo-Snack werfen');
    expect(store.dailyConsumedKcal, 0);
    await _fillCache();

    undo!.onPressed();

    expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
    expect(store.dailyConsumedKcal, 300,
        reason: 'die wiederhergestellte Mahlzeit zaehlt wieder — sonst fehlt '
            'sie in der Tagessumme, obwohl sie im Tagebuch steht');
    expect(store.macroProgress.proteinG, 30);

    // Zweiter Tipp auf denselben Snack: der Idempotenz-Schutz in
    // _restoreLoggedMeal muss halten, sonst steht die Mahlzeit doppelt im
    // Tagebuch und der Tag zaehlt 600 kcal.
    undo.onPressed();

    expect(store.loggedMeals.where((m) => m.id == id), hasLength(1));
    expect(store.dailyConsumedKcal, 300);
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
