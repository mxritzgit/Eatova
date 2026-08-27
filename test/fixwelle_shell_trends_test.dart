// Fix wave 2026-08-27 (F7-05, Review I-4): the step bonus reaches Trends only
// because the SHELL wires `trendBurnedKcalFor: _store.burnedKcalForFoodDate`
// into MealAnalysisScreen. fixwelle_trends_wiring_test.dart proves the screen
// forwards the prop; this guard proves the shell passes it — dropping the line
// in eatova_home_page.dart goes red here, not in a screen-level test.
//
// Boots the real EatovaHomePage without sync (preview path, as in
// home_page_tabs_test.dart) with a health double that reports steps.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Health double with a fixed step count, so the store KNOWS activity today.
class _StepsHealth implements HealthService {
  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async =>
      HealthSnapshot(stepsToday: 7000, fetchedAt: clock.now());

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

/// Frames without `pumpAndSettle`: the shell carries endless animations.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _pumpHomeOnFoodTab(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Headless font metrics produce overflows that never happen on a device
  // (same reasoning as test/flows/flow_test_helpers.dart).
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: EatovaHomePage(healthService: _StepsHealth()),
    ),
  );
  await _pumpFrames(tester);
  // Food is tab 1 and unbuilt at cold start; switch via the store (the
  // bottom nav's coach orb never settles).
  _storeOf(tester).setTab(1);
  await _pumpFrames(tester);
  expect(find.byType(MealAnalysisScreen), findsOneWidget);
}

void main() {
  testWidgets('die Schale reicht die Bonus-Quelle des Stores an den Food-Tab '
      'durch, sodass Trends mit Schritt-Bonus rechnen', (tester) async {
    await _pumpHomeOnFoodTab(tester);

    final screen = tester.widget<MealAnalysisScreen>(
      find.byType(MealAnalysisScreen),
    );
    final bonus = screen.trendBurnedKcalFor;
    expect(bonus, isNotNull,
        reason: 'ohne trendBurnedKcalFor bleiben Trends beim Basisziel, '
            'obwohl der Heute-Tab den Bonus zeigt (F7-05)');

    // Not just any function: the store's per-day value, and a real one.
    final store = _storeOf(tester);
    final heute = clock.now();
    expect(store.dailySteps, 7000,
        reason: 'der Boot-Refresh muss die Schritte geliefert haben');
    final erwartet = store.burnedKcalForFoodDate(heute);
    expect(erwartet, greaterThan(0));
    expect(bonus!(heute), erwartet);
    expect(tester.takeException(), isNull);
  });
}
