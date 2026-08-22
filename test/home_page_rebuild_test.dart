// G11 — every store notification used to rebuild the whole tab (W3-01).
//
// Each tab hung in a bare `ListenableBuilder(listenable: _store)`, so every
// notify re-ran the day getters independently; at 210 meals that is hundreds
// of comparisons and element rebuilds per notify (boot hydration, outbox
// replay, archive-day load, health refresh).
//
// Measured with `debugTabBuilds` from eatova_home_page.dart, which counts real
// builder passes per tab index (under `assert`, gone in release).
//
// Index 0 is the "Heute" tab (food is 1, recipes 2, coach 3); its selector
// slice also carries `lifetimeStats` and `userName`, so the expectations below
// were re-measured for it.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Health double returning the same step count on every refresh — the normal
/// app-resume case: notifies that change NOTHING for the visible tab.
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
      // _navItems() reads context.l10n, so without localizations
      // AppLocalizations.of() throws while building the bottom nav.
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

    // Cold start: two builds — the initial one plus one for the first REAL
    // step count (0 -> 7000, part of the slice). The slice must not suppress a
    // relevant change.
    final nachBoot = debugTabBuilds[0]!;
    expect(nachBoot, 2);

    // Three resume refreshes = six notifies that change nothing for this tab
    // (same steps, same meals, same LifetimeStats instance).
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

    // The stats save is debounced by 600 ms; let it run out or its timer stays
    // pending at teardown.
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('ein Tab-Wechsel baut die gemounteten Tabs nicht neu',
      (tester) async {
    await _pumpHome(tester);
    await _pumpFrames(tester);
    final store = _storeOf(tester);

    // Visit the three other tabs once (= mount them).
    for (final tab in const [1, 2, 3]) {
      store.setTab(tab);
      await _pumpFrames(tester);
    }

    final nachBesuch = Map<int, int>.from(debugTabBuilds);
    expect(nachBesuch[1], 1, reason: 'Food einmal gebaut');
    expect(nachBesuch[2], 1, reason: 'Rezepte einmal gebaut');
    expect(nachBesuch[3], 1, reason: 'Coach einmal gebaut');

    // Five more switches across all tabs.
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

    // A plain date change in the food tab does not concern the coach context.
    store.setFoodDate(DateTime(2026, 8, 7));
    await _pumpFrames(tester);
    expect(debugTabBuilds[3], 1);

    // A logged meal does change coachContext -> rebuild.
    store.addResultToDailyTotal(_meal('Testmahlzeit'));
    await _pumpFrames(tester);
    expect(debugTabBuilds[3], 2);
  });
}
