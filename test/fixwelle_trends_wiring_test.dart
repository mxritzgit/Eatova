// Fix wave 2026-08-27 (F7-05, Review G I-2): the step bonus reaches Trends
// over the REAL call path — MealAnalysisScreen.trendBurnedKcalFor (what the
// shell wires to HomeStore.burnedKcalForFoodDate) -> _openTrends ->
// TrendsScreen(burnedKcalFor:). Without the prop Trends stay on the base goal.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

DateTime _vorTagen(int n) => addDays(startOfDay(DateTime.now()), -n);

TrendDayTotals _tag(int vorTagen, int kcal) => TrendDayTotals(
      day: _vorTagen(vorTagen),
      kcal: kcal,
      proteinG: 0,
      carbsG: 0,
      fatG: 0,
    );

/// Goal 2200, two completed days at 2450: without bonus both miss the ±10 %
/// corridor (2420), with 230 kcal bonus (goal 2430) both hit.
final List<TrendDayTotals> _totals = [_tag(2, 2450), _tag(1, 2450), _tag(0, 500)];

Future<void> _pumpAndOpenTrends(
  WidgetTester tester, {
  int Function(DateTime day)? bonus,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

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
      home: Scaffold(
        body: MealAnalysisScreen(
          dailyConsumedKcal: 0,
          profile: const UserProfile(dailyKcalGoal: 2200),
          trendTotalsLoader: () async => _totals,
          trendBurnedKcalFor: bonus,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('topbar-trends')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
}

void main() {
  testWidgets('Bonus-Quelle am Screen: Tag mit Schritt-Bonus gilt in Trends '
      'als getroffen, Fussnote erscheint', (tester) async {
    await _pumpAndOpenTrends(tester, bonus: (_) => 230);

    expect(find.text('2 von 2 Tagen (±10 %)'), findsOneWidget);
    expect(find.byKey(const ValueKey('trends-goal-bonus-note')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ohne Bonus-Quelle bleibt Trends beim Basisziel (wie vorher)',
      (tester) async {
    await _pumpAndOpenTrends(tester);

    expect(find.text('0 von 2 Tagen (±10 %)'), findsOneWidget);
    expect(find.byKey(const ValueKey('trends-goal-bonus-note')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
