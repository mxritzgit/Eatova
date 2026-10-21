import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import 'support/harness.dart';

CoachTrainingProposal _draft({String title = 'Three strong days'}) =>
    CoachTrainingProposal(
      title: title,
      description: 'Strength and mobility, at your pace.',
      goal: 'Build consistency',
      workouts: [
        TrainingWorkout(
          title: 'Full body',
          description: 'Start gently.',
          exercises: [
            TrainingExercise(
              name: 'Squat',
              sets: 3,
              reps: 10,
              restSeconds: 60,
              notes: 'Move with control.',
            ),
            TrainingExercise(
              name: 'Plank',
              sets: 2,
              durationSeconds: 30,
              restSeconds: 45,
            ),
          ],
        ),
        TrainingWorkout(
          title: 'Mobility',
          exercises: [
            TrainingExercise(
              name: 'Shoulder circles',
              sets: 1,
              durationSeconds: 40,
              restSeconds: 0,
            ),
          ],
        ),
      ],
    );

TrainingPlan _plan({
  String id = 'manual-plan',
  String title = 'Three strong days',
}) => TrainingPlan(
  id: id,
  proposal: _draft(title: title),
);

TrainingScreen _screen({
  List<TrainingPlan> plans = const [],
  String? selectedPlanId,
  ValueChanged<String>? select,
  Future<SyncDelivery> Function(TrainingPlan)? create,
  Future<SyncDelivery> Function(TrainingPlan, CoachTrainingProposal)? update,
  Future<SyncDelivery> Function(String)? delete,
  void Function(TrainingPlan, int)? start,
  VoidCallback? coach,
  bool loading = false,
  bool loadFailed = false,
  VoidCallback? retry,
  bool hasActiveSession = false,
  VoidCallback? resume,
}) => TrainingScreen(
  plans: plans,
  selectedPlanId: selectedPlanId,
  onSelectPlan: select ?? (_) {},
  onCreatePlan: create ?? (_) async => SyncDelivery.delivered,
  onUpdatePlan: update ?? (_, _) async => SyncDelivery.delivered,
  onDeletePlan: delete ?? (_) async => SyncDelivery.delivered,
  onStartWorkout: start ?? (_, _) {},
  onOpenCoach: coach ?? () {},
  loading: loading,
  loadFailed: loadFailed,
  onRetry: retry,
  hasActiveSession: hasActiveSession,
  onResumeWorkout: resume,
);

Future<void> _openEditor(
  WidgetTester tester, {
  CoachTrainingProposal? initialDraft,
  required Future<SyncDelivery> Function(CoachTrainingProposal) save,
  ValueChanged<bool>? result,
  double scale = 1,
}) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        key: const ValueKey('open-editor'),
        onPressed: () async {
          final saved = await showTrainingPlanEditor(
            context,
            initialDraft: initialDraft,
            onSave: save,
          );
          result?.call(saved);
        },
        child: const Text('Open'),
      ),
    ),
    locale: const Locale('en'),
    surfaceSize: const Size(390, 844),
    textScale: scale,
  );
  await tester.tap(find.byKey(const ValueKey('open-editor')));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Picks workout [index] through Quick start's "Choose workout" menu.
