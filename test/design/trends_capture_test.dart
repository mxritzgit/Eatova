// Visual evidence for the trends page (opened from the Food tab): 30 days of
// bars with the goal line and corridor, the metrics below, the empty state
// and the error state.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/trends-*.png (light: DESIGN_CAPTURE_BRIGHTNESS=light);
// without it the suite still checks that every state renders without an
// exception or overflow.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

final DateTime _now = DateTime(2026, 9, 28, 19);

/// 30 days around a 2,200 kcal goal: a realistic spread with a few misses
/// and two untracked days.
List<TrendDayTotals> _month() => <TrendDayTotals>[
  for (var d = 0; d < 30; d++)
    if (d != 9 && d != 17)
      TrendDayTotals(
        day: DateTime(_now.year, _now.month, _now.day - d),
        kcal: 1850 + (d * 137) % 700,
        proteinG: 105 + (d * 7) % 40,
        carbsG: 180 + (d * 11) % 70,
        fatG: 55 + (d * 5) % 25,
      ),
];

Future<void> _pump(WidgetTester tester, TrendTotalsLoader loader) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        TrendsScreen(kcalGoal: 2200, loadTotals: loader),
        locale: const Locale('en'),
        // TrendsScreen brings its own Scaffold and SafeArea.
        scaffold: false,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('trends: a month of data, top to bottom', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pump(tester, () async => _month());
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
      await captureDesignShot(tester, 'trends-00');
      await scrollDesignTabBy(tester, 600);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'trends-01');
    });
  });

  testWidgets('trends: empty', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pump(tester, () async => const <TrendDayTotals>[]);
      expect(find.byKey(const ValueKey('trends-empty')), findsOneWidget);
      await captureDesignShot(tester, 'trends-empty');
    });
  });

  testWidgets('trends: load error', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pump(tester, () async => throw StateError('offline'));
      expect(find.byKey(const ValueKey('trends-chart')), findsNothing);
      await captureDesignShot(tester, 'trends-error');
    });
  });
}
