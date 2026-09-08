import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/training/training_exercise_list.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import 'support/harness.dart';

CoachTrainingProposal _draft() => CoachTrainingProposal(
  title: 'Stark im Alltag',
  description: 'Kraft und Beweglichkeit. Zwei Einheiten für deinen Alltag.',
  goal: 'Eine Routine aufbauen',
  workouts: [
    TrainingWorkout(
      title: 'Ganzkörper',
      exercises: [
        TrainingExercise(
          name: 'Kniebeugen',
          sets: 3,
          reps: 10,
          restSeconds: 60,
        ),
        TrainingExercise(
          name: 'Unterarmstütz',
          sets: 2,
          durationSeconds: 30,
          restSeconds: 45,
        ),
      ],
    ),
    TrainingWorkout(
      title: 'Mobilität',
      exercises: [
        TrainingExercise(
          name: 'Schulterkreisen',
          sets: 1,
          durationSeconds: 40,
          restSeconds: 0,
        ),
      ],
    ),
  ],
);

Future<void> _fonts() async {
  for (final family in ['Archivo', 'BricolageGrotesque']) {
    final loader = FontLoader(family);
    for (final weight
        in family == 'Archivo'
            ? ['Regular', 'Medium', 'SemiBold', 'Bold']
            : ['Bold', 'ExtraBold']) {
      loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
    }
    await loader.load();
  }
}

Future<void> _editor(
  WidgetTester tester, {
  Size size = const Size(320, 568),
}) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showTrainingPlanEditor(
          context,
          initialDraft: _draft(),
          onSave: (_) async => SyncDelivery.delivered,
        ),
        child: const Text('Open'),
      ),
    ),
    textScale: 2,
    surfaceSize: size,
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _edit(WidgetTester tester) async {
  final edit = find.byKey(const ValueKey('training-editor-edit'));
  await tester.ensureVisible(edit);
  await tester.pumpAndSettle();
  await tester.tap(edit);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  testWidgets('actual fonts keep Training on one line at 320 and 2x', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      TrainingScreen(
        plans: [_draft().toTrainingPlan(id: 'geometry')],
        onCreatePlan: (_) async => SyncDelivery.delivered,
        onUpdatePlan: (_, _) async => SyncDelivery.delivered,
        onDeletePlan: (_) async => SyncDelivery.delivered,
        onSelectPlan: (_) {},
        onStartWorkout: (_, _) {},
        onOpenCoach: () {},
      ),
      textScale: 2,
      surfaceSize: const Size(320, 568),
    );
    final title = tester.renderObject<RenderParagraph>(find.text('Training'));
    expect(
      title.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 8),
      ),
      hasLength(1),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('training-create'))).dy,
      greaterThan(tester.getBottomLeft(find.text('Training')).dy),
    );
    final workout = find.byKey(const ValueKey('training-workout-0'));
    await tester.scrollUntilVisible(workout, 200);
    expect(
      tester.widget<ChoiceChip>(workout).checkmarkColor,
      AppTokens.dark.onLime,
    );
  });

  testWidgets(
    'actual fonts keep exercise ordinals unbroken and within their column',
    (tester) async {
      await pumpLocalized(
        tester,
        TrainingExerciseList(exercises: _draft().workouts.first.exercises),
        textScale: 2,
        surfaceSize: const Size(320, 568),
      );
      for (final number in ['1', '2']) {
        final finder = find.text(number);
        final paragraph = tester.renderObject<RenderParagraph>(finder);
        final boxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        );
        expect(boxes, hasLength(1));
        expect(boxes.single.right, lessThanOrEqualTo(paragraph.size.width));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching a scrolled review to editing reveals the plan name first',
    (tester) async {
      await _editor(tester);
      await _edit(tester);
      final field = find.byKey(const ValueKey('training-editor-title'));
      final viewport = tester.getRect(
        find.byKey(const ValueKey('training-editor-scroll')),
      );
      expect(
        tester.getRect(field).intersect(viewport).height,
        greaterThanOrEqualTo(48),
      );
      final heading = tester.renderObject<RenderParagraph>(
        find.text('Plan bearbeiten'),
      );
      expect(
        heading.getBoxesForSelection(
          const TextSelection(baseOffset: 5, extentOffset: 15),
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focused title stays visible above Save with the keyboard and actual fonts',
    (tester) async {
      await _editor(tester);
      await _edit(tester);
      final field = find.byKey(const ValueKey('training-editor-title'));
      await tester.tap(field);
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(
        bottom: 220 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final viewport = tester.getRect(
        find.byKey(const ValueKey('training-editor-scroll')),
      );
      final save = tester.getRect(
        find.byKey(const ValueKey('training-editor-save')),
      );
      final editable = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      final text = tester.getRect(editable);
      expect(
        tester.getRect(field).intersect(viewport).height,
        greaterThanOrEqualTo(48),
      );
      expect(text.top, greaterThanOrEqualTo(viewport.top));
      expect(text.bottom, lessThanOrEqualTo(save.top));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected exercise chips use readable checks on lime in dark mode',
    (tester) async {
      await _editor(tester, size: const Size(390, 844));
      await _edit(tester);
      final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
      expect(chips, isNotEmpty);
      for (final chip in chips.where((chip) => chip.selected)) {
        expect(chip.checkmarkColor, AppTokens.dark.onLime);
      }
    },
  );
}