Future<void> _chooseWorkout(WidgetTester tester, int index) async {
  await _tap(tester, 'training-quick-workouts');
  await tester.tap(find.byKey(ValueKey('training-workout-$index')));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

void main() {
  testWidgets('keyboard and large text keep validation and close reachable', (
    tester,
  ) async {
    await _openEditor(
      tester,
      initialDraft: _draft(),
      scale: 2,
      save: (_) async => SyncDelivery.delivered,
    );
    await _tap(tester, 'training-editor-edit');
    await _enter(tester, 'training-editor-title', '');
    tester.view.viewInsets = FakeViewPadding(
      bottom: 350 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await _tap(tester, 'training-editor-save');
    expect(tester.takeException(), isNull);
    expect(find.text('Check the highlighted fields.'), findsOneWidget);
    await _tap(tester, 'training-editor-close');
    expect(
      find.byKey(const ValueKey('training-discard-dialog')),
      findsOneWidget,
    );
  });

  testWidgets('empty library opens Coach without creating user data', (
    tester,
  ) async {
    var opened = 0;
    var writes = 0;
    await pumpLocalized(
      tester,
      _screen(
        coach: () => opened++,
        create: (_) async {
          writes++;
          return SyncDelivery.delivered;
        },
      ),
      locale: const Locale('en'),
      surfaceSize: const Size(390, 844),
    );
    await _tap(tester, 'training-empty-coach');
    expect(opened, 1);
    expect(writes, 0);
  });

  testWidgets('loading, error and retry never pretend collection is empty', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      _screen(loading: true),
      locale: const Locale('en'),
    );
    // The next-workout card in outline, never the empty state.
    expect(find.byKey(const ValueKey('training-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('training-empty-coach')), findsNothing);
    var retries = 0;
    await pumpLocalized(
      tester,
      _screen(loadFailed: true, retry: () => retries++),
      locale: const Locale('en'),
    );
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
    expect(find.byKey(const ValueKey('training-empty-coach')), findsNothing);
  });

  testWidgets('editing a plan keeps the selected workout after reordering', (
    tester,
  ) async {
    final initial = TrainingPlan(
      id: 'selection-plan',
      proposal: CoachTrainingProposal(
        title: 'Three workouts',
        workouts: [
          for (final name in ['A', 'B', 'C'])
            TrainingWorkout(
              title: '$name workout',
              exercises: [
                TrainingExercise(
                  name: '$name move',
                  sets: 1,
                  reps: 8,
                  restSeconds: 0,
                ),
              ],
            ),
        ],
      ),
    );
    var current = initial;
    void Function(VoidCallback)? update;
    TrainingPlan? started;
    int? startedIndex;
    await pumpLocalized(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return _screen(
            plans: [current],
            start: (plan, index) {
              started = plan;
              startedIndex = index;
            },
          );
        },
      ),
      locale: const Locale('en'),
      surfaceSize: const Size(390, 844),
    );
    await _chooseWorkout(tester, 1);
    expect(find.text('B move'), findsOneWidget);
    update!(() => current = initial.copyWith());
    await tester.pumpAndSettle();
    expect(find.text('B move'), findsOneWidget);
    update!(() {
      current = initial.copyWith(
        proposal: initial.proposal.copyWith(
          workouts: initial.workouts.skip(1).toList(),
        ),
      );
    });
    await tester.pumpAndSettle();
    expect(find.text('B move'), findsOneWidget);
    expect(find.text('C move'), findsNothing);
    await _tap(tester, 'training-start');
    expect(started, same(current));
    expect(startedIndex, 0);
    update!(() {
      current = current.copyWith(
        proposal: current.proposal.copyWith(workouts: [current.workouts.last]),
      );
    });
    await tester.pumpAndSettle();
    expect(find.text('C move'), findsOneWidget);
    await _tap(tester, 'training-start');
    expect(started, same(current));
    expect(startedIndex, 0);
  });

  testWidgets(
    'delete requires confirmation and reports failure without losing plan',
    (tester) async {
      var deletes = 0;
      await pumpLocalized(
        tester,
        _screen(
          plans: [_plan()],
          delete: (_) async {
            deletes++;
            throw StateError('private database diagnostic');
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
      );
      await _tap(tester, 'training-plan-menu');
      await tester.tap(find.text('Delete plan'));
      await tester.pumpAndSettle();
      expect(deletes, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deletes, 0);
      await _tap(tester, 'training-plan-menu');
      await tester.tap(find.text('Delete plan'));
      await tester.pumpAndSettle();
      await _tap(tester, 'training-delete-confirm');
      expect(deletes, 1);
      expect(find.text('Three strong days'), findsOneWidget);
      expect(find.textContaining('private database'), findsNothing);
    },
  );

  testWidgets('draft review is readable and closing never writes', (
    tester,
  ) async {
    var writes = 0;
    bool? saved;
    await _openEditor(
      tester,
      initialDraft: _draft(),
      save: (_) async {
        writes++;
        return SyncDelivery.delivered;
      },
      result: (value) => saved = value,
    );
    expect(find.text('Full body'), findsOneWidget);
    expect(find.text('Mobility'), findsOneWidget);
    expect(find.text('3 × 10 reps'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(writes, 0);
    await _tap(tester, 'training-editor-close');
    expect(saved, false);
    expect(writes, 0);
  });

  testWidgets(
    'explicit save is single-flight, retains draft on failure, retries',
    (tester) async {
      final first = Completer<SyncDelivery>();
      var writes = 0;
      bool? saved;
      await _openEditor(
        tester,
        initialDraft: _draft(),
        save: (_) {
          writes++;
          return writes == 1
              ? first.future
              : Future.value(SyncDelivery.queuedOffline);
        },
        result: (value) => saved = value,
      );
      await tester.tap(find.byKey(const ValueKey('training-editor-save')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('training-editor-save')));
      await tester.pump();
      expect(writes, 1);
      expect(find.text('Saving …'), findsOneWidget);
      first.completeError(StateError('private credentials'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.textContaining('Your draft is still here'), findsOneWidget);
      expect(find.textContaining('private credentials'), findsNothing);
      await _tap(tester, 'training-editor-save');
      expect(writes, 2);
      expect(saved, true);
    },
  );

  testWidgets(
    'edit preserves all draft fields and changes timed prescription',
    (tester) async {
      CoachTrainingProposal? saved;
      await _openEditor(
        tester,
        initialDraft: _draft(),
        save: (draft) async {
          saved = draft;
          return SyncDelivery.delivered;
        },
      );
      await _tap(tester, 'training-editor-edit');
      await _enter(tester, 'training-editor-title', 'My revised plan');
      await _tap(tester, 'training-editor-exercise-0-0-time');
      await _enter(tester, 'training-editor-exercise-0-0-duration', '50');
      await _enter(tester, 'training-editor-exercise-0-0-rest', '20');
      await _tap(tester, 'training-editor-save');
      expect(saved!.title, 'My revised plan');
      expect(saved!.goal, 'Build consistency');
      expect(saved!.workouts.length, 2);
      expect(saved!.workouts.first.exercises.first.reps, isNull);
      expect(saved!.workouts.first.exercises.first.durationSeconds, 50);
      expect(saved!.workouts.first.exercises.first.restSeconds, 20);
      expect(saved!.workouts.first.exercises.first.notes, 'Move with control.');
    },
  );

  testWidgets('raw invalid fields cannot be persisted and remain editable', (
    tester,
  ) async {
    var writes = 0;
    await _openEditor(
      tester,
      initialDraft: _draft(),
      save: (_) async {
        writes++;
        return SyncDelivery.delivered;
      },
    );
    await _tap(tester, 'training-editor-edit');
    await _enter(tester, 'training-editor-exercise-0-0-repetitions', '101');
    await _tap(tester, 'training-editor-save');
    expect(writes, 0);
    expect(find.text('Enter 1–100.'), findsOneWidget);
    await _enter(tester, 'training-editor-exercise-0-0-repetitions', '12');
    await _enter(tester, 'training-editor-exercise-0-0-rest', '601');
    await _tap(tester, 'training-editor-save');
    expect(writes, 0);
    expect(find.text('Enter 0–600.'), findsOneWidget);
    await _enter(tester, 'training-editor-exercise-0-0-rest', '0');
    await _tap(tester, 'training-editor-save');
    expect(writes, 1);
  });

  testWidgets('add, remove and reorder preserve the edited exercise values', (
    tester,
  ) async {
    CoachTrainingProposal? saved;
    await _openEditor(
      tester,
      initialDraft: _draft(),
      save: (draft) async {
        saved = draft;
        return SyncDelivery.delivered;
      },
    );
    await _tap(tester, 'training-editor-edit');
    await _enter(tester, 'training-editor-exercise-0-0-name', 'Edited squat');
    // Order and removal live in each card's ⋯ menu; the first has no "up".
    await _tap(tester, 'training-editor-exercise-0-0-menu');
    expect(
      find.byKey(const ValueKey('training-editor-exercise-0-0-up')),
      findsNothing,
    );
    await _tap(tester, 'training-editor-exercise-0-0-down');
    await _tap(tester, 'training-editor-add-exercise-0');
    await _enter(tester, 'training-editor-exercise-0-2-name', 'Lunge');
    await _tap(tester, 'training-editor-exercise-0-0-menu');
    await _tap(tester, 'training-editor-exercise-0-0-remove');
    await _tap(tester, 'training-editor-workout-1-menu');
    await _tap(tester, 'training-editor-workout-1-up');
    await _tap(tester, 'training-editor-save');
    expect(saved!.workouts.first.title, 'Mobility');
    expect(saved!.workouts.last.exercises.map((e) => e.name), [
      'Edited squat',
      'Lunge',
    ]);
    expect(saved!.workouts.last.exercises.first.notes, 'Move with control.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('dirty close keeps changes until explicit discard', (
    tester,
  ) async {
    bool? saved;
    await _openEditor(
      tester,
      save: (_) async => SyncDelivery.delivered,
      result: (value) => saved = value,
    );
    await _enter(tester, 'training-editor-title', 'Unfinished');
    await _tap(tester, 'training-editor-close');
    expect(
      find.byKey(const ValueKey('training-discard-dialog')),
      findsOneWidget,
    );
    expect(saved, isNull);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Unfinished'), findsOneWidget);
    await _tap(tester, 'training-editor-close');
    await _tap(tester, 'training-discard-confirm');
    expect(saved, false);
  });

  testWidgets('manual save retries reuse the same plan ID', (tester) async {
    final ids = <String>[];
    await pumpLocalized(
      tester,
      _screen(
        create: (plan) async {
          ids.add(plan.id);
          if (ids.length == 1) throw StateError('retry');
          return SyncDelivery.delivered;
        },
      ),
      locale: const Locale('en'),
      surfaceSize: const Size(390, 844),
    );
    await _tap(tester, 'training-create');
    await _enter(tester, 'training-editor-title', 'My new plan');
    await _enter(tester, 'training-editor-workout-0-title', 'Day one');
    await _enter(tester, 'training-editor-exercise-0-0-name', 'Squat');
    await _tap(tester, 'training-editor-save');
    await _tap(tester, 'training-editor-save');
    expect(ids.length, 2);
    expect(ids.first, ids.last);
  });

  // Brightness changes no layout; English at 2x is covered by "large text
  // keeps library and start reachable" below.
  testWidgets('German quick start reflows at 320 and double text', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      _screen(plans: [_plan()]),
      locale: const Locale('de'),
      textScale: 2,
      surfaceSize: const Size(320, 844),
    );
    await tester.pumpAndSettle();
    await _chooseWorkout(tester, 1);
    await _tap(tester, 'training-start');
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor review and fields reflow at double text', (tester) async {
    await _openEditor(
      tester,
      initialDraft: _draft(),
      scale: 2,
      save: (_) async => SyncDelivery.delivered,
    );
    expect(tester.takeException(), isNull);
    await _tap(tester, 'training-editor-edit');
    await _tap(tester, 'training-editor-exercise-0-0-time');
    await _enter(tester, 'training-editor-exercise-0-0-duration', '5');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'training-editor-save');
    expect(tester.takeException(), isNull);
  });

  // TrainingScreen with the plan library, Quick start and the app shell.
  group('library and quick start', () {
    TrainingPlan libraryPlan(
      String id, {
      String? title,
      String first = 'Upper body',
      String second = 'Mobility',
    }) => CoachTrainingProposal(
      title: title ?? id,
      description: 'A complete description of this training plan.',
      goal: 'Build strength',
      workouts: [
        TrainingWorkout(
          title: first,
          exercises: List.generate(
            6,
            (i) => TrainingExercise(
              name: 'Exercise ${i + 1}',
              sets: 3,
              reps: 10,
              restSeconds: 45,
              notes: 'Technique note ${i + 1}',
            ),
          ),
        ),
        TrainingWorkout(
          title: second,
          exercises: [
            TrainingExercise(
              name: 'Timed movement',
              sets: 2,
              durationSeconds: 30,
              restSeconds: 0,
            ),
          ],
        ),
      ],
    ).toTrainingPlan(id: id);

    TrainingScreen libraryScreen({
      required List<TrainingPlan> plans,
      String? selected,
      ValueChanged<String>? onSelect,
      void Function(TrainingPlan, int)? onStart,
      VoidCallback? coach,
      Future<SyncDelivery> Function(TrainingPlan)? create,
    }) => TrainingScreen(
      plans: plans,
      selectedPlanId: selected,
      onSelectPlan: onSelect ?? (_) {},
      onCreatePlan: create ?? (_) async => SyncDelivery.delivered,
      onUpdatePlan: (_, _) async => SyncDelivery.delivered,
      onDeletePlan: (_) async => SyncDelivery.delivered,
      onStartWorkout: onStart ?? (_, _) {},
      onOpenCoach: coach ?? () {},
      onOpenHistory: () {},
    );

    Future<void> tapRevealed(WidgetTester tester, String key) async {
      final finder = find.byKey(ValueKey(key));
      if (finder.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          finder,
          180,
          scrollable: find.byType(Scrollable).last,
        );
      }
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    /// Picks workout [index] through Quick start's "Choose workout" menu.
    Future<void> chooseLibraryWorkout(WidgetTester tester, int index) async {
      await tapRevealed(tester, 'training-quick-workouts');
      await tester.tap(find.byKey(ValueKey('training-workout-$index')));
      await tester.pumpAndSettle();
    }

    testWidgets('screen readers can select a workout by its full title; '
        'Start starts that workout', (tester) async {
      final semantics = tester.ensureSemantics();
      final plan = libraryPlan('strength');
      final started = <(TrainingPlan, int)>[];
      try {
        await pumpLocalized(
          tester,
          libraryScreen(
            plans: [plan],
            onStart: (plan, index) => started.add((plan, index)),
          ),
          locale: const Locale('en'),
          surfaceSize: const Size(393, 852),
          settle: true,
        );
        // The chooser is a labelled button that opens the workout menu.
        final chooser = find.byKey(const ValueKey('training-quick-workouts'));
        await tester.ensureVisible(chooser);
        await tester.pumpAndSettle();
        tester.semantics.performAction(
          find.semantics.byLabel('Choose workout'),
          SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        final tab = find.bySemanticsLabel('Workout 2: Mobility');
        expect(tab, findsOneWidget);
        final node = tester.getSemantics(tab);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        expect(
          tester.getSemantics(find.bySemanticsLabel('Workout 1: Upper body')),
          isSemantics(isSelected: true),
        );
        tester.semantics.performAction(
          find.semantics.byLabel('Workout 2: Mobility'),
          SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        expect(find.text('Timed movement'), findsOneWidget);
        expect(find.text('Exercise 1'), findsNothing);
        await tapRevealed(tester, 'training-start');
        expect(started, hasLength(1));
        expect(started.single.$1, same(plan));
        expect(started.single.$2, 1);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets(
      'all exercises and prescribed notes are reachable without starting a session',
      (tester) async {
        var starts = 0;
        await pumpLocalized(
          tester,
          libraryScreen(
            plans: [libraryPlan('strength')],
            onStart: (_, _) => starts++,
          ),
          locale: const Locale('en'),
          surfaceSize: const Size(393, 852),
          settle: true,
        );
        expect(find.text('Exercise 4'), findsNothing);
        await tapRevealed(tester, 'training-exercise-0');
        expect(find.text('Technique note 1'), findsOneWidget);
        expect(find.text('45s rest'), findsOneWidget);
        await tapRevealed(tester, 'training-all-exercises');
        expect(find.text('Exercise 6'), findsOneWidget);
        await chooseLibraryWorkout(tester, 1);
        expect(find.text('Timed movement'), findsOneWidget);
        expect(find.text('Technique note 1'), findsNothing);
        expect(starts, 0);
      },
    );

    testWidgets('removing an implicit selected plan resets its workout index', (
      tester,
    ) async {
      final a = libraryPlan('a');
      final b = libraryPlan(
        'b',
        first: 'New first workout',
        second: 'New second workout',
      );
      void Function(VoidCallback)? update;
      var plans = [a, b];
      int? startedIndex;
      TrainingPlan? startedPlan;
      await pumpLocalized(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return libraryScreen(
              plans: plans,
              onStart: (plan, index) {
                startedPlan = plan;
                startedIndex = index;
              },
            );
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        settle: true,
      );
      await chooseLibraryWorkout(tester, 1);
      update!(() => plans = [b]);
      await tester.pumpAndSettle();
      expect(find.text('New first workout'), findsOneWidget);
      await tapRevealed(tester, 'training-start');
      expect(startedPlan, same(b));
      expect(startedIndex, 0);
    });

    testWidgets(
      'library search matches workout titles and description expands without selecting',
      (tester) async {
        final a = libraryPlan('strength', title: 'Strength');
        final b = libraryPlan(
          'balance',
          title: 'Balance',
          second: 'Stretching',
        );
        final selections = <String>[];
        await pumpLocalized(
          tester,
          libraryScreen(
            plans: [a, b],
            selected: a.id,
            onSelect: selections.add,
          ),
          locale: const Locale('en'),
          surfaceSize: const Size(393, 852),
          settle: true,
        );
        await tapRevealed(tester, 'training-open-plans');
        await tapRevealed(tester, 'training-plan-description-strength');
        expect(find.text(a.description), findsOneWidget);
        expect(selections, isEmpty);
        await tester.enterText(find.byType(TextField), 'stretching');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('training-select-strength')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('training-select-balance')),
          findsOneWidget,
        );
        await tapRevealed(tester, 'training-select-balance');
        expect(selections, ['balance']);
      },
    );

    testWidgets(
      'a removed plan cannot be selected from an already open library',
      (tester) async {
        final a = libraryPlan('a');
        final b = libraryPlan('b');
        var plans = [a, b];
        final selections = <String>[];
        void Function(VoidCallback)? update;
        await pumpLocalized(
          tester,
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return libraryScreen(plans: plans, onSelect: selections.add);
            },
          ),
          locale: const Locale('en'),
          surfaceSize: const Size(393, 852),
          settle: true,
        );
        await tapRevealed(tester, 'training-open-plans');
        update!(() => plans = [a]);
        await tester.pumpAndSettle();
        await tapRevealed(tester, 'training-select-b');
        expect(selections, isEmpty);
      },
    );

    testWidgets(
      'no-result library still offers Coach without adopting a plan',
      (tester) async {
        var coach = 0;
        var writes = 0;
        await pumpLocalized(
          tester,
          libraryScreen(
            plans: [libraryPlan('a')],
            coach: () => coach++,
            create: (_) async {
              writes++;
              return SyncDelivery.delivered;
            },
          ),
          locale: const Locale('en'),
          surfaceSize: const Size(393, 852),
          settle: true,
        );
        await tapRevealed(tester, 'training-open-plans');
        await tester.enterText(find.byType(TextField), 'not found');
        await tester.pumpAndSettle();
        expect(
          find.text('No matching plan. Try another search term.'),
          findsOneWidget,
        );
        await tapRevealed(tester, 'training-library-coach');
        expect(coach, 1);
        expect(writes, 0);
      },
    );

    testWidgets('create from the library opens a draft without writing', (
      tester,
    ) async {
      var writes = 0;
      await pumpLocalized(
        tester,
        libraryScreen(
          plans: [libraryPlan('a')],
          create: (_) async {
            writes++;
            return SyncDelivery.delivered;
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        settle: true,
      );
      await tapRevealed(tester, 'training-open-plans');
      await tapRevealed(tester, 'training-library-create');
      expect(
        find.byKey(const ValueKey('training-editor-title')),
        findsOneWidget,
      );
      expect(writes, 0);
    });

    for (final size in [const Size(320, 568), const Size(844, 390)]) {
      testWidgets('large text keeps library and start reachable at $size', (
        tester,
      ) async {
        var starts = 0;
        await pumpLocalized(
          tester,
          libraryScreen(
            plans: [libraryPlan('strength')],
            onStart: (_, _) => starts++,
          ),
          locale: const Locale('en'),
          surfaceSize: size,
          textScale: 2,
          settle: true,
        );
        await tapRevealed(tester, 'training-start');
        expect(starts, 1);
        await tapRevealed(tester, 'training-open-plans');
        await tester.enterText(find.byType(TextField), 'not found');
        tester.view.viewInsets = FakeViewPadding(
          bottom: 180 * tester.view.devicePixelRatio,
        );
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await tapRevealed(tester, 'training-library-close');
        expect(
          find.byKey(const ValueKey('training-plan-search')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'Training follows the app theme and shows Start in the first viewport',
      (tester) async {
        // The forced dark studio theme is gone (the app is dark now): a light
        // app theme reaches the tab unchanged, so a later switch back to light
        // needs no Training-specific code.
        await pumpLocalized(
          tester,
          libraryScreen(plans: [libraryPlan('a')]),
          brightness: Brightness.light,
          locale: const Locale('en'),
          surfaceSize: const Size(393, 852),
          settle: true,
        );
        final start = find.byKey(const ValueKey('training-start'));
        expect(start.hitTestable(), findsOneWidget);
        expect(AppTokens.of(tester.element(start)).bg, AppTokens.light.bg);
        // Start sits in the workout card, not pinned below the list: the page
        // scrolls as one down to the tab's bottom edge.
        final scroll = tester.getRect(
          find.byKey(const PageStorageKey('training-scroll')),
        );
        final page = tester.getRect(find.byType(TrainingScreen));
        expect(scroll.bottom, page.bottom);
        expect(tester.getRect(start).bottom, lessThan(page.bottom));
      },
    );

    testWidgets('hidden and covered studio pages yield the toast host', (
      tester,
    ) async {
      var visible = true;
      late StateSetter update;
      late BuildContext rootContext;
      await pumpLocalized(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            rootContext = context;
            update = setState;
            return Offstage(
              offstage: !visible,
              child: TickerMode(
                enabled: visible,
                child: libraryScreen(plans: [libraryPlan('a')]),
              ),
            );
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        settle: true,
      );
      expect(SnackHost.hasLiveHost, isTrue);
      update(() => visible = false);
      await tester.pumpAndSettle();
      expect(SnackHost.hasLiveHost, isFalse);
      update(() => visible = true);
      await tester.pumpAndSettle();
      Navigator.of(rootContext).push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Details')),
        ),
      );
      await tester.pumpAndSettle();
      expect(SnackHost.hasLiveHost, isFalse);
      Navigator.of(rootContext).pop();
      await tester.pumpAndSettle();
      expect(SnackHost.hasLiveHost, isTrue);
    });
  });
}
