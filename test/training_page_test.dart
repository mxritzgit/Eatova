import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

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
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
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

  testWidgets(
    'selected workout drives exercise list and actual start callback',
    (tester) async {
      final plan = _plan();
      TrainingPlan? started;
      int? index;
      await pumpLocalized(
        tester,
        _screen(
          plans: [plan],
          start: (p, i) {
            started = p;
            index = i;
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 844),
      );
      await _tap(tester, 'training-workout-1');
      expect(find.text('Shoulder circles'), findsOneWidget);
      expect(find.text('Squat'), findsNothing);
      await _tap(tester, 'training-start');
      expect(started, same(plan));
      expect(index, 1);
    },
  );

  testWidgets('saved plan picker calls account-owned selection', (
    tester,
  ) async {
    String? selected;
    await pumpLocalized(
      tester,
      _screen(
        plans: [
          _plan(),
          _plan(id: 'second', title: 'Second plan'),
        ],
        select: (id) => selected = id,
      ),
      locale: const Locale('en'),
      surfaceSize: const Size(390, 844),
    );
    await _tap(tester, 'training-switch-plan');
    await _tap(tester, 'training-select-second');
    expect(selected, 'second');
  });

  testWidgets(
    'active session exposes resume and does not start a second workout',
    (tester) async {
      var resumed = 0;
      await pumpLocalized(
        tester,
        _screen(
          plans: [_plan()],
          hasActiveSession: true,
          resume: () => resumed++,
        ),
        locale: const Locale('en'),
      );
      expect(find.byKey(const ValueKey('training-start')), findsNothing);
      await _tap(tester, 'training-resume');
      expect(resumed, 1);
    },
  );

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
    await _tap(tester, 'training-editor-exercise-0-0-down');
    await _tap(tester, 'training-editor-add-exercise-0');
    await _enter(tester, 'training-editor-exercise-0-2-name', 'Lunge');
    await _tap(tester, 'training-editor-exercise-0-0-remove');
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

  for (final locale in ['de', 'en']) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        'library $locale $brightness reflows at 320 and double text',
        (tester) async {
          await pumpLocalized(
            tester,
            _screen(plans: [_plan()]),
            locale: Locale(locale),
            brightness: brightness,
            textScale: 2,
            surfaceSize: const Size(320, 844),
          );
          await tester.pumpAndSettle();
          await _tap(tester, 'training-workout-1');
          await _tap(tester, 'training-start');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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
}
