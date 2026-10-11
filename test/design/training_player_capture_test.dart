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
//   training-player-menu-tooltip
//                       the long-press label of the header menu (tooltip
//                       theme)
//   training-plan-menu / training-workout-menu
//                       the plan's tune menu and the workout chooser on the
//                       Training tab
//   training-player-unstored-dialog (-320-x2)
//                       leaving when the store refused the place: Finish,
//                       the soft-danger "Leave without saving" and Stay
//
// Shots are written only with DARK_REDESIGN_CAPTURE or
// DESIGN_CAPTURE_BRIGHTNESS; the normal pass checks that each surface shows.

import 'package:clock/clock.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/screen_awake.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/flow_test_helpers.dart' show settleFrames;
import '../support/design_capture.dart';
import '../support/harness.dart';
import '../training/training_overview_fixture.dart';

Finder _key(String id) => find.byKey(ValueKey(id));

final class _NoAwake implements ScreenAwake {
  const _NoAwake();

  @override
  Future<void> setKeepAwake(bool on, {String owner = 'default'}) async {}
}

/// The list player alone, with a store that refuses every checkpoint (the
/// source plan changed), so leaving after a set asks on the unstored card.
Future<void> _pumpRefusingPlayer(
  WidgetTester tester, {
  double width = 390,
  double textScale = 1,
}) async {
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        TrainingPlayerScreen(
          plan: trainingDesignPlan(),
          onPersist: (_) async => false,
          onComplete: (_) async {},
          screenAwake: const _NoAwake(),
          monotonicNow: () => Duration.zero,
        ),
        locale: const Locale('en'),
        textScale: textScale,
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await settleFrames(tester);
}

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

      // Long-press shows the trigger's label in the tooltip theme.
      await tester.longPress(_key('training-timer-menu'));
      await settleFrames(tester, rounds: 20);
      expect(find.text('Workout options'), findsOneWidget);
      await captureDesignShot(tester, 'training-player-menu-tooltip');
      await tester.pump(const Duration(seconds: 3));
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

  for (final (suffix, width, scale) in const [
    ('', 390.0, 1.0),
    ('-320-x2', 320.0, 2.0),
  ]) {
    testWidgets('unstored leave: Finish, soft-danger leave and Stay$suffix', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        await _pumpRefusingPlayer(tester, width: width, textScale: scale);
        await _tap(tester, 'training-set-check-0-0');
        await _tap(tester, 'training-timer-back');
        // A done set can still be finished: all three actions show.
        for (final id in [
          'training-timer-unstored-finish',
          'training-timer-unstored-leave',
          'training-timer-unstored-stay',
        ]) {
          expect(_key(id), findsOneWidget, reason: id);
        }
        expect(tester.takeException(), isNull);
        await captureDesignShot(
          tester,
          'training-player-unstored-dialog$suffix',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await settleFrames(tester);
      });
    });
  }
}
