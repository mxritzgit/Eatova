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
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/training/training_history_screen.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/screens/training/training_plan_picker.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
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
);

void main() {
  group('shell', () {
    testWidgets('header: history opens the history, + opens a new plan draft', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _) = await pumpTrainingDesignHome(tester);
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
        final title = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(const ValueKey('training-editor-title')),
            matching: find.byType(EditableText),
          ),
        );
        expect(title.controller.text, isEmpty, reason: 'a new, empty plan');
        expect(store.trainingPlans, hasLength(1), reason: 'nothing written');
        await _leave(tester);
      });
    });

    testWidgets('Start opens the player on the rotation\'s next workout', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _) = await pumpTrainingDesignHome(tester);
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
        final (:store, server: _) = await pumpTrainingDesignHome(tester);
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
        // Today's workout is done: the card says so instead of "next".
        expect(find.text('DONE TODAY'), findsOneWidget);
        expect(find.text('NEXT WORKOUT'), findsNothing);
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
        final (:store, server: _) = await pumpTrainingDesignHome(tester);
        await _openTraining(tester);
        await _finishPushToday(tester, store);
        expect(find.text('DONE TODAY'), findsOneWidget);

        now = DateTime(2026, 9, 29, 7);
        store.maybeRollOverToToday();
        await settleFrames(tester);
        expect(find.text('NEXT WORKOUT'), findsOneWidget);
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
        final (:store, server: _) = await pumpTrainingDesignHome(tester);
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
          final (:store, :server) = await pumpTrainingDesignHome(tester);
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

          await _tap(tester, 'training-quick-create');
          expect(
            find.byKey(const ValueKey('training-editor-title')),
            findsOneWidget,
          );
          await _tap(tester, 'training-editor-close');

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

    testWidgets('weekly volume renders the store\'s trend', (tester) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _) = await pumpTrainingDesignHome(tester);
        await _openTraining(tester);
        final trend = store.weeklyTrainingVolume();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('training-volume-value')))
              .data,
          trend.lastFullWeek!.tonnes.toStringAsFixed(1),
        );
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('training-volume-change')),
              )
              .data,
          '↑ ${trend.changePercent!.round()}% vs. the week before',
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
        expect(
          tester.getSemantics(
            find.byKey(const ValueKey('training-volume-chart')),
          ),
          isSemantics(
            label:
                'Week of Aug 24: 6.8 tonnes. Week of Aug 31: 7.4 tonnes. '
                'Week of Sep 7: 7.1 tonnes. Week of Sep 14: 7.9 tonnes. '
                'Week of Sep 21: 8.6 tonnes. This week so far: 0.0 tonnes',
          ),
        );
        semantics.dispose();
        await _leave(tester);
      });
    });

    testWidgets('Recent: a row opens that workout, All workouts the history', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _) = await pumpTrainingDesignHome(tester);
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

        await _tap(tester, 'training-recent-all');
        expect(find.byType(TrainingHistoryScreen), findsOneWidget);
        await _leave(tester);
      });
    });

    testWidgets('no plan: empty card with Coach and Create, no plan widgets', (
      tester,
    ) async {
      await withClock(Clock.fixed(kTrainingDesignNow), () async {
        final (:store, server: _) = await pumpTrainingDesignHome(
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
          'training-quick-create',
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
