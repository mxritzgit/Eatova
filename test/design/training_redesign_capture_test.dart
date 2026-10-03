// Visual evidence for the redesigned Training tab (dark redesign 2026-09-28).
//
// Mounts the real home page, signed in against the fake backend with the
// design scenario (test/training/training_overview_fixture.dart), at the
// design's reference geometry and clock (Mon 2026-09-28 19:00), and shoots
// the tab at the design's scroll positions: training-00 (top), training-01
// (700) and training-02 (the end: 858 in the design, 734 here without the
// omitted kcal card and muscle chips).
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/ for comparison with design/shots/training-new-*.png.
// Without it the suite still checks that the store's real values reach the
// screen and that the end of the page clears the floating bar.

import 'package:clock/clock.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/flow_test_helpers.dart' show settleFrames;
import '../support/design_capture.dart';
import '../training/training_overview_fixture.dart';

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('training-00…02: the design scenario from the store', (
    tester,
  ) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await pumpTrainingDesignHome(tester);
      await tester.tap(find.byKey(const ValueKey('nav-Training')));
      await settleFrames(tester);

      // training-00: header, week, next workout.
      expect(find.text('Strength plan'), findsOneWidget);
      expect(find.text('NEXT WORKOUT'), findsOneWidget);
      expect(find.text('Upper Body Push'), findsWidgets);
      expect(find.text('Last time 75 kg × 8'), findsOneWidget);
      expect(find.text('≈ 50 min'), findsOneWidget);
      expect(
        find.text('+ Cable fly, Lateral raise, Triceps pushdown'),
        findsOneWidget,
      );
      final summary = tester.widget<Text>(
        find.byKey(const ValueKey('training-week-summary')),
      );
      expect(summary.textSpan!.toPlainText(), '0 of 3 done · Sep 28 – Oct 4');
      await captureDesignShot(tester, 'training-00');

      // training-01: quick start, weekly volume, top of Recent. The card
      // opens on the running week (nothing lifted yet); the design shows
      // last week, which is one tap on its bar.
      expect(await scrollDesignTabBy(tester, 700), 700);
      expect(find.text('tonnes this week'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('training-volume-week-4')));
      await settleFrames(tester);
      expect(find.text('tonnes last week'), findsOneWidget);
      expect(find.text('8.6'), findsWidgets);
      expect(find.text('↑ 9% vs. the week before'), findsOneWidget);
      await captureDesignShot(tester, 'training-01');

      // training-02: the end of the page, Recent with the PR badge.
      await scrollDesignTabBy(tester, 158);
      expect(find.text('Lower Body'), findsOneWidget);
      expect(find.text('2 PRs'), findsOneWidget);
      expect(find.text('Fri, Sep 25 · 52 min'), findsOneWidget);
      await captureDesignShot(tester, 'training-02');

      // The glass bar never hides the end: the last row clears the band.
      final position = tester
          .state<ScrollableState>(designMainScrollable())
          .position;
      position.jumpTo(position.maxScrollExtent);
      await settleFrames(tester);
      final lastRow = tester.getRect(find.text('Mon, Sep 21 · 49 min'));
      expect(
        lastRow.bottom,
        lessThan(
          kDesignViewport.height -
              AppNavBar.reservedHeightFor(kDesignSafeArea.bottom),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });

  testWidgets('training-empty-00: no plan, no history (not in the design)', (
    tester,
  ) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await pumpTrainingDesignHome(tester, plans: const [], history: const []);
      await tester.tap(find.byKey(const ValueKey('nav-Training')));
      await settleFrames(tester);
      expect(find.byKey(const ValueKey('training-empty')), findsOneWidget);
      await captureDesignShot(tester, 'training-empty-00');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });
}
