// The steps row of the Today tab's activity card (dark redesign).
//
// It shows the math behind the Activity stat: day total, progress towards the
// profile's step goal, the estimated kcal credit. Without a step source
// (`steps == null`) there is no row — "0 / 8.000" would be a claim about
// data that does not exist.
//
// Harness as in today_screen_test.dart: Eatova theme, phone viewport, shell
// padding.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/screens/today/today_sections.dart';
import 'package:eatova/src/services/day_math.dart';

import '../../support/harness.dart';
import '../../support/today_summary.dart';

const ValueKey<String> _zeile = ValueKey<String>('today-steps-card');
const ValueKey<String> _wert = ValueKey<String>('today-steps-value');
const ValueKey<String> _ziel = ValueKey<String>('today-steps-goal');
const ValueKey<String> _kcal = ValueKey<String>('today-steps-kcal');
const ValueKey<String> _balken = ValueKey<String>('today-steps-bar');

Future<void> _pump(
  WidgetTester tester, {
  int? steps,
  int burnedKcal = 0,
  int goal = 8000,
  bool dayLoading = false,
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  Locale locale = const Locale('de'),
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    TodayScreen(
      userName: 'Moritz',
      profile: const UserProfile().copyWith(dailyStepsGoal: goal),
      summary: todaySummary(
        profile: const UserProfile().copyWith(dailyStepsGoal: goal),
        consumedKcal: 0,
        burnedKcal: burnedKcal,
        macroProgress: MacroProgress.empty,
      ),
      meals: const <LoggedMeal>[],
      selectedDate: startOfDay(clock.now()),
      streak: 0,
      steps: steps,
      dayLoading: dayLoading,
    ),
    locale: locale,
    brightness: brightness,
    textScale: textScale,
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    // The bar is a TweenAnimationBuilder over motionDuration(320ms). Under the
    // harness default (reducedMotion: true) that collapses to zero and the
    // "after the animation settles" assertions would read the first frame.
    reducedMotion: false,
  );
  if (dayLoading) {
    // The loading card spins forever; pumpAndSettle would never settle.
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  } else {
    await tester.pumpAndSettle();
  }
}

String _text(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data!;

double _balkenWert(WidgetTester tester) =>
    tester.widget<LinearProgressIndicator>(find.byKey(_balken)).value!;

void main() {
  group('Schritte-Zeile', () {
    testWidgets('ohne Schrittquelle gibt es keine Zeile', (tester) async {
      await _pump(tester, steps: null, burnedKcal: 261);

      expect(find.byKey(_zeile), findsNothing);
      expect(find.byType(TodayStepsRow), findsNothing);
      // The rest of the day is unchanged.
      expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-macros-card')), findsOneWidget);
    });

    testWidgets('Stand, Ziel und kcal — mit Tausenderpunkt', (tester) async {
      await _pump(tester, steps: 7000, burnedKcal: 261);

      expect(find.byKey(_zeile), findsOneWidget);
      expect(_text(tester, _wert), '7.000');
      expect(_text(tester, _ziel), '/ 8.000 Schritte');
      expect(_text(tester, _kcal), '+261 kcal');
      // 7000 / 8000 after the animation settles.
      expect(_balkenWert(tester), closeTo(0.875, 0.001));
    });

    testWidgets('ohne Gutschrift steht nur das Ziel', (tester) async {
      await _pump(tester, steps: 7000, burnedKcal: 0);

      expect(find.byKey(_kcal), findsNothing);
      expect(_text(tester, _ziel), '/ 8.000 Schritte');
    });

    testWidgets('ohne Schrittziel steht nur die Einheit', (tester) async {
      await _pump(tester, steps: 7000, goal: 0);

      expect(_text(tester, _ziel), 'Schritte');
      expect(_balkenWert(tester), 0.0);
    });

    testWidgets('eine echte 0 (Quelle da, noch kein Schritt) bleibt sichtbar', (
      tester,
    ) async {
      await _pump(tester, steps: 0, burnedKcal: 0);

      expect(find.byKey(_zeile), findsOneWidget);
      expect(_text(tester, _wert), '0');
      expect(find.byKey(_kcal), findsNothing);
      expect(_text(tester, _ziel), '/ 8.000 Schritte');
      expect(_balkenWert(tester), 0.0);
    });

    testWidgets('waehrend der Tag laedt, fehlt auch die Schritte-Zeile', (
      tester,
    ) async {
      await _pump(tester, steps: 7000, burnedKcal: 261, dayLoading: true);

      expect(find.byKey(_zeile), findsNothing);
      expect(find.byKey(const ValueKey('today-day-loading')), findsOneWidget);
    });

    testWidgets('der Screenreader hoert Stand und Ziel, auch erreicht', (
      tester,
    ) async {
      // Disposed explicitly, not via addTearDown: the framework checks for
      // open handles BEFORE the teardowns run.
      final handle = tester.ensureSemantics();
      await _pump(tester, steps: 7000, burnedKcal: 261);

      final balken = find.bySemanticsLabel(RegExp('Schrittziel'));
      expect(balken, findsOneWidget);
      expect(
        tester.getSemantics(balken).value,
        contains('7.000 von 8.000 Schritten'),
      );

      // Goal reached: the bar is full and says so.
      await _pump(tester, steps: 9000, burnedKcal: 300);
      expect(_text(tester, _wert), '9.000');
      expect(_balkenWert(tester), 1.0);
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('Schrittziel'))).value,
        '9.000 von 8.000 Schritten, Ziel erreicht',
      );
      handle.dispose();
    });
  });
}
