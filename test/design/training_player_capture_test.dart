// Visual evidence for the Training surfaces training_redesign does not reach
// (light mode pass, 2026-10-04), from the real home page with the design
// scenario (test/training/training_overview_fixture.dart):
//
//   training-plans-00   the plan library, the selected plan over the studio
//                       artwork
//   training-player-00  the list player before the first set
//   training-player-01  after the first set: the rest bar is running
//   training-player-02  the expanded rest view
//   training-player-exercise-menu / training-player-menu
//                       the exercise and header overflow menus (MenuRow)
//   training-player-discard-dialog
//                       the discard decision card behind the header menu
//   training-plan-menu / training-workout-menu
//                       the plan's tune menu and the workout chooser on the
//                       Training tab
//
// Shots are written only with DARK_REDESIGN_CAPTURE or
// DESIGN_CAPTURE_BRIGHTNESS; the normal pass checks that each surface shows.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/flow_test_helpers.dart' show settleFrames;
import '../support/design_capture.dart';
import '../training/training_overview_fixture.dart';

Finder _key(String id) => find.byKey(ValueKey(id));

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(_key(id));
  await settleFrames(tester, rounds: 4);
  await tester.tap(_key(id));
  await settleFrames(tester);
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('plan library with the studio artwork', (tester) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await pumpTrainingDesignHome(tester);
      await tester.tap(_key('nav-Training'));
      await settleFrames(tester);
      await _tap(tester, 'training-open-plans');
      expect(_key('training-plan-search'), findsOneWidget);
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'training-plans-00');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });

  testWidgets('list player, rest bar and rest view', (tester) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await pumpTrainingDesignHome(tester);
      await tester.tap(_key('nav-Training'));
      await settleFrames(tester);
      await _tap(tester, 'training-start');
      expect(_key('training-set-check-0-0'), findsOneWidget);
      await captureDesignShot(tester, 'training-player-00');

      await _tap(tester, 'training-set-check-0-0');
      expect(_key('training-rest-bar'), findsOneWidget);
      await captureDesignShot(tester, 'training-player-01');

      await _tap(tester, 'training-timer-rest-expand');
      expect(_key('training-rest-view'), findsOneWidget);
      await captureDesignShot(tester, 'training-player-02');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });

  testWidgets('player menus and the discard decision card', (tester) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await pumpTrainingDesignHome(tester);
      await tester.tap(_key('nav-Training'));
      await settleFrames(tester);
      await _tap(tester, 'training-start');

      await _tap(tester, 'training-exercise-menu-0');
      expect(_key('training-timer-skip-exercise'), findsOneWidget);
      await captureDesignShot(tester, 'training-player-exercise-menu');
      await tester.tapAt(const Offset(20, 400));
      await settleFrames(tester);

      await _tap(tester, 'training-timer-menu');
      expect(_key('training-timer-discard'), findsOneWidget);
      await captureDesignShot(tester, 'training-player-menu');

      await _tap(tester, 'training-timer-discard');
      expect(_key('training-timer-confirm-exit'), findsOneWidget);
      await captureDesignShot(tester, 'training-player-discard-dialog');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });

  testWidgets('plan menu and workout chooser on the Training tab', (
    tester,
  ) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await pumpTrainingDesignHome(tester);
      await tester.tap(_key('nav-Training'));
      await settleFrames(tester);
      // Mid-screen, so the menu shows where it opens: under its anchor.
      await scrollDesignTabBy(tester, 260);
      await tester.tap(_key('training-plan-menu'));
      await settleFrames(tester);
      expect(find.text('Edit'), findsOneWidget);
      await captureDesignShot(tester, 'training-plan-menu');
      await tester.tapAt(const Offset(20, 120));
      await settleFrames(tester);

      await _tap(tester, 'training-quick-workouts');
      expect(_key('training-workout-0'), findsOneWidget);
      await captureDesignShot(tester, 'training-workout-menu');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });
}
