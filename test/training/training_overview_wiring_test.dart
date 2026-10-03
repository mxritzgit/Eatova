// Wiring of the redesigned Training tab (dark redesign 2026-09-28): every
// control does what its label promises, and every number follows the store.
//
// Group "shell" mounts the real home page against the fake backend with the
// design scenario (training_overview_fixture.dart) and taps through to the
// real routes, sheets and tabs. Group "screen" drives TrainingScreen alone
// where only the callback's arguments matter.

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_insights.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/training/training_history_screen.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/screens/training/training_plan_picker.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/flow_test_helpers.dart' show settleFrames;
import '../support/harness.dart';
import 'training_overview_fixture.dart';

const _push = [75.0, 45.0, 26.0, 10.0, 6.0, 15.0];

Future<void> _openTraining(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('nav-Training')));
  await settleFrames(tester);
}

/// Scrolls [key] into view and taps it (bounded frames, no pumpAndSettle:
/// the signed-in shell never settles).
Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await settleFrames(tester);
  await tester.tap(target);
  await settleFrames(tester);
}

/// The plan-name field of the open plan editor.
String _editorTitle(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('training-editor-title')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

String _weekSummary(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('training-week-summary')))
    .textSpan!
    .toPlainText();

/// A finished Upper Body Push today (Mon 2026-09-28), through the store.
Future<TrainingHistoryEntry> _finishPushToday(
  WidgetTester tester,
  HomeStore store,
) async {
  final entry = trainingDesignEntry(
    store.trainingPlans.single,
    0,
    finishedAt: DateTime(2026, 9, 28, 18),
    minutes: 50,
    topKg: _push,
    backOff: 0.8,
  );
  final before = store.trainingHistory.length;
  await store.completeTrainingSession(
    entry,
    generation: store.trainingSessionGeneration,
  );
  await pumpRealUntil(
    tester,
    () => store.trainingHistory.length == before + 1,
    'the finished workout reaches the history',
  );
  return entry;
}

Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await settleFrames(tester);
}

TrainingScreen _screen({
  required List<TrainingPlan> plans,
  TrainingNextWorkout? next,
  List<TrainingHistoryEntry> history = const [],
  void Function(TrainingPlan, int)? start,
  VoidCallback? resume,
  bool active = false,
  Future<SyncDelivery> Function(String)? delete,
  VoidCallback? coach,
  VoidCallback? logWorkout,
  void Function(TrainingPlan, int)? logPlanned,
  VoidCallback? coachLog,
  bool historyLoadFailed = false,
  VoidCallback? retryHistory,
  List<TrainingWorkoutSummary> recent = const [],
}) => TrainingScreen(
  plans: plans,
  onCreatePlan: (_) async => SyncDelivery.delivered,
  onUpdatePlan: (_, _) async => SyncDelivery.delivered,
  onSelectPlan: (_) {},
  onDeletePlan: delete ?? (_) async => SyncDelivery.delivered,
  onStartWorkout: start ?? (_, _) {},
  onOpenCoach: coach ?? () {},
  onOpenHistory: () {},
  hasActiveSession: active,
  onResumeWorkout: resume,
  nextWorkout: next,
  history: history,
  recentWorkouts: recent,
  onLogWorkout: logWorkout,
  onLogPlannedWorkout: logPlanned,
  onOpenCoachLog: coachLog,
  historyLoadFailed: historyLoadFailed,
  onRetryHistory: retryHistory,
);

/// A free log of [plan]'s first Pull exercise name, with no duration.
TrainingHistoryEntry _pulldownLog({required DateTime performedOn}) =>
    buildLoggedWorkout(
      historyId: '00000000-0000-4000-8000-0000000f0001',
      draft: LoggedWorkoutDraft(
        title: 'Back day',
        performedOn: performedOn,
        exercises: const [
          LoggedExercise(
            name: 'lat  Pulldown',
            timed: false,
            sets: [LoggedSet(reps: 10, weightKg: 55)],
          ),
        ],
      ),
      now: kTrainingDesignNow,
      fallbackTitle: 'Workout',
    );

Future<void> _pumpScreen(WidgetTester tester, TrainingScreen screen) =>
    pumpLocalized(
      tester,
      screen,
      locale: const Locale('en'),
      surfaceSize: const Size(390, 844),
      settle: true,
    );

