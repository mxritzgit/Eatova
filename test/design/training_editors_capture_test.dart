// Visual evidence for the training editors in the dark redesign (2026-10-03):
// the log editor's day and type chips, its suggestion and "Add set" pills and
// the calendar sheet; the Coach training brief (redesign 2026-10-04: intent
// cards, the plan row and its preview, goal chips, segments, steppers and the
// pinned action); the plan editor's review and its foldable exercise cards;
// the history rows. Each surface also renders on a 320 px phone at 2x text.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/training-editors-*.png; without it the suite still
// checks the selection semantics, the 44 px targets and that every surface
// renders without an exception or overflow.

import 'package:clock/clock.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/coach/coach_training_brief.dart';
import 'package:eatova/src/screens/training/training_history_screen.dart';
import 'package:eatova/src/screens/training/training_log_editor.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

/// Saturday 2026-10-03, 18:30 local.
final _now = DateTime(2026, 10, 3, 18, 30);

const _logId = '3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e';

CoachTrainingProposal _proposal() => CoachTrainingProposal(
  title: 'Strength plan',
  description: 'Three sessions a week with dumbbells and a bench.',
  goal: 'Build strength',
  workouts: [
    TrainingWorkout(
      title: 'Upper Body Push',
      exercises: [
        TrainingExercise(
          name: 'Bench press',
          sets: 4,
          reps: 8,
          restSeconds: 120,
        ),
        TrainingExercise(
          name: 'Incline dumbbell press',
          sets: 3,
          reps: 10,
          restSeconds: 90,
        ),
        TrainingExercise(
          name: 'Plank',
          sets: 3,
          durationSeconds: 45,
          restSeconds: 45,
        ),
      ],
    ),
    TrainingWorkout(
      title: 'Lower Body',
      exercises: [
        TrainingExercise(name: 'Squat', sets: 4, reps: 6, restSeconds: 150),
      ],
    ),
  ],
);

TrainingPlan _plan() => TrainingPlan(id: 'plan-a', proposal: _proposal());

/// Bench press two days ago, so the name field offers it.
TrainingHistoryEntry _benchLog() => buildLoggedWorkout(
  historyId: '0b6f2a9e-1c3d-4e5f-8a7b-6c5d4e3f2a1b',
  draft: LoggedWorkoutDraft(
    title: 'Push',
    performedOn: DateTime(2026, 10, 1),
    durationMinutes: 48,
    exercises: const [
      LoggedExercise(
        name: 'Bench press',
        timed: false,
        sets: [
          LoggedSet(reps: 8, weightKg: 80),
          LoggedSet(reps: 8, weightKg: 80),
          LoggedSet(reps: 6, weightKg: 75),
        ],
      ),
    ],
  ),
  now: _now,
  fallbackTitle: 'Workout',
);

TrainingHistoryEntry _planLog() => buildPlanAttachedLog(
  historyId: '5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a',
  plan: _plan(),
  workoutIndex: 1,
  sets: [
    [for (var s = 0; s < 4; s++) const PlanAttachedSet(done: true, reps: 6)],
  ],
  performedOn: DateTime(2026, 9, 30),
  durationMinutes: 52,
  now: _now,
);

/// The two geometries every surface is shot at: the design's phone, and a
/// 320 px phone with double text.
enum _Geometry {
  phone(Size(390, 844), 1, ''),
  narrow(Size(320, 690), 2, '-320-2x');

  const _Geometry(this.size, this.textScale, this.suffix);

  final Size size;
  final double textScale;
  final String suffix;
}

void _pinViewport(WidgetTester tester, _Geometry geometry) {
  if (geometry == _Geometry.phone) {
    pinDesignViewport(tester);
    return;
  }
  final view = tester.view;
  view.devicePixelRatio = kDesignPixelRatio;
  view.physicalSize = geometry.size * kDesignPixelRatio;
  final padding = FakeViewPadding(
    top: kDesignSafeArea.top * kDesignPixelRatio,
    bottom: kDesignSafeArea.bottom * kDesignPixelRatio,
  );
  view.padding = padding;
  view.viewPadding = padding;
  addTearDown(view.reset);
}

/// Pumps a launcher at [geometry] and opens a sheet or page from it.
Future<void> _host(
  WidgetTester tester,
  _Geometry geometry,
  void Function(BuildContext context) open,
) async {
  _pinViewport(tester, geometry);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
        locale: const Locale('en'),
        textScale: geometry.textScale,
        safeArea: false,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// Each keyed chip is a [FilterChipPill] at least 44 px tall whose semantics
/// report its selection.
void _expectChips(WidgetTester tester, Map<String, bool> chips) {
  for (final MapEntry(key: key, value: selected) in chips.entries) {
    final chip = _key(key);
    expect(tester.widget<FilterChipPill>(chip).selected, selected, reason: key);
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(44), reason: key);
    expect(
      tester.getSemantics(chip),
      isSemantics(isButton: true, isSelected: selected),
      reason: key,
    );
  }
}

