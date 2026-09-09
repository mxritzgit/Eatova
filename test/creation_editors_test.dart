import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

void main() {
  setUpAll(() async {
    for (final family in ['Archivo', 'BricolageGrotesque']) {
      final fonts = FontLoader(family);
      for (final weight
          in family == 'Archivo'
              ? ['Regular', 'Medium', 'SemiBold', 'Bold']
              : ['Bold', 'ExtraBold']) {
        fonts.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
      }
      await fonts.load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final locale in ['de', 'en']) {
      for (final training in [false, true]) {
        testWidgets(
          '$training editor keeps focused input and actions reachable '
          'at 320px / 2x with keyboard ($locale/$brightness)',
          (tester) async {
            await pumpLocalized(
              tester,
              training
                  ? Builder(
                      builder: (context) => TextButton(
                        onPressed: () => showTrainingPlanEditor(
                          context,
                          onSave: (_) async => SyncDelivery.delivered,
                        ),
                        child: const Text('Open'),
                      ),
                    )
                  : RecipesScreen(onAddMeal: (_, _) {}),
              locale: Locale(locale),
              brightness: brightness,
              surfaceSize: const Size(320, 568),
              textScale: 2,
            );
            await tester.tap(
              training
                  ? find.text('Open')
                  : find.byKey(const ValueKey('recipe-create-button')),
            );
            await tester.pumpAndSettle();
            final field = find.byKey(
              ValueKey(
                training ? 'training-editor-title' : 'recipe-create-name',
              ),
            );
            await tester.ensureVisible(field);
            await tester.pumpAndSettle();
            await tester.tap(field);
            await tester.enterText(field, 'Test');
            await tester.pump();
            expect(
              tester
                  .widget<EditableText>(
                    find.descendant(
                      of: field,
                      matching: find.byType(EditableText),
                    ),
                  )
                  .focusNode
                  .hasFocus,
              isTrue,
            );
            tester.view.viewInsets = FakeViewPadding(
              bottom: 220 * tester.view.devicePixelRatio,
            );
            addTearDown(tester.view.resetViewInsets);
            await tester.pumpAndSettle();
            final save = find.byKey(
              ValueKey(
                training ? 'training-editor-save' : 'recipe-create-save',
              ),
            );
            final close = find.byKey(
              ValueKey(
                training ? 'training-editor-close' : 'recipe-create-close',
              ),
            );
            final viewport = tester.getRect(
              find.byKey(
                ValueKey(
                  training ? 'training-editor-scroll' : 'recipe-create-scroll',
                ),
              ),
            );
            final text = tester.getRect(
              find.descendant(of: field, matching: find.byType(EditableText)),
            );
            expect(text.top, greaterThanOrEqualTo(viewport.top));
            expect(text.bottom, lessThanOrEqualTo(viewport.bottom));
            expect(text.bottom, lessThan(tester.getTopLeft(save).dy));
            expect(save.hitTestable(), findsOneWidget);
            expect(close.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('editing and saving workout notes preserves line breaks', (
    tester,
  ) async {
    final draft = CoachTrainingProposal(
      title: 'Plan',
      workouts: [
        TrainingWorkout(
          title: 'Session',
          description: 'Warm up\nCool down',
          exercises: [
            TrainingExercise(name: 'Squat', sets: 1, reps: 5, restSeconds: 0),
          ],
        ),
      ],
    );
    CoachTrainingProposal? saved;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showTrainingPlanEditor(
            context,
            initialDraft: draft,
            onSave: (value) async {
              saved = value;
              return SyncDelivery.delivered;
            },
          ),
          child: const Text('Open'),
        ),
      ),
      surfaceSize: const Size(390, 844),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final edit = find.byKey(const ValueKey('training-editor-edit'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final notes = find.byKey(
      const ValueKey('training-editor-workout-0-description'),
    );
    await tester.ensureVisible(notes);
    await tester.pumpAndSettle();
    await tester.enterText(notes, 'Warm up\nCool down!');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('training-editor-save')));
    await tester.pumpAndSettle();
    expect(saved!.workouts.single.description, 'Warm up\nCool down!');
  });

  testWidgets('recipe photo actions keep full labels and 48px touch targets', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      RecipesScreen(onAddMeal: (_, _) {}),
      surfaceSize: const Size(320, 568),
      textScale: 2,
    );
    await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
    await tester.pumpAndSettle();
    for (final name in ['camera', 'gallery']) {
      final action = find.byKey(ValueKey('recipe-create-photo-$name'));
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      expect(action.hitTestable(), findsOneWidget);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      final label = tester.renderObject<RenderParagraph>(
        find.descendant(of: action, matching: find.byType(Text)),
      );
      expect(label.didExceedMaxLines, isFalse);
      expect(label.overflow, isNot(TextOverflow.ellipsis));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'recipe close preserves a dirty draft until discard is confirmed',
    (tester) async {
      var saves = 0;
      await pumpLocalized(
        tester,
        RecipesScreen(
          onAddMeal: (_, _) {},
          onCreateRecipe: (_) async {
            saves++;
            return SyncDelivery.delivered;
          },
        ),
        surfaceSize: const Size(390, 844),
      );
      await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('recipe-create-name'));
      await tester.enterText(name, 'Mein Rezept');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipe-create-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('discard-changes-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(name).controller!.text, 'Mein Rezept');
      await tester.tap(find.byKey(const ValueKey('recipe-create-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsNothing);
      expect(saves, 0);
    },
  );
}
