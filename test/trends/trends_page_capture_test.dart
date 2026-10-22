// Visual evidence for the trends page with every section (2026-10-18):
// calories, macros, steps, weight and training over 30 days and six months,
// the first-load skeleton, the empty and the error state, plus Today's
// trends card. With --dart-define=DARK_REDESIGN_CAPTURE=true the
// PNGs land in build/dark-redesign/trends-full-*.png (light:
// DESIGN_CAPTURE_BRIGHTNESS=light); without it the suite still checks that
// every state renders without an exception or overflow, at 320 px with 2x
// text too.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/today/today_trends.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/trend_service.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';
import '../support/text_layout.dart';

final DateTime _now = DateTime(2026, 10, 18, 19);

DateTime _day(int back) => DateTime(_now.year, _now.month, _now.day - back);

/// Six months around a 2,200 kcal goal with a few gaps.
List<TrendDayTotals> _halfYear() => <TrendDayTotals>[
  for (var d = 0; d < 182; d++)
    if (d % 11 != 4)
      TrendDayTotals(
        day: _day(d),
        kcal: 1850 + (d * 137) % 700,
        proteinG: 105 + (d * 7) % 40,
        carbsG: 180 + (d * 11) % 70,
        fatG: 55 + (d * 5) % 25,
      ),
];

TrendLocalData _local() => TrendLocalData(
  stepsByDay: <String, int>{
    for (var d = 1; d < 182; d++)
      if (d % 9 != 2) localDayKey(_day(d)): 5200 + (d * 977) % 7400,
  },
  stepsToday: 6400,
  hasStepSource: true,
  weighIns: <WeightLogEntry>[
    for (var d = 180; d >= 0; d -= 3)
      WeightLogEntry(
        timestamp: _day(d).add(const Duration(hours: 7)),
        weightKg: 78.4 - (180 - d) * 0.022 + (d % 7) * 0.08,
      ),
  ],
  workoutsFinishedAt: <DateTime>[
    for (var d = 1; d < 182; d++)
      if (d % 7 == 1 || d % 7 == 3 || d % 7 == 5)
        _day(d).add(const Duration(hours: 18)),
  ],
  proteinGoalG: 130,
  stepsGoal: 8000,
);

Future<void> _pumpPage(WidgetTester tester, {Size? size, double? scale}) async {
  pinDesignViewport(tester);
  if (size != null) tester.view.physicalSize = size * kDesignPixelRatio;
  final page = TrendsScreen(
    kcalGoal: 2200,
    loadTotals: () async => _halfYear(),
    local: TrendLocalSource(changes: ChangeNotifier(), read: _local),
  );
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        page,
        locale: const Locale('de'),
        scaffold: false,
        safeArea: false,
        textScale: scale ?? 1,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// The page over [loader] alone, without the store's sections.
Future<void> _pumpServerOnly(
  WidgetTester tester,
  TrendTotalsLoader loader,
) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        // A fresh state per pump: the loader runs in initState only.
        TrendsScreen(key: UniqueKey(), kcalGoal: 2200, loadTotals: loader),
        locale: const Locale('en'),
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

  testWidgets('trends: 30 days with every section, top to bottom', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpPage(tester);
      expect(find.byKey(const ValueKey('trends-steps-chart')), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await captureDesignShot(tester, 'trends-full-30-0$i');
        await scrollDesignTabBy(tester, 560);
        expect(tester.takeException(), isNull);
      }
    });
  });

  testWidgets('trends: six months in weekly bars', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('trends-range-182')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trends-weekly-note')), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await captureDesignShot(tester, 'trends-full-182-0$i');
        await scrollDesignTabBy(tester, 560);
        expect(tester.takeException(), isNull);
      }
    });
  });

  testWidgets('trends: 320 px and 2x text keep every section whole', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpPage(
        tester,
        size: Size(320, kDesignViewport.height),
        scale: 2,
      );
      final page = find.byKey(const ValueKey('screen-trends'));
      for (var i = 0; i < 8; i++) {
        expectAllWholeWords(tester, page);
        await captureDesignShot(tester, 'trends-full-320-x2-0$i');
        await scrollDesignTabBy(tester, 500);
        expect(tester.takeException(), isNull);
      }
    });
  });

  testWidgets('today: the trends card', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      pinDesignViewport(tester);
      await tester.pumpWidget(
        designCaptureBoundary(
          localizedApp(
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  TodayTrendsCard(
                    preview: (
                      avgKcal: 2104,
                      avgProteinG: 118,
                      proteinAtLeast: false,
                      avgSteps: 8432,
                    ),
                    onOpen: () {},
                  ),
                  const SizedBox(height: 16),
                  TodayTrendsCard(
                    preview: (
                      avgKcal: null,
                      avgProteinG: null,
                      proteinAtLeast: false,
                      avgSteps: null,
                    ),
                    onOpen: () {},
                  ),
                ],
              ),
            ),
            locale: const Locale('de'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'trends-full-today-card');
    });
  });

  testWidgets('trends: first load, empty and error states', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final pending = Completer<List<TrendDayTotals>>();
      await _pumpServerOnly(tester, () => pending.future);
      expect(find.byKey(const ValueKey('trends-loading')), findsOneWidget);
      await captureDesignShot(tester, 'trends-loading');
      pending.complete(const <TrendDayTotals>[]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trends-empty')), findsOneWidget);
      await captureDesignShot(tester, 'trends-empty');

      await _pumpServerOnly(tester, () async => throw StateError('offline'));
      expect(find.byKey(const ValueKey('trends-error')), findsOneWidget);
      await captureDesignShot(tester, 'trends-error');
    });
  });
}
