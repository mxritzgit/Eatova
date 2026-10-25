// Visual evidence for the call sites of group 2 (polish 2026-10-25): food,
// meal, training and today adopting the depth-and-light buttons.
//
// Every scene renders the real widgets in German at the design's 390 px
// reference and is written as `<scene>-dark` / `<scene>-light`:
//   g2-training-card      the workout card: lit Start (TrainingStartButton
//                         on PrimaryActionButton), "Als erledigt eintragen"
//   g2-training-recent    quick start with "Dem Coach erzählen" and the
//                         Recent heading's "Alle" link
//   g2-training-empty     no plan: lit Coach, the neutral "Plan erstellen"
//                         capsule as tall, two text links
//   g2-player-timer       the player's header Finish pill and the forest
//                         timer card's "Früher fertig" link
//   g2-player-unstored    "Ohne Speichern verlassen?": lit Finish, soft
//                         danger leave, the quiet stay
//   g2-add-item           the meal's add-item form card with its quiet
//                         cancel
//   g2-suggestion-add     an open food suggestion with the round lit "+"
//   g2-legacy-notice      Today's legacy notice with the terms link
//
//   flutter test test/design/g2_capture_test.dart \
//     --dart-define=DARK_REDESIGN_CAPTURE=true          (build/dark-redesign)
//   flutter test test/design/g2_capture_test.dart \
//     --dart-define=DESIGN_CAPTURE_BRIGHTNESS=light     (build/light-redesign)
//
// Without a define the suite still pins that every scene opens without an
// exception.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_insights.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/today/today_legacy_notice.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/screen_awake.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';
import '../training/training_overview_fixture.dart';
import '../training/training_timer_fixtures.dart';

String get _mode =>
    designCaptureBrightness == Brightness.light ? 'light' : 'dark';

Future<void> _shoot(WidgetTester tester, String scene) =>
    captureDesignShot(tester, '$scene-$_mode');

Finder _key(String value) => find.byKey(ValueKey(value));

/// The [EatovaDialogAction] around [inner] (its button key or label).
EatovaDialogAction _action(WidgetTester tester, Finder inner) =>
    tester.widget<EatovaDialogAction>(
      find.ancestor(of: inner, matching: find.byType(EatovaDialogAction)),
    );

/// Mounts [child] on the reference phone; returns a context below the
/// navigator.
Future<BuildContext> _mount(
  WidgetTester tester,
  Widget child, {
  bool settle = true,
}) async {
  pinDesignViewport(tester);
  late BuildContext context;
  await tester.pumpWidget(
    designCaptureBoundary(localizedApp(child, onContext: (c) => context = c)),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return context;
}

/// Scrolls [target] to [alignment] of the viewport (0 top, 1 bottom).
Future<void> _reveal(
  WidgetTester tester,
  Finder target, {
  double alignment = 0.5,
}) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: alignment);
  await tester.pumpAndSettle();
}

TrainingScreen _training({
  required List<TrainingPlan> plans,
  TrainingNextWorkout? next,
  List<TrainingHistoryEntry> history = const [],
}) => TrainingScreen(
  plans: plans,
  onCreatePlan: (_) async => SyncDelivery.delivered,
  onUpdatePlan: (_, _) async => SyncDelivery.delivered,
  onSelectPlan: (_) {},
  onDeletePlan: (_) async => SyncDelivery.delivered,
  onStartWorkout: (_, _) {},
  onOpenCoach: () {},
  onOpenHistory: () {},
  hasActiveSession: false,
  nextWorkout: next,
  history: history,
  recentWorkouts: recentTrainingWorkouts(history),
  onLogWorkout: () {},
  onLogPlannedWorkout: (_, _) {},
  onOpenCoachLog: () {},
);

Widget _trainingWithPlan() {
  final plan = trainingDesignPlan();
  final history = trainingDesignHistory(plan);
  return _training(
    plans: [plan],
    next: nextTrainingWorkout(
      plan: plan,
      history: history,
      now: kTrainingDesignNow,
    ),
    history: history,
  );
}

