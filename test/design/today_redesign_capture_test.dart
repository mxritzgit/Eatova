// Visual evidence for the Today tab of the dark redesign (Task 2).
//
// Mounts the real home page at the design's reference geometry with the
// design's scenario (test/support/today_design_fixture.dart) and shoots
// `today-00` (top) and `today-01` (scrolled to the reference's 631 px), plus
// the design's `day=Empty` variant as `today-empty-00`.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/. Without it the suite still pins that the scenario's
// store values reach the screen and that the page scrolls under the glass.

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/design/design.dart';

import '../support/design_capture.dart';
import '../support/today_design_fixture.dart';

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('today-00 / today-01: the design scenario from the store', (
    tester,
  ) async {
    await withClock(Clock.fixed(designNow), () async {
      await pumpDesignToday(tester);

      // The scenario's numbers, read back from the rendered screen.
      expect(_text(tester, 'today-date-selected-label'), 'Monday, Sep 28');
      expect(_text(tester, 'today-streak-count'), '1');
      expect(_text(tester, 'today-kcal-remaining'), '902');
      expect(_text(tester, 'today-kcal-budget'), 'kcal of 2,123');
      expect(_text(tester, 'today-kcal-percent'), '58% eaten');
      expect(_text(tester, 'today-stat-eaten'), '1,221');
      expect(_text(tester, 'today-kcal-goal'), '2,050');
      expect(_text(tester, 'today-stat-burned'), '+73');
      expect(find.text('51 g left'), findsOneWidget);
      expect(find.text('78 g left'), findsOneWidget);
      expect(find.text('37 g left'), findsOneWidget);
      expect(
        _text(tester, 'today-pick-title'),
        'Turkey Steak with Quinoa & Roasted Vegetables',
      );
      expect(_text(tester, 'today-pick-leaves'), 'Leaves 292 kcal for today');
      expect(
        _text(tester, 'today-meal-sub-breakfast'),
        'Skyr, Oats, Blueberries',
      );
      expect(_text(tester, 'today-meal-sub-dinner'), 'Suggested 550–700 kcal');
      expect(_text(tester, 'today-meal-kcal-lunch'), '597 kcal');
      expect(_text(tester, 'today-steps-value'), '1,392');
      expect(_text(tester, 'today-steps-goal'), '/ 8,000 steps');
      expect(_text(tester, 'today-steps-kcal'), '+73 kcal');
      expect(_text(tester, 'today-workout-title'), 'Upper Body Push');
      expect(_text(tester, 'today-workout-sub'), 'Next workout · ≈ 50 min');

      // The pill shares the "Calories" line, right-aligned in the card.
      final pill = tester.getRect(
        find.byKey(const ValueKey('today-kcal-percent')),
      );
      final title = tester.getRect(find.text('Calories'));
      final card = tester.getRect(
        find.byKey(const ValueKey('today-kcal-hero')),
      );
      expect(pill.top, lessThan(title.bottom));
      expect(pill.right, closeTo(card.right - 18 - 10, 1));
      expect(pill.width, lessThan(card.width / 2));

      // Header, strip and the complete calorie card stand above the glass.
      final glass = tester.getRect(find.byKey(const ValueKey('nav-glass')));
      expect(
        tester.getRect(find.byKey(const ValueKey('today-kcal-hero'))).bottom,
        lessThan(glass.top),
      );

      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'today-00');

      final offset = await scrollDesignTabBy(tester, 631);
      expect(offset, 631, reason: 'design shot today-01 sits at 631');
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'today-01');

      // Mid-page, content runs under the glass bar ...
      await scrollDesignTabBy(tester, -331);
      final page = find.byKey(const ValueKey('screen-today'));
      final underGlass = tester
          .renderObjectList<RenderBox>(
            find.descendant(of: page, matching: find.byType(RichText)),
          )
          .where(
            (box) =>
                (box.localToGlobal(Offset.zero) & box.size).overlaps(glass),
          );
      expect(underGlass, isNotEmpty, reason: 'text scrolls under the glass');
      // ... and at the end the last card clears the bar's band.
      await scrollDesignTabBy(tester, 10000);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('today-activity-card')))
            .bottom,
        lessThanOrEqualTo(
          kDesignViewport.height -
              AppNavBar.reservedHeightFor(kDesignSafeArea.bottom),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('today-empty-00: the design\'s empty day', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      await pumpDesignToday(tester, emptyDay: true);

      expect(_text(tester, 'today-kcal-remaining'), '2,123');
      expect(_text(tester, 'today-kcal-percent'), '0% eaten');
      expect(_text(tester, 'today-stat-eaten'), '0');
      expect(
        _text(tester, 'today-meal-sub-breakfast'),
        'Suggested 400–550 kcal',
      );
      expect(_text(tester, 'today-meal-sub-lunch'), 'Suggested 550–700 kcal');
      expect(_text(tester, 'today-meal-sub-snack'), 'Suggested 150–300 kcal');
      expect(find.byKey(const ValueKey('today-meal-kcal-lunch')), findsNothing);

      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'today-empty-00');
      expect(tester.takeException(), isNull);
    });
  });
}
