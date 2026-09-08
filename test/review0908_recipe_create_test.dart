import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

class _PhotoInput implements MealPhotoInput {
  final bytes = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 8, height: 8)),
  );

  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async =>
      MealPhotoSelection(
        request: MealAnalysisRequest(imageId: 'recipe-test', imageBytes: bytes),
        previewBytes: bytes,
      );
}

class _HeldImageStore extends RecipeImageStore {
  final completion = Completer<String?>();
  int calls = 0;

  @override
  Future<String?> save({required Uint8List bytes}) {
    calls++;
    return completion.future;
  }
}

Future<List<FitnessRecipe>> _open(WidgetTester tester) async {
  pinPhoneViewport(tester);
  final created = <FitnessRecipe>[];
  await pumpLocalized(
    tester,
    RecipesScreen(
      onAddMeal: (_, __) {},
      photoInput: _PhotoInput(),
      onCreateRecipe: (recipe) async {
        created.add(recipe);
        return SyncDelivery.delivered;
      },
    ),
    reducedMotion: false,
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
  await _enter(tester, 'name', 'Protein Bowl');
  await _enter(tester, 'kcal', '520');
  return created;
}

Finder _field(String name) => find.byKey(ValueKey('recipe-create-$name'));

Future<void> _enter(WidgetTester tester, String field, String text) async {
  await tester.enterText(_field(field), text);
  await tester.pumpAndSettle();
}

Future<void> _startPhotoSave(WidgetTester tester) async {
  await tester.tap(_field('photo-camera'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(_field('save'));
  await tester.tap(_field('save'));
  await tester.pump();
}

void main() {
  tearDown(RecipeImageStore.resetInstance);

  testWidgets(
    'photo save uses the complete validated draft from the save tap',
    (tester) async {
      final images = _HeldImageStore();
      RecipeImageStore.instance = images;
      final created = await _open(tester);
      await _enter(tester, 'protein', '40');
      await _startPhotoSave(tester);
      expect(images.calls, 1);
      expect(created, isEmpty);

      // A controller change represents input arriving after validation but
      // before disk IO completes. The submitted draft must remain coherent.
      tester.widget<TextField>(_field('kcal')).controller!.text = '';
      tester.widget<TextField>(_field('grams')).controller!.text = '0';
      tester.widget<TextField>(_field('protein')).controller!.text = '99999';
      images.completion.complete(null);
      await tester.pumpAndSettle();

      expect(created, hasLength(1));
      expect(created.single.caloriesKcal, 520);
      expect(created.single.estimatedGrams, 300);
      expect(created.single.proteinG, 40);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('back during photo save cannot place a discard dialog above it', (
    tester,
  ) async {
    final images = _HeldImageStore();
    RecipeImageStore.instance = images;
    final created = await _open(tester);
    await _startPhotoSave(tester);
    expect(images.calls, 1);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    final discard = find.byKey(const ValueKey('discard-changes-dialog'));
    final openedDiscard = discard.evaluate().isNotEmpty;
    // Finish the held operation even on the faulty implementation so the
    // failure does not leave an unfinished disk write in the test.
    if (openedDiscard) {
      await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
      await tester.pumpAndSettle();
    }
    images.completion.complete(null);
    await tester.pumpAndSettle();

    expect(
      openedDiscard,
      isFalse,
      reason: 'an in-flight save owns the sheet until its result is returned',
    );
    expect(created, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  final family = String.fromCharCodes([
    0x1F468,
    0x200D,
    0x1F469,
    0x200D,
    0x1F467,
    0x200D,
    0x1F466,
  ]);
  for (final (field, maxCodePoints, graphemes) in [
    ('portion', 1000, 143),
    ('ingredients', 20000, 2858),
  ]) {
    testWidgets(
      '$field rejects graphemes exceeding the database codepoint cap',
      (tester) async {
        final created = await _open(tester);
        await _enter(tester, field, family * graphemes);
        final text = tester.widget<TextField>(_field(field)).controller!.text;
        expect(text.runes.length, greaterThan(maxCodePoints));
        expect(tester.widget<FilledButton>(_field('save')).onPressed, isNull);
        expect(created, isEmpty);

        // Exactly the DB boundary is accepted, including multi-codepoint
        // graphemes. A blanket rejection of Unicode must not pass.
        final groups = maxCodePoints ~/ 7;
        await _enter(
          tester,
          field,
          family * groups + 'a' * (maxCodePoints - groups * 7),
        );
        expect(
          tester.widget<FilledButton>(_field('save')).onPressed,
          isNotNull,
        );
        await tester.ensureVisible(_field('save'));
        await tester.tap(_field('save'));
        await tester.pumpAndSettle();
        expect(created, hasLength(1));
        final saved = field == 'portion'
            ? created.single.portion
            : created.single.ingredients;
        expect(saved.runes.length, maxCodePoints);
      },
    );
  }
}