Future<void> _tapScreen(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  group('shell', () {
    testWidgets('header: history opens the history, + opens a new plan draft', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
          tester,
        );
        await _openTraining(tester);
        final semantics = tester.ensureSemantics();
        expect(
          find.bySemanticsLabel('Workout history'),
          findsOneWidget,
          reason: 'the round history button is labelled',
        );
        expect(find.bySemanticsLabel('New plan'), findsWidgets);
        semantics.dispose();

        await _tap(tester, 'training-open-history');
        expect(find.byType(TrainingHistoryScreen), findsOneWidget);
        expect(
          tester
              .widget<TrainingHistoryScreen>(find.byType(TrainingHistoryScreen))
              .entries,
          hasLength(15),
        );
        await _tap(tester, 'training-history-back');

        await _tap(tester, 'training-create');
        expect(
          find.byKey(const ValueKey('training-editor-title')),
          findsOneWidget,
        );
        expect(_editorTitle(tester), isEmpty, reason: 'a new, empty plan');
        expect(store.trainingPlans, hasLength(1), reason: 'nothing written');
        await _leave(tester);
      });
    });

    testWidgets('Start opens the player on the rotation\'s next workout', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
          tester,
        );
        await _openTraining(tester);
        final next = store.nextTrainingWorkoutForToday()!;
        expect(next.workoutIndex, 0, reason: 'Lower Body was last: Push');
        expect(find.text('NEXT WORKOUT'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('training-card-title')))
              .data,
          next.title,
        );

        await _tap(tester, 'training-start');
        final player = tester.widget<TrainingPlayerScreen>(
          find.byType(TrainingPlayerScreen),
        );
        expect(player.plan?.id, kTrainingDesignPlanId);
        expect(player.workoutIndex, next.workoutIndex);
        await _leave(tester);
      });
    });

    testWidgets('a finished workout updates week, card, volume and Recent', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
          tester,
        );
        await _openTraining(tester);
        expect(_weekSummary(tester), '0 of 3 done · Sep 28 – Oct 4');
        expect(
          find.byKey(const ValueKey('training-week-done-1')),
          findsNothing,
        );
        final nowBar = find.byKey(const ValueKey('training-volume-bar-5'));
        expect(tester.getSize(nowBar).height, 4, reason: 'just started');

        final entry = await _finishPushToday(tester, store);

        expect(_weekSummary(tester), '1 of 3 done · Sep 28 – Oct 4');
        expect(
          find.byKey(const ValueKey('training-week-done-1')),
          findsOneWidget,
        );
        final semantics = tester.ensureSemantics();
        expect(
          find.bySemanticsLabel(
            RegExp(r'^Monday, September 28, today, workout done$'),
          ),
          findsOneWidget,
        );
        semantics.dispose();
        // Today's workout is done: the card says so and offers the next.
        expect(find.text('Done today: Upper Body Push'), findsOneWidget);
        expect(find.text('NEXT WORKOUT'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('training-card-title')))
              .data,
          'Upper Body Pull',
        );
        // The current week's bar grows with today's load.
        final volume = store.weeklyTrainingVolume();
        expect(volume.currentWeek.volumeKg, greaterThan(0));
        expect(
          tester.getSize(nowBar).height,
          closeTo(
            96 *
                volume.currentWeek.volumeKg /
                volume.weeks
                    .map((w) => w.volumeKg)
                    .reduce((a, b) => a > b ? a : b),
            0.01,
          ),
        );
        // Recent leads with the new workout.
        expect(
          find.byKey(ValueKey('training-recent-${entry.id}')),
          findsOneWidget,
        );
        expect(find.text('Mon, Sep 28 · 50 min'), findsOneWidget);
        await _leave(tester);
      });
    });

    testWidgets('the rotation and the week strip follow midnight', (
      tester,
    ) async {
      var now = DateTime(2026, 9, 28, 19);
      await withClock(Clock(() => now), () async {
        final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
          tester,
        );
        await _openTraining(tester);
        await _finishPushToday(tester, store);
        expect(find.text('Done today: Upper Body Push'), findsOneWidget);

        now = DateTime(2026, 9, 29, 7);
        store.maybeRollOverToToday();
        await settleFrames(tester);
        expect(find.text('NEXT WORKOUT'), findsOneWidget);
        expect(find.text('Done today: Upper Body Push'), findsNothing);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('training-card-title')))
              .data,
          'Upper Body Pull',
        );
        expect(
          tester.getSemantics(
            find.byKey(const ValueKey('training-week-day-2')),
          ),
          isSemantics(isSelected: true),
          reason: 'Tuesday is today now',
        );
        await _leave(tester);
      });
    });

    testWidgets('adjust: Edit opens the plan editor on this plan', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
          tester,
        );
        await _openTraining(tester);
        await _tap(tester, 'training-plan-menu');
        await tester.tap(find.text('Edit'));
        await settleFrames(tester);
        expect(find.byKey(const ValueKey('training-editor-scroll')), findsOne);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('training-editor-scroll')),
            matching: find.text('Strength plan'),
          ),
          findsWidgets,
        );
        expect(store.trainingPlans.single.title, 'Strength plan');
        await _leave(tester);
      });
    });

    testWidgets('quick start: Choose workout shows it, Start starts it', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        await pumpTrainingDesignHome(tester);
        await _openTraining(tester);
        await _tap(tester, 'training-quick-workouts');
        await tester.tap(find.byKey(const ValueKey('training-workout-2')));
        await settleFrames(tester);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('training-card-title')))
              .data,
          'Lower Body',
        );
        expect(find.text('WORKOUT 3'), findsOneWidget);
        expect(find.text('Last time 95 kg × 5'), findsOneWidget);
        await _tap(tester, 'training-start');
        expect(
          tester
              .widget<TrainingPlayerScreen>(find.byType(TrainingPlayerScreen))
              .workoutIndex,
          2,
        );
        await _leave(tester);
      });
    });

    testWidgets(
      'quick start: Plans opens the library, Ask Coach the plan brief',
      (tester) async {
        await withClock(Clock.fixed(kTrainingDesignNow), () async {
          final (:store, :server, storage: _) = await pumpTrainingDesignHome(
            tester,
          );
          await _openTraining(tester);
          await _tap(tester, 'training-open-plans');
          expect(find.byType(TrainingPlanPicker), findsOneWidget);
          expect(
            find.byKey(
              const ValueKey('training-select-$kTrainingDesignPlanId'),
            ),
            findsOneWidget,
          );
          await _tap(tester, 'training-library-close');

          // The header + is the one create action; the tile became Log.
          expect(
            find.byKey(const ValueKey('training-quick-create')),
            findsNothing,
          );
          expect(store.trainingPlans, hasLength(1), reason: 'nothing written');
          expect(server.trainingRows.keys, [kTrainingDesignPlanId]);

          await _tap(tester, 'training-discuss-plan');
          expect(store.selectedTab, 4);
          final coach = tester.widget<CoachChatScreen>(
            find.byType(CoachChatScreen),
          );
          expect(coach.selectedPlanForCoach?.id, kTrainingDesignPlanId);
          expect(
            server.requests.where((r) => r.url.path.contains('/functions/v1/')),
            isEmpty,
            reason: 'opening the brief sends nothing',
          );
          await _leave(tester);
        });
      },
    );

    testWidgets(
      'a saved hand-picked workout owns the card after a restart; Resume '
      'continues it',
      (tester) async {
        await withClock(Clock.fixed(kTrainingDesignNow), () async {
          final first = await pumpTrainingDesignHome(tester);
          await _openTraining(tester);
          expect(first.store.nextTrainingWorkoutForToday()!.workoutIndex, 0);
          await _tap(tester, 'training-quick-workouts');
          await tester.tap(find.byKey(const ValueKey('training-workout-2')));
          await settleFrames(tester);
          await _tap(tester, 'training-start');
          await _tap(tester, 'training-timer-back');
          await _tap(tester, 'training-timer-confirm-exit');
          await pumpRealUntil(
            tester,
            () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
            'save and leave finishes',
          );
          final saved = first.store.trainingSession!;
          expect(saved.workoutIndex, 2);
          expect(find.text('IN PROGRESS'), findsOneWidget);

          // Restart on the same backend and device cache: the pick is gone,
          // the saved session still decides what the card shows.
          await _leave(tester);
          final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
            tester,
            server: first.server,
            storage: first.storage,
          );
          await pumpRealUntil(
            tester,
            () => store.trainingSession != null,
            'the saved session is restored',
          );
          await _openTraining(tester);
          expect(store.nextTrainingWorkoutForToday()!.workoutIndex, 0);
          expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('training-card-title')))
                .data,
            'Lower Body',
          );
          expect(find.text('IN PROGRESS'), findsOneWidget);
          expect(find.byKey(const ValueKey('training-start')), findsNothing);
          expect(
            find.byKey(const ValueKey('training-quick-workouts')),
            findsNothing,
          );
          await _tap(tester, 'training-resume');
          final player = tester.widget<TrainingPlayerScreen>(
            find.byType(TrainingPlayerScreen),
          );
          expect(player.initialSnapshot?.sessionId, saved.sessionId);
          expect(player.initialSnapshot?.workoutIndex, 2);
          await _leave(tester);
        });
      },
    );

    testWidgets('weekly volume renders the store\'s trend', (tester) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
          tester,
        );
        await _openTraining(tester);
        final trend = store.weeklyTrainingVolume();
        String text(String key) =>
            tester.widget<Text>(find.byKey(ValueKey(key))).data!;
        // The running week first; nothing lifted yet, so no share line.
        expect(trend.currentWeek.volumeKg, 0);
        expect(text('training-volume-value'), '0');
        expect(text('training-volume-caption'), 'kg this week');
        expect(
          find.byKey(const ValueKey('training-volume-change')),
          findsNothing,
        );
        // Last week's bar shows last week, exact to the kilogram, against
        // the week before.
        await _tap(tester, 'training-volume-week-4');
        expect(trend.weeks[4].volumeKg, 8625);
        expect(text('training-volume-value'), '8,625');
        expect(text('training-volume-caption'), 'kg last week');
        expect(
          text('training-volume-change'),
          '↑ ${trend.changePercentAt(4)!.round()}% vs. the week before',
        );
        final highest = trend.weeks
            .map((w) => w.volumeKg)
            .reduce((a, b) => a > b ? a : b);
        for (var i = 0; i < 5; i++) {
          expect(
            tester
                .getSize(find.byKey(ValueKey('training-volume-bar-$i')))
                .height,
            closeTo(96 * trend.weeks[i].volumeKg / highest, 0.01),
          );
        }
        final semantics = tester.ensureSemantics();
        const spoken = [
          'Week of Aug 24: 6,798 kg',
          'Week of Aug 31: 7,415 kg',
          'Week of Sep 7: 7,106 kg',
          'Week of Sep 14: 7,892 kg',
          'Week of Sep 21: 8,625 kg',
          'This week so far: 0 kg',
        ];
        for (var i = 0; i < spoken.length; i++) {
          expect(
            tester.getSemantics(
              find.byKey(ValueKey('training-volume-week-$i')),
            ),
            isSemantics(label: spoken[i], isButton: true, isSelected: i == 4),
          );
        }
        semantics.dispose();
        await _leave(tester);
      });
    });

    testWidgets('Recent: a row opens that workout, All workouts the history', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
          tester,
        );
        await _openTraining(tester);
        final recent = store.recentWorkoutSummaries(limit: 3);
        expect(recent.map((s) => s.title), [
          'Lower Body',
          'Upper Body Pull',
          'Upper Body Push',
        ]);
        expect(recent.first.personalRecords, 2);
        expect(
          find.byKey(ValueKey('training-recent-pr-${recent.first.entry.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('training-recent-pr-${recent[1].entry.id}')),
          findsNothing,
        );
        final semantics = tester.ensureSemantics();
        expect(
          find.bySemanticsLabel('Lower Body, Fri, Sep 25 · 52 min, 2 PRs'),
          findsOneWidget,
        );
        semantics.dispose();

        final pull = recent[1].entry;
        await _tap(tester, 'training-recent-${pull.id}');
        final detail = tester.widget<TrainingHistoryDetail>(
          find.byType(TrainingHistoryDetail),
        );
        expect(detail.entry.id, pull.id);
        expect(find.text('Upper Body Pull'), findsWidgets);
        await _tap(tester, 'training-history-detail-back');
        expect(find.byType(TrainingHistoryDetail), findsNothing);

        // "All workouts" sits at the right edge, flush with the card.
        final link = find.byKey(const ValueKey('training-recent-all'));
        await tester.ensureVisible(link);
        await settleFrames(tester);
        expect(
          tester.getRect(link).right,
          tester.getRect(find.byKey(const ValueKey('training-recent'))).right,
        );
        await _tap(tester, 'training-recent-all');
        expect(find.byType(TrainingHistoryScreen), findsOneWidget);
        await _leave(tester);
      });
    });

    testWidgets('no plan: empty card with Coach and Create, no plan widgets', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _, storage: _) = await pumpTrainingDesignHome(
          tester,
          plans: const [],
          history: const [],
        );
        await _openTraining(tester);
        expect(find.byKey(const ValueKey('training-empty')), findsOneWidget);
        expect(_weekSummary(tester), '0 done · Sep 28 – Oct 4');
        for (final key in [
          'training-plan-title',
          'training-start',
          'training-plan-menu',
          'training-quick-log',
          'training-volume',
          'training-recent',
        ]) {
          expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
        }
        await _tap(tester, 'training-empty-create');
        expect(
          find.byKey(const ValueKey('training-editor-title')),
          findsOneWidget,
        );
        await _tap(tester, 'training-editor-close');
        await _tap(tester, 'training-empty-coach');
        expect(store.selectedTab, 4);
        expect(store.trainingPlans, isEmpty);
        await _leave(tester);
      });
    });

    testWidgets('tap targets meet the 44 px guideline', (tester) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        await pumpTrainingDesignHome(tester);
        await _openTraining(tester);
        final semantics = tester.ensureSemantics();
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        semantics.dispose();
        await _leave(tester);
      });
    });
  });

  group('screen', () {
    final plan = trainingDesignPlan();
    final history = trainingDesignHistory(plan);

    testWidgets('Start passes the plan and the rotation index it shows', (
      tester,
    ) async {
      // Push was last: the rotation continues with Pull (index 1).
      final pushed = history.where((e) => e.snapshot.workoutIndex != 2);
      final next = nextTrainingWorkout(
        plan: plan,
        history: pushed.take(pushed.length - 1).toList(),
        now: kTrainingDesignNow,
      )!;
      expect(next.workoutIndex, 1);
      final started = <(TrainingPlan, int)>[];
      await pumpLocalized(
        tester,
        _screen(
          plans: [plan],
          next: next,
          start: (plan, index) => started.add((plan, index)),
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
        settle: true,
      );
      expect(find.text('Upper Body Pull'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('training-start')));
      expect(started, [(plan, 1)]);
    });

    testWidgets('a running session turns Start into Resume', (tester) async {
      var resumed = 0;
      var started = 0;
      await pumpLocalized(
        tester,
        _screen(
          plans: [plan],
          active: true,
          resume: () => resumed++,
          start: (_, _) => started++,
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
        settle: true,
      );
      expect(find.byKey(const ValueKey('training-start')), findsNothing);
      expect(find.text('Your workout is ready to continue.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('training-resume')));
      expect((resumed, started), (1, 0));
    });

    testWidgets('adjust: Delete asks first and passes the plan id', (
      tester,
    ) async {
      final deleted = <String>[];
      await pumpLocalized(
        tester,
        _screen(
          plans: [plan],
          delete: (id) async {
            deleted.add(id);
            return SyncDelivery.delivered;
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
        settle: true,
      );
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Plan options'), findsOneWidget);
      semantics.dispose();
      await tester.tap(find.byKey(const ValueKey('training-plan-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete plan'));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);
      await tester.tap(find.byKey(const ValueKey('training-delete-confirm')));
      await tester.pumpAndSettle();
      expect(deleted, [plan.id]);
    });

    testWidgets('Review adoption opens the review of the selected conflict', (
      tester,
    ) async {
      final reviewed = <TrainingPlan>[];
      var starts = 0;
      await pumpLocalized(
        tester,
        TrainingScreen(
          plans: [plan],
          selectedPlanId: plan.id,
          adoptionConflicts: [plan],
          onReviewAdoption: (conflict) async {
            reviewed.add(conflict);
            final context = tester.element(find.byType(TrainingScreen));
            await showTrainingPlanEditor(
              context,
              initialDraft: conflict.proposal,
              explanation: 'Review before confirming',
              onSave: (_) async => SyncDelivery.delivered,
            );
          },
          onCreatePlan: (_) async => SyncDelivery.delivered,
          onUpdatePlan: (_, _) async => SyncDelivery.delivered,
          onSelectPlan: (_) {},
          onDeletePlan: (_) async => SyncDelivery.delivered,
          onStartWorkout: (_, _) => starts++,
          onOpenCoach: () {},
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
        settle: true,
      );
      expect(find.byKey(const ValueKey('training-start')), findsNothing);
      final primary = find.byKey(
        const ValueKey('training-review-adoption-primary'),
      );
      await tester.ensureVisible(primary);
      await tester.pumpAndSettle();
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(reviewed.map((p) => p.id), [plan.id]);
      expect(find.text('Review before confirming'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('training-editor-scroll')),
          matching: find.text('Strength plan'),
        ),
        findsWidgets,
      );
      expect(starts, 0);
    });

    testWidgets('a saved session shows its own workout under Resume', (
      tester,
    ) async {
      final session = TrainingSessionSnapshot(
        plan: plan,
        sessionId: '00000000-0000-4000-8000-00000000abcd',
        startedAt: kTrainingDesignNow.subtract(const Duration(minutes: 5)),
        workoutIndex: 2,
        exerciseIndex: 0,
        setIndex: 0,
        phase: TrainingSessionPhase.exercise,
        remainingMilliseconds: 0,
      );
      var resumed = 0;
      await pumpLocalized(
        tester,
        TrainingScreen(
          plans: [plan],
          onCreatePlan: (_) async => SyncDelivery.delivered,
          onUpdatePlan: (_, _) async => SyncDelivery.delivered,
          onSelectPlan: (_) {},
          onDeletePlan: (_) async => SyncDelivery.delivered,
          onStartWorkout: (_, _) {},
          onOpenCoach: () {},
          nextWorkout: nextTrainingWorkout(
            plan: plan,
            history: history,
            now: kTrainingDesignNow,
          ),
          history: history,
          hasActiveSession: true,
          activeSession: session,
          onResumeWorkout: () => resumed++,
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
        settle: true,
      );
      expect(find.text('Lower Body'), findsOneWidget);
      expect(find.text('Upper Body Push'), findsNothing);
      expect(find.text('IN PROGRESS'), findsOneWidget);
      expect(find.text('Last time 95 kg × 5'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('training-resume')));
      expect(resumed, 1);
    });

    testWidgets('a hand-picked workout shows its own Last time', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        _screen(
          plans: [plan],
          next: nextTrainingWorkout(
            plan: plan,
            history: history,
            now: kTrainingDesignNow,
          ),
          history: history,
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
        settle: true,
      );
      final chooser = find.byKey(const ValueKey('training-quick-workouts'));
      await tester.ensureVisible(chooser);
      await tester.pumpAndSettle();
      await tester.tap(chooser);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('training-workout-1')));
      await tester.pumpAndSettle();
      expect(find.text('Upper Body Pull'), findsOneWidget);
      expect(find.text('Last time 60 kg × 8'), findsOneWidget);
      // The card is scrolled into view with its Start.
      expect(
        find.byKey(const ValueKey('training-start')).hitTestable(),
        findsOneWidget,
      );
    });

    testWidgets('a one-workout plan offers no workout chooser', (tester) async {
      final single = CoachTrainingProposal(
        title: 'Solo',
        workouts: [plan.workouts.first],
      ).toTrainingPlan(id: 'solo');
      await pumpLocalized(
        tester,
        _screen(plans: [single]),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
        settle: true,
      );
      expect(
        find.byKey(const ValueKey('training-quick-workouts')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('training-open-plans')), findsOneWidget);
    });

    testWidgets('Log workout replaces the duplicate create tile', (
      tester,
    ) async {
      var logs = 0;
      await _pumpScreen(
        tester,
        _screen(plans: [plan], logWorkout: () => logs++),
      );
      expect(find.byKey(const ValueKey('training-quick-create')), findsNothing);
      expect(
        find.byKey(const ValueKey('training-create')),
        findsOneWidget,
        reason: 'the header + still creates a plan',
      );
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Log workout'), findsOneWidget);
      semantics.dispose();
      await _tapScreen(tester, 'training-quick-log');
      expect(logs, 1);
    });

    testWidgets('without log callbacks nothing offers logging', (tester) async {
      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          next: nextTrainingWorkout(
            plan: plan,
            history: history,
            now: kTrainingDesignNow,
          ),
          history: history,
        ),
      );
      for (final key in [
        'training-quick-log',
        'training-log-done',
        'training-log-coach',
        'training-history-retry',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
    });

    testWidgets('Log as done passes the shown workout; a session hides it', (
      tester,
    ) async {
      final logged = <(TrainingPlan, int)>[];
      final next = nextTrainingWorkout(
        plan: plan,
        history: history,
        now: kTrainingDesignNow,
      )!;
      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          next: next,
          history: history,
          logPlanned: (p, i) => logged.add((p, i)),
        ),
      );
      expect(find.text('Log as done'), findsOneWidget);
      await _tapScreen(tester, 'training-log-done');
      expect(logged, [(plan, next.upNextWorkoutIndex)]);

      await _tapScreen(tester, 'training-quick-workouts');
      await tester.tap(find.byKey(const ValueKey('training-workout-2')));
      await tester.pumpAndSettle();
      await _tapScreen(tester, 'training-log-done');
      expect(logged.last, (plan, 2), reason: 'the hand-picked workout');

      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          next: next,
          history: history,
          active: true,
          logPlanned: (p, i) => logged.add((p, i)),
        ),
      );
      expect(find.byKey(const ValueKey('training-log-done')), findsNothing);
      expect(find.byKey(const ValueKey('training-resume')), findsOneWidget);
    });

    testWidgets('after a workout today: "Done today" and Start offers the '
        'next one', (tester) async {
      final today = trainingDesignEntry(
        plan,
        0,
        finishedAt: DateTime(2026, 9, 28, 18),
        minutes: 50,
        topKg: _push,
      );
      final done = [...history, today];
      final next = nextTrainingWorkout(
        plan: plan,
        history: done,
        now: kTrainingDesignNow,
      )!;
      expect((next.completedToday, next.upNextWorkoutIndex), (true, 1));
      final started = <(TrainingPlan, int)>[];
      final logged = <(TrainingPlan, int)>[];
      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          next: next,
          history: done,
          start: (p, i) => started.add((p, i)),
          logPlanned: (p, i) => logged.add((p, i)),
        ),
      );
      expect(find.text('Done today: Upper Body Push'), findsOneWidget);
      expect(find.text('NEXT WORKOUT'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('training-card-title')))
            .data,
        'Upper Body Pull',
      );
      expect(find.text('Last time 60 kg × 8'), findsOneWidget);
      await _tapScreen(tester, 'training-start');
      await _tapScreen(tester, 'training-log-done');
      expect(started, [(plan, 1)]);
      expect(logged, [(plan, 1)]);
    });

    testWidgets('a stale store copy with more workouts never indexes past '
        'the selected plan', (tester) async {
      // The store's copy still has a fourth workout the saved plan dropped.
      final stale = TrainingPlan(
        id: plan.id,
        proposal: CoachTrainingProposal(
          title: plan.title,
          workouts: [
            ...plan.workouts,
            TrainingWorkout(
              title: 'Conditioning',
              exercises: [
                TrainingExercise(
                  name: 'Rower',
                  sets: 1,
                  reps: 10,
                  restSeconds: 0,
                ),
              ],
            ),
          ],
        ),
      );
      final next = TrainingNextWorkout(
        plan: stale,
        workoutIndex: 2,
        completedToday: true,
        exercises: [
          for (final exercise in stale.workouts[2].exercises)
            TrainingExercisePreview(exercise: exercise),
        ],
      );
      expect(next.upNextWorkoutIndex, 3, reason: 'past the saved plan');
      final started = <(TrainingPlan, int)>[];
      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          next: next,
          start: (p, i) => started.add((p, i)),
        ),
      );
      expect(find.text('Done today: Lower Body'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('training-card-title')))
            .data,
        'Upper Body Push',
        reason: 'the rotation wraps to the first workout',
      );
      await _tapScreen(tester, 'training-start');
      expect(started, [(plan, 0)]);
    });

    testWidgets('a stale store copy with fewer workouts follows the selected '
        "plan's rotation", (tester) async {
      // The store's copy predates the saved plan's third workout.
      final stale = TrainingPlan(
        id: plan.id,
        proposal: CoachTrainingProposal(
          title: plan.title,
          workouts: plan.workouts.take(2).toList(),
        ),
      );
      final next = TrainingNextWorkout(
        plan: stale,
        workoutIndex: 1,
        completedToday: true,
        exercises: [
          for (final exercise in stale.workouts[1].exercises)
            TrainingExercisePreview(exercise: exercise),
        ],
      );
      expect(next.upNextWorkoutIndex, 0, reason: 'wrapped by the stale copy');
      final started = <(TrainingPlan, int)>[];
      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          next: next,
          start: (p, i) => started.add((p, i)),
        ),
      );
      expect(find.text('Done today: Upper Body Pull'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('training-card-title')))
            .data,
        'Lower Body',
        reason: 'the saved plan has a third workout after Pull',
      );
      await _tapScreen(tester, 'training-start');
      expect(started, [(plan, 2)]);
    });

    testWidgets('a picked workout finds Last time by name in a free log', (
      tester,
    ) async {
      final log = _pulldownLog(performedOn: DateTime(2026, 9, 26));
      await _pumpScreen(tester, _screen(plans: [plan], history: [log]));
      await _tapScreen(tester, 'training-quick-workouts');
      await tester.tap(find.byKey(const ValueKey('training-workout-1')));
      await tester.pumpAndSettle();
      expect(find.text('Upper Body Pull'), findsOneWidget);
      expect(find.text('Last time 55 kg × 10'), findsOneWidget);
    });

    testWidgets('a history load failure is said, with retry', (tester) async {
      var retries = 0;
      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          historyLoadFailed: true,
          retryHistory: () => retries++,
        ),
      );
      expect(
        find.text(
          'Your workout history could not be loaded, so this overview may '
          'be incomplete.',
        ),
        findsOneWidget,
      );
      await _tapScreen(tester, 'training-history-retry');
      expect(retries, 1);
    });

    testWidgets('"Tell the Coach instead" opens the Coach log', (tester) async {
      var opened = 0;
      await _pumpScreen(
        tester,
        _screen(plans: [plan], logWorkout: () {}, coachLog: () => opened++),
      );
      expect(find.text('Tell the Coach instead'), findsOneWidget);
      await _tapScreen(tester, 'training-log-coach');
      expect(opened, 1);
    });

    testWidgets('Recent shows a log without duration as "Logged"', (
      tester,
    ) async {
      final log = _pulldownLog(performedOn: DateTime(2026, 9, 27));
      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          history: [log],
          recent: recentTrainingWorkouts([log]),
        ),
      );
      expect(find.text('Sun, Sep 27 · Logged'), findsOneWidget);
      expect(find.text('Sun, Sep 27 · 0 min'), findsNothing);
    });

    testWidgets('Recent never tags a played workout as "Logged"', (
      tester,
    ) async {
      // Review TUI-1: ✓ on set 1, Finish 10 min later finishes at that set,
      // so the played workout has no duration either.
      final at = DateTime(2026, 9, 27, 18);
      final controller = withClock(
        Clock.fixed(at),
        () => TrainingSessionController(plan: plan, autoTick: false),
      );
      withClock(Clock.fixed(at), controller.completeCurrentSet);
      final played = withClock(
        Clock.fixed(at.add(const Duration(minutes: 10))),
        controller.completion,
      );
      controller.dispose();
      expect(trainingEntryHasDuration(played), isFalse);
      await _pumpScreen(
        tester,
        _screen(
          plans: [plan],
          history: [played],
          recent: recentTrainingWorkouts([played]),
        ),
      );
      expect(find.text('Sun, Sep 27'), findsOneWidget);
      expect(find.text('Sun, Sep 27 · Logged'), findsNothing);
      expect(find.text('Sun, Sep 27 · 0 min'), findsNothing);
    });

    testWidgets('no plan: the empty card offers Log workout', (tester) async {
      var logs = 0;
      await _pumpScreen(
        tester,
        _screen(plans: const [], logWorkout: () => logs++),
      );
      await _tapScreen(tester, 'training-empty-log');
      expect(logs, 1);
    });

    testWidgets('no plan: the empty card offers "Tell the Coach instead"', (
      tester,
    ) async {
      var opened = 0;
      await _pumpScreen(
        tester,
        _screen(plans: const [], logWorkout: () {}, coachLog: () => opened++),
      );
      expect(find.text('Tell the Coach instead'), findsOneWidget);
      // Both links keep the 48 px target at the default text size too.
      for (final key in ['training-empty-log', 'training-empty-log-coach']) {
        expect(
          tester.getSize(find.byKey(ValueKey(key))).height,
          greaterThanOrEqualTo(48),
          reason: key,
        );
      }
      await _tapScreen(tester, 'training-empty-log-coach');
      expect(opened, 1);

      await _pumpScreen(tester, _screen(plans: const [], logWorkout: () {}));
      expect(find.byKey(const ValueKey('training-empty-log')), findsOneWidget);
      expect(find.text('Tell the Coach instead'), findsNothing);
    });

    for (final locale in ['de', 'en']) {
      testWidgets('no plan, 320 px at 2.0 text, $locale: the empty card '
          'keeps both log links reachable', (tester) async {
        await pumpLocalized(
          tester,
          _screen(plans: const [], logWorkout: () {}, coachLog: () {}),
          locale: Locale(locale),
          textScale: 2,
          surfaceSize: const Size(320, 568),
          settle: true,
        );
        for (final key in ['training-empty-log', 'training-empty-log-coach']) {
          final target = find.byKey(ValueKey(key));
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          final rect = tester.getRect(target);
          expect(rect.right, lessThanOrEqualTo(320), reason: key);
          expect(rect.height, greaterThanOrEqualTo(48), reason: key);
          expect(target.hitTestable(), findsOneWidget, reason: key);
        }
        expect(tester.takeException(), isNull);
      });
    }

    for (final (size, scale) in [
      (const Size(390, 844), 1.3),
      (const Size(320, 568), 1.0),
      (const Size(320, 568), 2.0),
    ]) {
      for (final locale in ['de', 'en']) {
        testWidgets('no overflow at $size ${scale}x $locale', (tester) async {
          await pumpLocalized(
            tester,
            TrainingScreen(
              plans: [plan],
              onCreatePlan: (_) async => SyncDelivery.delivered,
              onUpdatePlan: (_, _) async => SyncDelivery.delivered,
              onSelectPlan: (_) {},
              onDeletePlan: (_) async => SyncDelivery.delivered,
              onStartWorkout: (_, _) {},
              onOpenCoach: () {},
              onOpenHistory: () {},
              nextWorkout: nextTrainingWorkout(
                plan: plan,
                history: history,
                now: kTrainingDesignNow,
              ),
              week: trainingWeekOf(
                now: kTrainingDesignNow,
                history: history,
                plan: plan,
              ),
              volume: trainingVolumeTrend(
                history: history,
                now: kTrainingDesignNow,
              ),
              recentWorkouts: recentTrainingWorkouts(history),
              history: history,
              onLogWorkout: () {},
              onLogPlannedWorkout: (_, _) {},
              onOpenCoachLog: () {},
              historyLoadFailed: true,
              onRetryHistory: () {},
            ),
            locale: Locale(locale),
            textScale: scale,
            surfaceSize: size,
            settle: true,
          );
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 12; i++) {
            await tester.drag(scrollable, const Offset(0, -300));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