/// Each keyed option (intent card, segment) reports its selection as a
/// button in a single-choice group, on a target of at least 44 px.
void _expectSelected(WidgetTester tester, Map<String, bool> options) {
  for (final MapEntry(key: key, value: selected) in options.entries) {
    final option = _key(key);
    expect(
      tester.getSemantics(option),
      isSemantics(
        isButton: true,
        isSelected: selected,
        isInMutuallyExclusiveGroup: true,
      ),
      reason: key,
    );
    expect(tester.getSize(option).height, greaterThanOrEqualTo(44));
  }
}

/// The brief's action sits fully on screen and takes taps where it is,
/// without scrolling.
void _expectActionPinned(WidgetTester tester) {
  final submit = _key('coach-brief-submit');
  final screen = Offset.zero & tester.view.physicalSize / kDesignPixelRatio;
  expect(screen.contains(tester.getRect(submit).topLeft), isTrue);
  expect(screen.contains(tester.getRect(submit).bottomRight), isTrue);
  expect(submit.hitTestable(), findsOneWidget);
  expect(
    find.descendant(of: _key('coach-brief-scroll'), matching: submit),
    findsNothing,
    reason: 'the action does not scroll with the form',
  );
}

void main() {
  setUpAll(loadDesignFonts);

  for (final geometry in _Geometry.values) {
    testWidgets('log editor: chips, pills and calendar${geometry.suffix}', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_now), () async {
        await _host(
          tester,
          geometry,
          (context) => showTrainingLogEditor(
            context,
            request: const FreeLogRequest(historyId: _logId),
            history: [_benchLog()],
            onSave: (_) async => TrainingLogSaveOutcome.saved,
          ),
        );
        await tester.tap(_key('training-log-day-yesterday'));
        await tester.pumpAndSettle();
        _expectChips(tester, {
          'training-log-day-today': false,
          'training-log-day-yesterday': true,
          'training-log-day-pick': false,
          'training-log-exercise-0-reps': true,
          'training-log-exercise-0-timed': false,
        });
        expect(tester.takeException(), isNull);
        await captureDesignShot(
          tester,
          'training-editors-log-00${geometry.suffix}',
        );

        // The exercise card: a suggestion pill, the type chips, "Add set".
        await _reveal(tester, _key('training-log-exercise-0-name'));
        await tester.enterText(_key('training-log-exercise-0-name'), 'Be');
        await tester.pumpAndSettle();
        final suggestion = _key('training-log-exercise-0-suggestion-0');
        expect(tester.widget<SoftPillButton>(suggestion).label, 'Bench press');
        expect(tester.getSize(suggestion).height, greaterThanOrEqualTo(44));
        await _reveal(tester, _key('training-log-exercise-0-add-set'));
        expect(
          tester.getSize(_key('training-log-exercise-0-add-set')).height,
          greaterThanOrEqualTo(44),
        );
        await _reveal(tester, suggestion);
        expect(tester.takeException(), isNull);
        await captureDesignShot(
          tester,
          'training-editors-log-01${geometry.suffix}',
        );

        // The calendar sheet: past days only, a training confirm label.
        await _reveal(tester, _key('training-log-day-pick'));
        await tester.tap(_key('training-log-day-pick'));
        await tester.pumpAndSettle();
        final picker = tester.widget<FoodDatePicker>(
          find.byType(FoodDatePicker),
        );
        expect(picker.lastDate, DateTime(2026, 10, 3));
        expect(picker.firstDate, DateTime(2026, 9, 3));
        expect(find.text('Use this day'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureDesignShot(
          tester,
          'training-editors-log-date${geometry.suffix}',
        );
      });
      handle.dispose();
    });

    testWidgets('coach brief: intent cards, plan row and choices'
        '${geometry.suffix}', (tester) async {
      final handle = tester.ensureSemantics();
      final active = ValueNotifier<bool>(true);
      addTearDown(active.dispose);
      await _host(
        tester,
        geometry,
        (context) => showCoachTrainingBrief(
          context,
          selectedPlan: _plan(),
          canSubmit: () => true,
          isActive: active,
        ),
      );
      final toggle = _key('coach-brief-plan-preview');
      expect(
        tester.getSemantics(toggle),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: false),
      );
      expect(find.text('Bench press'), findsNothing);
      // With a plan: two intent cards, "Discuss" chosen; the pinned action
      // says so and needs no scrolling.
      _expectSelected(tester, {
        'coach-brief-intent-adapt': false,
        'coach-brief-intent-discuss': true,
      });
      _expectActionPinned(tester);
      expect(
        tester.widget<PrimaryActionButton>(_key('coach-brief-submit')).label,
        'Discuss plan',
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(
        tester,
        'training-editors-brief-00${geometry.suffix}',
      );

      await _reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(toggle),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: true),
      );
      expect(find.text('Bench press'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(
        tester,
        'training-editors-brief-01${geometry.suffix}',
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      // "Adapt" relabels the action.
      await _reveal(tester, _key('coach-brief-intent-adapt'));
      await tester.tap(_key('coach-brief-intent-adapt'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PrimaryActionButton>(_key('coach-brief-submit')).label,
        'Draft changes',
      );

      // The plan's goal is a quick goal: its chip is chosen, no free field.
      _expectChips(tester, {
        'coach-brief-goal-general': false,
        'coach-brief-goal-strength': true,
        'coach-brief-goal-own': false,
      });
      expect(_key('coach-brief-goal'), findsNothing);
      await _reveal(tester, _key('coach-brief-equipment-dumbbells'));
      await tester.tap(_key('coach-brief-equipment-dumbbells'));
      await tester.pumpAndSettle();
      _expectSelected(tester, {
        'coach-brief-experience-beginner': true,
        'coach-brief-experience-intermediate': false,
        'coach-brief-experience-advanced': false,
        'coach-brief-equipment-bodyweight': false,
        'coach-brief-equipment-dumbbells': true,
        'coach-brief-equipment-gym': false,
      });
      await _reveal(tester, _key('coach-brief-goal-strength'));
      expect(tester.takeException(), isNull);
      await captureDesignShot(
        tester,
        'training-editors-brief-02${geometry.suffix}',
      );

      // The schedule steppers and the request field; the summary follows.
      for (final key in [
        'coach-brief-sessions-inc',
        'coach-brief-minutes-inc',
      ]) {
        await _reveal(tester, _key(key));
        await tester.tap(_key(key));
        await tester.pumpAndSettle();
      }
      await _reveal(tester, _key('coach-brief-wish'));
      String reading(String key) =>
          tester.widget<Text>(_key(key)).textSpan!.toPlainText();
      expect(reading('coach-brief-sessions-value'), '4×');
      expect(reading('coach-brief-minutes-value'), '45 min');
      if (geometry == _Geometry.phone) {
        expect(
          tester.widget<Text>(_key('coach-brief-summary')).data,
          '4× a week · 45 min · Dumbbells',
        );
      } else {
        // Large text: the bar keeps only the action and its cost.
        expect(_key('coach-brief-summary'), findsNothing);
      }
      expect(find.text('Uses 1 Coach request'), findsOneWidget);
      for (final key in [
        'coach-brief-sessions-dec',
        'coach-brief-sessions-inc',
        'coach-brief-minutes-dec',
        'coach-brief-minutes-inc',
      ]) {
        expect(tester.getSize(_key(key)).height, greaterThanOrEqualTo(44));
      }
      _expectActionPinned(tester);
      expect(tester.takeException(), isNull);
      await captureDesignShot(
        tester,
        'training-editors-brief-03${geometry.suffix}',
      );
      handle.dispose();
    });

    testWidgets('plan editor: review and exercise card${geometry.suffix}', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _host(
        tester,
        geometry,
        (context) => showTrainingPlanEditor(
          context,
          initialDraft: _proposal(),
          onSave: (_) async => SyncDelivery.delivered,
        ),
      );
      final edit = _key('training-editor-edit');
      expect(tester.widget<SoftPillButton>(edit).label, 'Edit');
      expect(tester.getSize(edit).height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
      await captureDesignShot(
        tester,
        'training-editors-plan-00${geometry.suffix}',
      );

      await _reveal(tester, edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      const prefix = 'training-editor-exercise-0-0';
      final toggle = _key('$prefix-toggle');
      // Brings the open card's head to the top of the sheet's scroll view.
      await _reveal(tester, toggle);
      expect(
        tester.getSemantics(toggle),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: true),
      );
      _expectChips(tester, {'$prefix-reps': true, '$prefix-time': false});
      expect(tester.takeException(), isNull);
      await captureDesignShot(
        tester,
        'training-editors-plan-01${geometry.suffix}',
      );

      // Folded: the fields leave, the head stays.
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(_key('$prefix-name'), findsNothing);
      expect(
        tester.getSemantics(toggle),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: false),
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(
        tester,
        'training-editors-plan-02${geometry.suffix}',
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(_key('$prefix-name'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('history rows${geometry.suffix}', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final log = _benchLog();
        final played = _planLog();
        await _host(
          tester,
          geometry,
          (context) => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => TrainingHistoryScreen(
                entries: [log, played],
                onDelete: (_) async => SyncDelivery.delivered,
              ),
            ),
          ),
        );
        for (final entry in [log, played]) {
          expect(
            tester.getSize(_key('training-history-${entry.id}')).height,
            greaterThanOrEqualTo(64),
          );
        }
        expect(tester.takeException(), isNull);
        await captureDesignShot(
          tester,
          'training-editors-history${geometry.suffix}',
        );
        await _reveal(tester, _key('training-history-${log.id}'));
        await tester.tap(_key('training-history-${log.id}'));
        await tester.pumpAndSettle();
        // The detail list builds lazily: scroll until Delete exists.
        await tester.scrollUntilVisible(
          _key('training-history-delete'),
          250,
          scrollable: find
              .descendant(
                of: find.byType(TrainingHistoryDetail),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<SoftPillButton>(_key('training-history-delete')).tone,
          SoftPillTone.danger,
        );
        expect(tester.takeException(), isNull);
        await captureDesignShot(
          tester,
          'training-editors-history-detail${geometry.suffix}',
        );
      });
    });
  }
}
