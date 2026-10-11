// Visual evidence for the feedback-state pass (2026-10-11): toasts with
// their tone glyph, the shared signal note, calm state, loading card and
// skeleton, and the screens that used to show bare text, default spinners
// or square bars — the workout history (empty, loading, error), the
// Training tab (loading, load error, in-progress notice) and the recipe
// history (loading, empty, error).
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/feedback-*.png (light: DESIGN_CAPTURE_BRIGHTNESS=light);
// without it the suite still checks that every state renders without an
// exception or overflow, at 390 px and at 320 px with 2x text.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/recipes/recipe_history_screen.dart';
import 'package:eatova/src/screens/training/training_history_screen.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/user_recipe_reads.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

/// The reference phone, optionally narrowed to [width].
void _viewport(WidgetTester tester, double width) {
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double textScale = 1,
  bool scaffold = true,
}) async {
  _viewport(tester, width);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        child,
        locale: const Locale('en'),
        textScale: textScale,
        scaffold: scaffold,
        safeArea: scaffold,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// The shared pieces on one page, as a reviewer's sheet.
class _Gallery extends StatelessWidget {
  const _Gallery();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ListView(
      key: const ValueKey('feedback-gallery'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        const SectionHeading(title: 'Signal notes'),
        const SizedBox(height: 12),
        SignalNote(
          'Could not save. Check the connection and try again.',
          tone: t.danger,
          icon: Icons.error_outline_rounded,
          boxed: true,
        ),
        const SizedBox(height: 10),
        SignalNote(
          'Some sets are missing values.',
          tone: t.warning,
          icon: Icons.warning_amber_rounded,
          boxed: true,
        ),
        const SizedBox(height: 10),
        SignalNote(
          'Your workout could not be saved on this device.',
          tone: t.danger,
          icon: Icons.error_outline_rounded,
          boxed: true,
          action: SoftPillButton(
            label: 'Retry',
            icon: Icons.refresh_rounded,
            onTap: () {},
          ),
        ),
        const SizedBox(height: 24),
        const SectionHeading(title: 'Calm state'),
        CalmState(
          icon: Icons.cloud_off_rounded,
          text: 'OpenFoodFacts is currently unreachable.',
          actions: [
            SoftPillButton(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              onTap: () {},
            ),
            SoftPillButton(
              label: 'Add manually',
              icon: Icons.edit_rounded,
              tone: SoftPillTone.neutral,
              onTap: () {},
            ),
          ],
        ),
        const SizedBox(height: 16),
        CalmState(
          card: true,
          icon: Icons.history_rounded,
          title: 'Nothing to restore yet',
          text:
              'When you change or delete one of your recipes, the earlier '
              'version shows up here.',
          actions: [
            SoftPillButton(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              onTap: () {},
            ),
          ],
        ),
        const SizedBox(height: 24),
        const SectionHeading(title: 'Loading'),
        const SizedBox(height: 12),
        const LoadingCard(label: 'Loading day…'),
        const SizedBox(height: 12),
        const SkeletonCard(rows: 2),
        const SizedBox(height: 12),
        const PrimaryActionButton(label: 'Saving…', busy: true),
      ],
    );
  }
}

RecipeHistoryPage _emptyPage() => const RecipeHistoryPage(
  versions: <RecipeVersion>[],
  currentRevision: null,
  currentDeleted: null,
  nextBefore: null,
);