/// Pushes the list player for [plan]; [persist] answers every checkpoint.
Future<void> _openPlayer(
  WidgetTester tester,
  TrainingPlan plan, {
  required TimerTestClock clock,
  bool persist = true,
}) async {
  final context = await _mount(tester, const SizedBox.shrink());
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrainingPlayerScreen(
          plan: plan,
          monotonicNow: clock.now,
          screenAwake: const NoopScreenAwake(),
          onPersist: (_) async => persist,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const MealAnalysisResult _bowl = MealAnalysisResult(
  mealName: 'Linsen-Bowl',
  caloriesKcal: 540,
  estimatedGrams: 380,
  kcalPer100G: 142,
  protein: '24 g',
  carbs: '68 g',
  fat: '16 g',
  confidence: 'Mittel',
  portionNotes: 'KI-Schätzung aus dem Foto.',
  sourceLabel: 'Foto-KI',
  items: [
    MealComponent(name: 'Linsen', grams: 180, caloriesKcal: 210),
    MealComponent(name: 'Reis', grams: 150, caloriesKcal: 195),
    MealComponent(name: 'Joghurt-Dip', grams: 50, caloriesKcal: 135),
  ],
);

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('g2-training-card and g2-training-recent', (tester) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await _mount(tester, _trainingWithPlan());
      await _reveal(tester, _key('training-log-done'), alignment: 0.85);
      expect(_key('training-start').hitTestable(), findsOneWidget);
      await _shoot(tester, 'g2-training-card');
      await _reveal(tester, _key('training-recent-all'), alignment: 0.35);
      expect(_key('training-log-coach').hitTestable(), findsOneWidget);
      await _shoot(tester, 'g2-training-recent');
    });
  });

  testWidgets('g2-training-empty', (tester) async {
    await withClock(Clock.fixed(kTrainingDesignNow), () async {
      await _mount(tester, _training(plans: const []));
      await _reveal(tester, _key('training-empty-log-coach'), alignment: 0.7);
      expect(
        tester.getSize(_key('training-empty-create')).height,
        tester.getSize(_key('training-empty-coach')).height,
      );
      await _shoot(tester, 'g2-training-empty');
    });
  });

  testWidgets('g2-player-timer', (tester) async {
    final clock = TimerTestClock();
    await _openPlayer(tester, timerPlan(), clock: clock);
    await tester.tap(_key('training-set-check-0-0'));
    await tester.pump();
    // Past the get-ready lead: the countdown runs with "Done early".
    clock.elapse(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(_key('training-timer-done-early'), findsOneWidget);
    await _shoot(tester, 'g2-player-timer');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('g2-player-unstored', (tester) async {
    final clock = TimerTestClock();
    final plan = TrainingPlan(
      id: 'g2_strength',
      proposal: CoachTrainingProposal(
        title: 'Kraft',
        workouts: [
          TrainingWorkout(
            title: 'Tag A',
            exercises: [
              for (final name in ['Kniebeuge', 'Bankdrücken', 'Rudern'])
                TrainingExercise(name: name, sets: 3, reps: 8, restSeconds: 60),
            ],
          ),
        ],
      ),
    );
    await _openPlayer(tester, plan, clock: clock, persist: false);
    await tester.tap(_key('training-set-check-0-0'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // The safe way out is the quiet one, not a second filled pill.
    expect(_action(tester, _key('training-timer-unstored-stay')).quiet, isTrue);
    await _shoot(tester, 'g2-player-unstored');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('g2-add-item', (tester) async {
    final context = await _mount(tester, const SizedBox.shrink());
    unawaited(showWeightAdjustmentSheet(context, _bowl));
    await tester.pumpAndSettle();
    await tester.tap(_key('analyse-item-add-button'));
    await tester.pumpAndSettle();
    expect(_key('analyse-add-item-save'), findsOneWidget);
    expect(_action(tester, find.text('Abbrechen')).quiet, isTrue);
    await _shoot(tester, 'g2-add-item');
  });

  testWidgets('g2-suggestion-add', (tester) async {
    await _mount(
      tester,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
        child: Column(
          children: [
            MealSuggestionItem(
              result: _bowl,
              expanded: true,
              onTap: () {},
              onAdd: (_) {},
              addButtonKey: const ValueKey('g2-suggestion-add'),
            ),
          ],
        ),
      ),
    );
    expect(_key('g2-suggestion-add'), findsOneWidget);
    await _shoot(tester, 'g2-suggestion-add');
  });

  testWidgets('g2-legacy-notice', (tester) async {
    await withClock(Clock.fixed(DateTime.utc(2026, 10, 25, 9)), () async {
      await _mount(
        tester,
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
          child: TodayLegacyNoticeCard(
            until: DateTime.utc(2026, 12, 1, 12),
            free: kAssumedFreeLimits,
            onDismiss: () async {},
            onUpgrade: () {},
            onOpenTerms: () {},
          ),
        ),
      );
      expect(_key('today-legacy-notice-terms'), findsOneWidget);
      await _shoot(tester, 'g2-legacy-notice');
    });
  });
}
