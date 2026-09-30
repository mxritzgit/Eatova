import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

TrainingPlan _plan(
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

TrainingScreen _screen({
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

Future<void> _tap(WidgetTester tester, String key) async {
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
Future<void> _chooseWorkout(WidgetTester tester, int index) async {
  await _tap(tester, 'training-quick-workouts');
  await tester.tap(find.byKey(ValueKey('training-workout-$index')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('screen readers can select a workout by its full title', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpLocalized(
        tester,
        _screen(plans: [_plan('strength')]),
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
        _screen(plans: [_plan('strength')], onStart: (_, _) => starts++),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        settle: true,
      );
      expect(find.text('Exercise 4'), findsNothing);
      await _tap(tester, 'training-exercise-0');
      expect(find.text('Technique note 1'), findsOneWidget);
      expect(find.text('45s rest'), findsOneWidget);
      await _tap(tester, 'training-all-exercises');
      expect(find.text('Exercise 6'), findsOneWidget);
      await _chooseWorkout(tester, 1);
      expect(find.text('Timed movement'), findsOneWidget);
      expect(find.text('Technique note 1'), findsNothing);
      expect(starts, 0);
    },
  );

  testWidgets('removing an implicit selected plan resets its workout index', (
    tester,
  ) async {
    final a = _plan('a');
    final b = _plan(
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
          return _screen(
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
    await _chooseWorkout(tester, 1);
    update!(() => plans = [b]);
    await tester.pumpAndSettle();
    expect(find.text('New first workout'), findsOneWidget);
    await _tap(tester, 'training-start');
    expect(startedPlan, same(b));
    expect(startedIndex, 0);
  });

  testWidgets(
    'library search matches workout titles and description expands without selecting',
    (tester) async {
      final a = _plan('strength', title: 'Strength');
      final b = _plan('balance', title: 'Balance', second: 'Stretching');
      final selections = <String>[];
      await pumpLocalized(
        tester,
        _screen(plans: [a, b], selected: a.id, onSelect: selections.add),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        settle: true,
      );
      await _tap(tester, 'training-open-plans');
      await _tap(tester, 'training-plan-description-strength');
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
      await _tap(tester, 'training-select-balance');
      expect(selections, ['balance']);
    },
  );

  testWidgets(
    'a removed plan cannot be selected from an already open library',
    (tester) async {
      final a = _plan('a');
      final b = _plan('b');
      var plans = [a, b];
      final selections = <String>[];
      void Function(VoidCallback)? update;
      await pumpLocalized(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _screen(plans: plans, onSelect: selections.add);
          },
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        settle: true,
      );
      await _tap(tester, 'training-open-plans');
      update!(() => plans = [a]);
      await tester.pumpAndSettle();
      await _tap(tester, 'training-select-b');
      expect(selections, isEmpty);
    },
  );

  testWidgets('no-result library still offers Coach without adopting a plan', (
    tester,
  ) async {
    var coach = 0;
    var writes = 0;
    await pumpLocalized(
      tester,
      _screen(
        plans: [_plan('a')],
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
    await _tap(tester, 'training-open-plans');
    await tester.enterText(find.byType(TextField), 'not found');
    await tester.pumpAndSettle();
    expect(
      find.text('No matching plan. Try another search term.'),
      findsOneWidget,
    );
    await _tap(tester, 'training-library-coach');
    expect(coach, 1);
    expect(writes, 0);
  });

  testWidgets('create from the library opens a draft without writing', (
    tester,
  ) async {
    var writes = 0;
    await pumpLocalized(
      tester,
      _screen(
        plans: [_plan('a')],
        create: (_) async {
          writes++;
          return SyncDelivery.delivered;
        },
      ),
      locale: const Locale('en'),
      surfaceSize: const Size(393, 852),
      settle: true,
    );
    await _tap(tester, 'training-open-plans');
    await _tap(tester, 'training-library-create');
    expect(find.byKey(const ValueKey('training-editor-title')), findsOneWidget);
    expect(writes, 0);
  });

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('large text keeps library and start reachable at $size', (
      tester,
    ) async {
      var starts = 0;
      await pumpLocalized(
        tester,
        _screen(plans: [_plan('strength')], onStart: (_, _) => starts++),
        locale: const Locale('en'),
        surfaceSize: size,
        textScale: 2,
        settle: true,
      );
      await _tap(tester, 'training-start');
      expect(starts, 1);
      await _tap(tester, 'training-open-plans');
      await tester.enterText(find.byType(TextField), 'not found');
      tester.view.viewInsets = FakeViewPadding(
        bottom: 180 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await _tap(tester, 'training-library-close');
      expect(find.byKey(const ValueKey('training-plan-search')), findsNothing);
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
        _screen(plans: [_plan('a')]),
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
              child: _screen(plans: [_plan('a')]),
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
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Details'))),
    );
    await tester.pumpAndSettle();
    expect(SnackHost.hasLiveHost, isFalse);
    Navigator.of(rootContext).pop();
    await tester.pumpAndSettle();
    expect(SnackHost.hasLiveHost, isTrue);
  });
}