void main() {
  setUpAll(loadDesignFonts);

  const sizes = <(String, double, double)>[('', 390, 1), ('-320-x2', 320, 2)];

  for (final (suffix, width, scale) in sizes) {
    testWidgets('gallery$suffix', (tester) async {
      await _pump(tester, const _Gallery(), width: width, textScale: scale);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-gallery$suffix');
      // The spinners never settle: jump and pump instead of settling.
      final position = tester
          .state<ScrollableState>(designMainScrollable())
          .position;
      position.jumpTo(position.maxScrollExtent);
      // The busy button's spinner is built by this jump and starts on the
      // next frame; then far enough into the spin that the arc reads as one.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-gallery-01$suffix');
    });

    testWidgets('workout history: empty$suffix', (tester) async {
      var logged = 0;
      await _pump(
        tester,
        TrainingHistoryScreen(
          entries: const [],
          onDelete: (_) async => SyncDelivery.delivered,
          onLogWorkout: () => logged++,
        ),
        width: width,
        textScale: scale,
        scaffold: false,
      );
      expect(
        find.byKey(const ValueKey('training-history-empty')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-training-history-empty$suffix');
      await tester.tap(
        find.byKey(const ValueKey('training-history-empty-log')),
      );
      expect(logged, 1);
    });

    testWidgets('workout history: loading and error$suffix', (tester) async {
      await _pump(
        tester,
        TrainingHistoryScreen(
          entries: const [],
          loading: true,
          onDelete: (_) async => SyncDelivery.delivered,
        ),
        width: width,
        textScale: scale,
        scaffold: false,
      );
      expect(
        find.byKey(const ValueKey('training-history-loading')),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await captureDesignShot(
        tester,
        'feedback-training-history-loading$suffix',
      );
      await _pump(
        tester,
        TrainingHistoryScreen(
          entries: const [],
          loadFailed: true,
          onRetry: () {},
          onDelete: (_) async => SyncDelivery.delivered,
        ),
        width: width,
        textScale: scale,
        scaffold: false,
      );
      expect(
        find.byKey(const ValueKey('training-history-error')),
        findsOneWidget,
      );
      // An error never doubles as "you have no workouts".
      expect(
        find.byKey(const ValueKey('training-history-empty')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-training-history-error$suffix');
    });

    TrainingScreen training({
      bool loading = false,
      bool loadFailed = false,
      bool active = false,
    }) => TrainingScreen(
      plans: const [],
      selectedPlanId: null,
      onSelectPlan: (_) {},
      onCreatePlan: (_) async => SyncDelivery.delivered,
      onUpdatePlan: (_, _) async => SyncDelivery.delivered,
      onDeletePlan: (_) async => SyncDelivery.delivered,
      onStartWorkout: (_, _) {},
      onOpenCoach: () {},
      loading: loading,
      loadFailed: loadFailed,
      onRetry: () {},
      hasActiveSession: active,
      onResumeWorkout: () {},
    );

    testWidgets('training tab: loading$suffix', (tester) async {
      await _pump(
        tester,
        training(loading: true),
        width: width,
        textScale: scale,
      );
      expect(find.byKey(const ValueKey('training-loading')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-training-loading$suffix');
    });

    testWidgets('training tab: load error and notice$suffix', (tester) async {
      await _pump(
        tester,
        training(loadFailed: true, active: true),
        width: width,
        textScale: scale,
      );
      expect(find.byKey(const ValueKey('training-load-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-training-error$suffix');
    });

    testWidgets('recipe history: loading, empty, error$suffix', (tester) async {
      final first = Completer<RecipeHistoryPage>();
      var calls = 0;
      await _pump(
        tester,
        RecipeHistoryScreen(
          loadHistory: ({slug, beforeRevision}) {
            calls++;
            return calls == 1
                ? first.future
                : Future<RecipeHistoryPage>.value(_emptyPage());
          },
          restoreVersion: (recipe, {required expectedRevision}) async =>
              SyncDelivery.delivered,
          isSessionCurrent: () => true,
        ),
        width: width,
        textScale: scale,
        scaffold: false,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await captureDesignShot(tester, 'feedback-recipe-history-loading$suffix');
      first.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-history-error')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-recipe-history-error$suffix');
      await tester.tap(find.byKey(const ValueKey('recipe-history-retry')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-history-empty')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-recipe-history-empty$suffix');
    });
  }

  for (final tone in SnackTone.values) {
    testWidgets('toast: ${tone.name}', (tester) async {
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showAppSnack(context, switch (tone) {
                SnackTone.positive => 'Workout saved.',
                SnackTone.neutral => 'Favorite removed.',
                SnackTone.warning =>
                  'Your plan changed. This workout '
                      'was not saved.',
                SnackTone.error => 'Something went wrong. Try again.',
              }, tone: tone),
              child: const Text('show'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Every toast carries its tone's glyph, also without a caller icon.
      expect(
        find.descendant(of: find.byType(SnackBar), matching: find.byType(Icon)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'feedback-toast-${tone.name}');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  }
}
