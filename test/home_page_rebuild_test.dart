// G11 — jede Store-Benachrichtigung baute den ganzen Food-Tab neu (W3-01).
//
// Der oberste StoreSelector war sauber gefasst, darunter hing aber jeder Tab
// in einem blanken `ListenableBuilder(listenable: _store)`. Pro Notify liefen
// `isLoadingFoodDay`, `consumedKcalForFoodDate`, `macroProgressForFoodDate` und
// `mealsForFoodDate` unabhaengig — und meal_totals.dart filtert intern nochmal.
// Bei 210 Mahlzeiten sind das 630 Vergleiche und 3 Listen-Allokationen pro
// Rebuild, plus 400-500 Element-Rebuilds. Ausloeser laut Review: Boot-
// Hydration, Boot-Load, Outbox-Replay, Archivtag-Load (zwei Notifies),
// Health-Refresh (zwei bis drei pro App-Resume).
//
// Gemessen wird mit dem Zaehler `debugTabBuilds` aus eatova_home_page.dart: er
// zaehlt pro Tab-Index die tatsaechlichen Builder-Durchlaeufe (unter `assert`,
// im Release also weg).
//
// Design-Refactor 2026-08-09: Der neue Tab „Heute" sitzt auf Index 0, Food ist
// auf 1 gerueckt (Rezepte 2, Coach 3). Index 0 misst also nicht mehr den
// Food-Tab, sondern Heute. Dessen Selector-Slice
// (eatova_home_page.dart:553-564) traegt zusaetzlich `lifetimeStats` und
// `userName` — die Erwartungswerte sind deshalb NACHGEMESSEN und nicht aus der
// alten Food-Fassung uebernommen.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Health-Double, das bei jedem Refresh denselben Schrittstand liefert — genau
/// der Normalfall beim App-Resume: zwei bis drei Notifies, an denen sich fuer
/// den sichtbaren Tab NICHTS aendert.
class _StaticHealth implements HealthService {
  int snapshotCalls = 0;

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    snapshotCalls++;
    return HealthSnapshot(stepsToday: 7000, fetchedAt: DateTime(2026, 8, 8));
  }

  @override
  void reset() {}

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      const <WeightSample>[];

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;
}

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

MealAnalysisResult _meal(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 420,
      estimatedGrams: 300,
      kcalPer100G: 140,
      protein: '30 g',
      carbs: '40 g',
      fat: '12 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

Future<void> _pumpHome(WidgetTester tester, {HealthService? health}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  debugTabBuilds.clear();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      // _navItems() liest jetzt context.l10n (Spec §4) — ohne diese
      // Lokalisierung wirft AppLocalizations.of() beim Bau der Bottom-Nav.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: EatovaHomePage(healthService: health),
    ),
  );
  await tester.pump();
}

Future<void> _pumpFrames(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUp(debugTabBuilds.clear);

  testWidgets('ein Health-Refresh baut den Heute-Tab nicht mehr neu',
      (tester) async {
    final health = _StaticHealth();
    await _pumpHome(tester, health: health);
    await _pumpFrames(tester);

    // Kaltstart: zwei Heute-Builds — der initiale plus einer fuer den ersten
    // ECHTEN Schrittstand (0 -> 7000, steckt in der Slice). Genau so soll es
    // sein: die Fassung unterdrueckt keine relevante Aenderung.
    final nachBoot = debugTabBuilds[0]!;
    expect(nachBoot, 2);

    // Drei Resume-Refreshes = sechs Notifies, an denen sich fuer den Heute-Tab
    // nichts aendert (gleicher Schrittstand, gleiche Mahlzeiten, dieselbe
    // LifetimeStats-INSTANZ — die wird nur bei echten Ereignissen neu
    // zugewiesen, ein Health-Refresh fasst sie nicht an).
    final store = _storeOf(tester);
    for (var i = 0; i < 3; i++) {
      await store.refreshHealthSteps();
      await tester.pump();
    }

    expect(health.snapshotCalls, greaterThanOrEqualTo(3));
    expect(debugTabBuilds[0], nachBoot,
        reason: 'sechs irrelevante Notifies -> null zusaetzliche Rebuilds '
            '(gemessen vorher fuer Food: 2 -> 5)');
  });

  testWidgets('eine echte Aenderung baut den Heute-Tab genau einmal neu',
      (tester) async {
    await _pumpHome(tester);
    final vorher = debugTabBuilds[0]!;
    final store = _storeOf(tester);

    store.addResultToDailyTotal(_meal('Testmahlzeit'));
    await tester.pump();

    expect(debugTabBuilds[0], vorher + 1,
        reason: 'die Fassung darf nichts verschlucken, was der Tab anzeigt — '
            'und `loggedMeals` und `lifetimeStats` wechseln in EINEM Notify, '
            'ergeben also zusammen genau einen Rebuild');

    // Der Stats-Save laeuft 600 ms debounced — die Zeit auslaufen lassen,
    // sonst haengt sein Timer im Teardown als „Timer is still pending".
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('ein Tab-Wechsel baut die gemounteten Tabs nicht neu',
      (tester) async {
    await _pumpHome(tester);
    await _pumpFrames(tester);
    final store = _storeOf(tester);

    // Die drei anderen Tabs einmal besuchen (= mounten).
    for (final tab in const [1, 2, 3]) {
      store.setTab(tab);
      await _pumpFrames(tester);
    }

    final nachBesuch = Map<int, int>.from(debugTabBuilds);
    expect(nachBesuch[1], 1, reason: 'Food einmal gebaut');
    expect(nachBesuch[2], 1, reason: 'Rezepte einmal gebaut');
    expect(nachBesuch[3], 1, reason: 'Coach einmal gebaut');

    // Fuenf weitere Wechsel ueber alle Tabs.
    for (final tab in const [0, 1, 2, 3, 0]) {
      store.setTab(tab);
      await _pumpFrames(tester);
    }

    expect(debugTabBuilds, nachBesuch,
        reason: 'die gecachten Tab-Instanzen kommen identisch zurueck — '
            'Element.updateChild ueberspringt den Teilbaum '
            '(gemessen vorher: {0: 3, 1: 2, 2: 2} statt {0: 1, 1: 1, 2: 1})');
  });

  testWidgets('der Coach-Tab rebuildet nur bei Kontext-relevanten Aenderungen',
      (tester) async {
    await _pumpHome(tester);
    final store = _storeOf(tester);
    store.setTab(3);
    await _pumpFrames(tester);
    expect(debugTabBuilds[3], 1);

    // Reiner Datumswechsel im Food-Tab: geht den Coach-Kontext nichts an.
    store.setFoodDate(DateTime(2026, 8, 7));
    await _pumpFrames(tester);
    expect(debugTabBuilds[3], 1);

    // Eine geloggte Mahlzeit dagegen aendert coachContext -> Rebuild.
    store.addResultToDailyTotal(_meal('Testmahlzeit'));
    await _pumpFrames(tester);
    expect(debugTabBuilds[3], 2);
  });
}
