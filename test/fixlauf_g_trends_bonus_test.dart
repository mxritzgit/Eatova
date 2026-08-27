import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/trend_service.dart';

import 'support/harness.dart';

// F7-05: Trends measured "goal hit" as ±10 % around the BASE goal while the
// Today tab steers by goal + step bonus (model B). Goal 2200 + 8000 steps
// (~230 kcal): Today said "20 over", Trends said "missed" (2450 > 2420). The
// hit rate, corridor and target line now use goal + burnedKcalFor(day).

DateTime _vorTagen(int n) => addDays(startOfDay(DateTime.now()), -n);

TrendDayTotals _tag(int vorTagen, int kcal) => TrendDayTotals(
      day: _vorTagen(vorTagen),
      kcal: kcal,
      proteinG: 0,
      carbsG: 0,
      fatG: 0,
    );

/// No `renderMatrix` here: this suite pins the step-bonus ARITHMETIC and its
/// footnote, which do not vary by brightness, locale or text scale.
Future<void> _pump(
  WidgetTester tester, {
  required List<TrendDayTotals> totals,
  int Function(DateTime day)? bonus,
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    bonus == null
        ? TrendsScreen(kcalGoal: 2200, loadTotals: () async => totals)
        : TrendsScreen(
            kcalGoal: 2200,
            loadTotals: () async => totals,
            burnedKcalFor: bonus,
          ),
    // TrendsScreen brings its own Scaffold and SafeArea.
    scaffold: false,
    safeArea: false,
    settle: true,
  );
}

void main() {
  group('goalHitsOf mit Schritt-Bonus', () {
    final tage = <TrendDayTotals?>[_tag(2, 2450), _tag(1, 2450)];

    test('ohne Bonus: 2450 > 2420 -> verfehlt (alter Stand)', () {
      final hits = goalHitsOf(tage, goalKcal: 2200);
      expect(hits, (hit: 0, tracked: 2));
    });

    test('mit 230 kcal Bonus: Ziel 2430, 2450 liegt im Korridor', () {
      final hits = goalHitsOf(tage, goalKcal: 2200, burnedKcalFor: (_) => 230);
      expect(hits, (hit: 2, tracked: 2));
    });

    test('Bonus ist tagesgenau: nur der Tag mit Schritten trifft', () {
      final gestern = _vorTagen(1);
      final hits = goalHitsOf(
        tage,
        goalKcal: 2200,
        burnedKcalFor: (day) => day == gestern ? 230 : 0,
      );
      expect(hits, (hit: 1, tracked: 2));
    });

    test('Luecken zaehlen weiter nicht, Ziel <= 0 hat keinen Korridor', () {
      final hits = goalHitsOf(
        <TrendDayTotals?>[null, _tag(1, 100)],
        goalKcal: 0,
        burnedKcalFor: (_) => 0,
      );
      expect(hits, (hit: 0, tracked: 1));
    });
  });

  group('TrendsScreen', () {
    testWidgets('Tag mit Bonus gilt als getroffen, Fussnote erklaert es',
        (tester) async {
      await _pump(
        tester,
        totals: [_tag(2, 2450), _tag(1, 2450), _tag(0, 500)],
        bonus: (_) => 230,
      );

      expect(find.text('2 von 2 Tagen (±10 %)'), findsOneWidget);
      expect(find.text('100 %'), findsOneWidget);
      expect(find.byKey(const ValueKey('trends-goal-bonus-note')),
          findsOneWidget);
    });

    testWidgets('ohne Bonus bleibt alles beim Basisziel, keine Fussnote',
        (tester) async {
      await _pump(tester, totals: [_tag(2, 2450), _tag(1, 2450), _tag(0, 500)]);

      expect(find.text('0 von 2 Tagen (±10 %)'), findsOneWidget);
      expect(find.byKey(const ValueKey('trends-goal-bonus-note')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Stufen-Ziellinie rendert ohne Fehler ueber 90 Tage',
        (tester) async {
      await _pump(
        tester,
        totals: [for (var i = 0; i < 40; i++) _tag(i, 2000 + i * 10)],
        bonus: (day) => day.day.isEven ? 300 : 0,
      );
      await tester.tap(find.byKey(const ValueKey('trends-range-90')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    });

    testWidgets('Semantik-Ansage nennt das Ziel des letzten Slots inklusive '
        'Bonus, nicht das Basisziel (G M-1)', (tester) async {
      await _pump(
        tester,
        totals: [_tag(2, 2450), _tag(1, 2450), _tag(0, 500)],
        bonus: (_) => 230,
      );

      Finder ansage(String ziel) => find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                (w.properties.value ?? '')
                    .contains('Tagesziel $ziel Kilokalorien'),
          );
      expect(ansage('2430'), findsOneWidget);
      expect(ansage('2200'), findsNothing);
    });
  });
}
