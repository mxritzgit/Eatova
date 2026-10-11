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
//   training-player-01 / -02 with -de, -320-x2, -de-320-x2
//                       the rest bar and rest view in German (the long
//                       "Pause überspringen") and on a 320 px phone at 2x
//   training-player-01-paused
//                       a paused rest: Resume joins the controls
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

/// The list player alone. With [refuse] the store refuses every checkpoint
/// (the source plan changed), so leaving after a set asks on the unstored
/// card.
Future<void> _pumpPlayer(
  WidgetTester tester, {
  double width = 390,
  double textScale = 1,
  Locale locale = const Locale('en'),
  bool refuse = false,
}) async {
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        TrainingPlayerScreen(
          plan: trainingDesignPlan(),
          onPersist: (_) async => !refuse,
          onComplete: (_) async {},
          screenAwake: const _NoAwake(),
          monotonicNow: () => Duration.zero,
        ),
        locale: locale,
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
        await _pumpPlayer(
          tester,
          width: width,
          textScale: scale,
          refuse: true,
        );
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

  for (final (suffix, width, scale, locale) in const [
    ('-de', 390.0, 1.0, Locale('de')),
    ('-320-x2', 320.0, 2.0, Locale('en')),
    ('-de-320-x2', 320.0, 2.0, Locale('de')),
  ]) {
    testWidgets('rest bar and rest view$suffix', (tester) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        await _pumpPlayer(
          tester,
          width: width,
          textScale: scale,
          locale: locale,
        );
        await _tap(tester, 'training-set-check-0-0');
        expect(_key('training-rest-bar'), findsOneWidget);
        // At 2x text the bar scrolls: its controls sit at its end.
        await tester.ensureVisible(_key('training-timer-skip-rest'));
        await settleFrames(tester, rounds: 4);
        const controls = [
          'training-timer-rest-minus',
          'training-timer-rest-plus',
          'training-timer-skip-rest',
        ];
        for (final id in controls) {
          final rect = tester.getRect(_key(id));
          expect(rect.left, greaterThanOrEqualTo(0), reason: id);
          expect(rect.right, lessThanOrEqualTo(width), reason: id);
          expect(rect.height, greaterThanOrEqualTo(48), reason: id);
        }
        if (scale == 1) {
          // One row of one height, and every label on one line: the
          // 15 px "Pause überspringen" wrapped inside its pill.
          expect({
            for (final id in controls) tester.getRect(_key(id)).top,
          }, hasLength(1));
          expect({
            for (final id in controls) tester.getSize(_key(id)).height,
          }, {48.0});
          for (final id in controls) {
            final label = find.descendant(
              of: _key(id),
              matching: find.byType(Text),
            );
            expect(
              tester.getSize(label).height,
              lessThan(30),
              reason: '$id: one line',
            );
          }
        }
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'training-player-01$suffix');

        await _tap(tester, 'training-timer-rest-expand');
        expect(_key('training-rest-view'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'training-player-02$suffix');
        await tester.pumpWidget(const SizedBox.shrink());
        await settleFrames(tester);
      });
    });
  }

  testWidgets('paused rest: Resume joins the controls', (tester) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await _pumpPlayer(tester);
      await _tap(tester, 'training-set-check-0-0');
      await _tap(tester, 'training-timer-menu');
      await _tap(tester, 'training-timer-pause');
      expect(_key('training-timer-rest-resume'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'training-player-01-paused');
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });
}
