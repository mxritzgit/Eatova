// The Coach training brief as a sheet of its own (redesign 2026-10-04):
// quick goals and the own-goal field, the pinned action, the summary, the
// steppers' limits, the intent cards and the keyboard. The send path through
// the chat is coach_training_plan_flow_test.dart.

import 'package:eatova/src/models/coach_training_context.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/coach/coach_training_brief.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

TrainingPlan _plan({String goal = 'Build strength'}) => TrainingPlan(
  id: 'plan-a',
  proposal: CoachTrainingProposal(
    title: 'Strength plan',
    description: 'Three sessions a week with dumbbells.',
    goal: goal,
    workouts: [
      TrainingWorkout(
        title: 'Full body',
        exercises: [
          TrainingExercise(name: 'Squat', sets: 3, reps: 8, restSeconds: 90),
        ],
      ),
    ],
  ),
);

/// What the sheet handed back, once it closed.
final class _Outcome {
  CoachTrainingBriefSubmission? submission;
  bool closed = false;
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<_Outcome> _open(
  WidgetTester tester, {
  TrainingPlan? plan,
  Locale locale = const Locale('en'),
  double scale = 1,
  Size size = const Size(390, 844),
}) async {
  final outcome = _Outcome();
  final active = ValueNotifier<bool>(true);
  addTearDown(active.dispose);
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () async {
            outcome.submission = await showCoachTrainingBrief(
              context,
              selectedPlan: plan,
              canSubmit: () => true,
              isActive: active,
            );
            outcome.closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
    locale: locale,
    textScale: scale,
    surfaceSize: size,
    safeArea: false,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return outcome;
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

/// Sends the brief straight from where the action is, without scrolling.
Future<CoachTrainingContext> _send(
  WidgetTester tester,
  _Outcome outcome,
) async {
  await tester.tap(_key('coach-brief-submit'));
  await tester.pumpAndSettle();
  expect(outcome.closed, isTrue, reason: 'the brief was not sent');
  return outcome.submission!.context;
}

String? _summary(WidgetTester tester) =>
    tester.widget<Text>(_key('coach-brief-summary')).data;

bool _chipSelected(WidgetTester tester, String key) =>
    tester.widget<FilterChipPill>(_key(key)).selected;

void main() {
  group('goal', () {
    testWidgets('a quick goal chip writes its goal into the request', (
      tester,
    ) async {
      final outcome = await _open(tester);
      expect(_chipSelected(tester, 'coach-brief-goal-general'), isTrue);
      expect(_key('coach-brief-goal'), findsNothing);

      await _tap(tester, 'coach-brief-goal-muscle');
      expect(_chipSelected(tester, 'coach-brief-goal-muscle'), isTrue);
      expect(_chipSelected(tester, 'coach-brief-goal-general'), isFalse);

      final sent = await _send(tester, outcome);
      expect(sent.goal, 'Build muscle');
      expect(sent.intent, CoachTrainingIntent.create);
      expect(sent.selectedPlan, isNull);
    });

    testWidgets('quick goals are localized (de)', (tester) async {
      final outcome = await _open(tester, locale: const Locale('de'));
      await _tap(tester, 'coach-brief-goal-endurance');
      expect((await _send(tester, outcome)).goal, 'Ausdauer');
    });

    testWidgets('Own goal opens a focused field and sends what is typed', (
      tester,
    ) async {
      final outcome = await _open(tester);
      await _tap(tester, 'coach-brief-goal-own');
      final field = _key('coach-brief-goal');
      expect(field, findsOneWidget);
      expect(_chipSelected(tester, 'coach-brief-goal-own'), isTrue);
      expect(_chipSelected(tester, 'coach-brief-goal-general'), isFalse);
      expect(
        tester.widget<TextField>(field).focusNode!.hasFocus,
        isTrue,
        reason: 'the keyboard comes up for the own goal',
      );

      await tester.enterText(field, 'Climb a 6b by spring');
      await tester.pumpAndSettle();
      expect((await _send(tester, outcome)).goal, 'Climb a 6b by spring');
    });

    testWidgets('a quick goal after Own goal closes the field again', (
      tester,
    ) async {
      final outcome = await _open(tester);
      await _tap(tester, 'coach-brief-goal-own');
      await tester.enterText(_key('coach-brief-goal'), 'Something else');
      await _tap(tester, 'coach-brief-goal-strength');
      expect(_key('coach-brief-goal'), findsNothing);
      expect((await _send(tester, outcome)).goal, 'Build strength');
    });

    testWidgets('a plan goal that is no quick goal opens in its own field', (
      tester,
    ) async {
      final outcome = await _open(tester, plan: _plan(goal: 'Hypertrophy'));
      expect(_chipSelected(tester, 'coach-brief-goal-own'), isTrue);
      for (final key in ['general', 'strength', 'muscle']) {
        expect(_chipSelected(tester, 'coach-brief-goal-$key'), isFalse);
      }
      final field = tester.widget<TextField>(_key('coach-brief-goal'));
      expect(field.controller!.text, 'Hypertrophy');
      expect((await _send(tester, outcome)).goal, 'Hypertrophy');
    });

    testWidgets('an emptied own goal blocks sending and says why', (
      tester,
    ) async {
      final outcome = await _open(tester);
      await _tap(tester, 'coach-brief-goal-own');
      await tester.enterText(_key('coach-brief-goal'), '   ');
      await tester.pumpAndSettle();
      await tester.tap(_key('coach-brief-submit'));
      await tester.pumpAndSettle();
      expect(outcome.closed, isFalse);
      expect(find.text('Please fill this in.'), findsOneWidget);
      expect(find.textContaining('Check your goal'), findsOneWidget);
    });
  });

  group('pinned action', () {
    for (final (name, size, scale) in <(String, Size, double)>[
      ('phone', const Size(390, 844), 1.0),
      ('320 px at 2x text', const Size(320, 568), 2.0),
    ]) {
      testWidgets('reachable without scrolling ($name)', (tester) async {
        final outcome = await _open(
          tester,
          plan: _plan(),
          size: size,
          scale: scale,
        );
        final submit = _key('coach-brief-submit');
        expect(
          find.descendant(of: _key('coach-brief-scroll'), matching: submit),
          findsNothing,
          reason: 'the action does not scroll with the form',
        );
        final rect = tester.getRect(submit);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(size.height));
        expect(submit.hitTestable(), findsOneWidget);
        expect(find.text('Uses 1 Coach request'), findsOneWidget);

        // Deep in the form, the action is still where it was.
        await tester.ensureVisible(_key('coach-brief-wish'));
        await tester.pumpAndSettle();
        expect(tester.getRect(submit), rect);
        final sent = await _send(tester, outcome);
        expect(sent.intent, CoachTrainingIntent.discuss);
      });
    }

    testWidgets('with the keyboard up the field stays above the action', (
      tester,
    ) async {
      await _open(tester, plan: _plan());
      await _tap(tester, 'coach-brief-goal-own');
      // 300 logical px of keyboard at the harness' 3x pixel ratio.
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final field = tester.getRect(_key('coach-brief-goal'));
      final bar = tester.getRect(_key('coach-brief-submit'));
      expect(field.bottom, lessThanOrEqualTo(bar.top));
      expect(bar.bottom, lessThanOrEqualTo(844 - 300));
      expect(_key('coach-brief-goal').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('summary and steppers', () {
    testWidgets('the summary above the action follows the choices', (
      tester,
    ) async {
      final outcome = await _open(tester);
      expect(_summary(tester), '3× a week · 30 min · Bodyweight');
      await _tap(tester, 'coach-brief-equipment-gym');
      await _tap(tester, 'coach-brief-sessions-inc');
      await _tap(tester, 'coach-brief-sessions-inc');
      await _tap(tester, 'coach-brief-minutes-dec');
      expect(_summary(tester), '5× a week · 20 min · Gym');

      final sent = await _send(tester, outcome);
      expect(sent.equipment, CoachTrainingEquipment.gym);
      expect(sent.sessionsPerWeek, 5);
      expect(sent.minutesPerSession, 20);
    });

    testWidgets('the summary is localized (de)', (tester) async {
      await _open(tester, locale: const Locale('de'));
      expect(_summary(tester), '3× pro Woche · 30 Min. · Körpergewicht');
    });

    testWidgets('steppers stop at the limits and send what they show', (
      tester,
    ) async {
      final outcome = await _open(tester);
      bool enabled(String key) =>
          tester.widget<InkWell>(_key(key)).onTap != null;
      for (var i = 0; i < 6; i++) {
        await _tap(tester, 'coach-brief-sessions-inc');
      }
      expect(enabled('coach-brief-sessions-inc'), isFalse);
      for (var i = 0; i < 3; i++) {
        await _tap(tester, 'coach-brief-minutes-inc');
      }
      expect(enabled('coach-brief-minutes-inc'), isFalse);
      expect(_summary(tester), '7× a week · 90 min · Bodyweight');
      final sent = await _send(tester, outcome);
      expect(sent.sessionsPerWeek, 7);
      expect(sent.minutesPerSession, 90);
    });

    testWidgets('the lower limits: one session, 15 minutes', (tester) async {
      final outcome = await _open(tester);
      for (var i = 0; i < 2; i++) {
        await _tap(tester, 'coach-brief-sessions-dec');
        await _tap(tester, 'coach-brief-minutes-dec');
      }
      expect(
        tester.widget<InkWell>(_key('coach-brief-sessions-dec')).onTap,
        isNull,
      );
      expect(
        tester.widget<InkWell>(_key('coach-brief-minutes-dec')).onTap,
        isNull,
      );
      final sent = await _send(tester, outcome);
      expect(sent.sessionsPerWeek, 1);
      expect(sent.minutesPerSession, 15);
    });

    testWidgets('a stepper is one adjustable node for screen readers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _open(tester);
      final row = find.bySemanticsLabel('Sessions per week');
      expect(
        tester.getSemantics(row),
        isSemantics(
          label: 'Sessions per week',
          value: '3× a week',
          increasedValue: '4× a week',
          decreasedValue: '2× a week',
          hasIncreaseAction: true,
          hasDecreaseAction: true,
        ),
      );
      tester.semantics.increase(find.semantics.byLabel('Sessions per week'));
      await tester.pumpAndSettle();
      expect(_summary(tester), '4× a week · 30 min · Bodyweight');
      handle.dispose();
    });
  });

  group('intent', () {
    testWidgets('without a plan there is nothing to choose: create', (
      tester,
    ) async {
      await _open(tester);
      expect(_key('coach-brief-intent-adapt'), findsNothing);
      expect(_key('coach-brief-intent-discuss'), findsNothing);
      expect(
        tester.widget<PrimaryActionButton>(_key('coach-brief-submit')).label,
        'Create plan draft',
      );
    });

    testWidgets('the Adapt card sends adapt and relabels the action', (
      tester,
    ) async {
      final plan = _plan();
      final outcome = await _open(tester, plan: plan);
      PrimaryActionButton action() =>
          tester.widget<PrimaryActionButton>(_key('coach-brief-submit'));
      expect(action().label, 'Discuss plan');
      await _tap(tester, 'coach-brief-intent-adapt');
      expect(action().label, 'Draft changes');
      final sent = await _send(tester, outcome);
      expect(sent.intent, CoachTrainingIntent.adapt);
      expect(sent.selectedPlan, same(plan.proposal));
      expect(outcome.submission!.wish, isNotEmpty);
    });
  });
}
