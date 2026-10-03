// Visual evidence for the "Your recipe" sheet redesign (2026-10-03): the live
// preview card on top, the soft toggle rows, the accent save action and the
// ingredient editor in the meal-row language.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/recipe-create-*.png; without it the suite still checks
// that every state renders without an exception or overflow, also at 320 px
// with 2x text.

import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';
import '../support/recipe_navigation.dart';

/// Hands back a bundled dish photo instead of opening the system picker.
class _DishPhoto implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async {
    final bytes = File(
      'assets/recipes/falafel_bowl_mit_hummus.jpg',
    ).readAsBytesSync();
    return MealPhotoSelection(
      request: MealAnalysisRequest(imageId: 'capture', imageBytes: bytes),
      previewBytes: bytes,
    );
  }
}

class _Products implements ProductLookupService {
  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async => [
    for (final (code, name, brand, kcal, protein, carbs, fat) in [
      ('101', 'Rolled oats', 'Kölln', 372, 13.5, 58.7, 7.0),
      ('102', 'Oat drink barista', 'Oatly', 59, 1.0, 6.6, 3.0),
      ('103', 'Oat bran', null, 361, 17.0, 47.0, 7.1),
    ])
      ProductSearchResult.fromOpenFoodFacts({
        'code': code,
        'product_name': name,
        'brands': ?brand,
        'nutriments': {
          'energy-kcal_100g': kcal,
          'proteins_100g': protein,
          'carbohydrates_100g': carbs,
          'fat_100g': fat,
        },
      }),
  ];

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnimplementedError();
}

Finder _key(String key) => find.byKey(ValueKey(key));

/// The sheet's own scrollable; text fields nest further ones below it.
Finder get _scroll => find
    .descendant(
      of: _key('recipe-create-scroll'),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _open(
  WidgetTester tester, {
  double textScale = 1,
  Size? narrow,
  Brightness brightness = Brightness.dark,
}) async {
  pinDesignViewport(tester);
  if (narrow != null) {
    tester.view.physicalSize = narrow * kDesignPixelRatio;
  }
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        RecipesScreen(
          onAddMeal: (_, _) {},
          onCreateRecipe: (_) async => SyncDelivery.delivered,
          photoInput: _DishPhoto(),
          productService: _Products(),
        ),
        locale: const Locale('en'),
        brightness: brightness,
        textScale: textScale,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await openRecipeCreateSheet(tester);
  expect(_key('recipe-create-sheet'), findsOneWidget);
}

Future<void> _type(WidgetTester tester, String field, String text) async {
  final finder = _key('recipe-create-$field');
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

/// Drops the focus fill so a shot shows the resting fields.
Future<void> _unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, double offset) async {
  tester.state<ScrollableState>(_scroll).position.jumpTo(offset);
  await tester.pumpAndSettle();
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  final position = tester.state<ScrollableState>(_scroll).position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
}

Future<void> _addManualIngredient(
  WidgetTester tester,
  List<String> values,
) async {
  final add = _key('ingredient-add');
  await tester.ensureVisible(add);
  await tester.pumpAndSettle();
  await tester.tap(add);
  await tester.pumpAndSettle();
  await tester.tap(_key('ingredient-manual'));
  await tester.pumpAndSettle();
  for (var i = 0; i < values.length; i++) {
    final field = _key('ingredient-field-$i');
    await tester.ensureVisible(field);
    await tester.enterText(field, values[i]);
    await tester.pump();
  }
  await tester.pumpAndSettle();
  final save = find.text(enL10n.ingredientSave);
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  // The recipes screen behind the sheet rotates by date.
  Future<void> fixed(Future<void> Function() body) =>
      withClock(Clock.fixed(DateTime(2026, 10, 3, 12)), body);

  testWidgets('empty sheet, filled preview, toggles and save', (tester) async {
    await fixed(() async {
      await _open(tester);
      expect(
        find.text(enL10n.recipesPreviewNamePlaceholder),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'recipe-create-00-empty');

      await _type(tester, 'name', 'Falafel bowl with hummus');
      await _type(tester, 'kcal', '640');
      await _type(tester, 'protein', '24');
      await _type(tester, 'carbs', '71');
      await _type(tester, 'fat', '27');
      final camera = _key('recipe-create-photo-camera');
      await tester.ensureVisible(camera);
      await tester.pumpAndSettle();
      await tester.tap(camera);
      await tester.pumpAndSettle();
      await _unfocus(tester);
      await _scrollTo(tester, 0);
      await precacheDesignImages(tester);
      expect(
        tester.widget<Text>(_key('recipe-create-preview-name')).data,
        'Falafel bowl with hummus',
      );
      expect(
        tester
            .widget<Text>(_key('recipe-create-preview-kcal'))
            .textSpan!
            .toPlainText(),
        startsWith('640 kcal'),
      );
      await captureDesignShot(tester, 'recipe-create-01-filled');

      await _scrollTo(tester, 360);
      await captureDesignShot(tester, 'recipe-create-02-middle');

      await _scrollToEnd(tester);
      await captureDesignShot(tester, 'recipe-create-03-bottom');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('calculate from ingredients with the editor', (tester) async {
    await fixed(() async {
      await _open(tester);
      await _type(tester, 'name', 'Overnight oats');
      final structured = _key('recipe-create-structured');
      await tester.ensureVisible(structured);
      await tester.pumpAndSettle();
      await tester.tap(structured);
      await tester.pumpAndSettle();
      await _addManualIngredient(tester, [
        'Rolled oats',
        '80',
        '372',
        '13.5',
        '58.7',
        '7',
      ]);
      await _addManualIngredient(tester, ['Skyr', '250', '63', '11', '4', '']);
      await _unfocus(tester);
      await tester.ensureVisible(_key('recipe-create-structured'));
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'recipe-create-04-ingredients');

      final portion = _key('recipe-portion-field');
      await tester.ensureVisible(portion);
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'recipe-create-05-portions');

      // The search half of the ingredient sheet with product hits.
      final add = _key('ingredient-add');
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(_key('ingredient-query'), 'oats');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(_key('ingredient-result-0'), findsOneWidget);
      await _unfocus(tester);
      await captureDesignShot(tester, 'recipe-create-06-search');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('320 px with 2x text renders every section', (tester) async {
    await fixed(() async {
      await _open(tester, textScale: 2, narrow: const Size(320, 700));
      await _type(tester, 'name', 'Falafel bowl with hummus');
      await _type(tester, 'kcal', '640');
      await _type(tester, 'protein', '24');
      await _unfocus(tester);
      await _scrollTo(tester, 0);
      await captureDesignShot(tester, 'recipe-create-07-narrow-top');
      final structured = _key('recipe-create-structured');
      await tester.ensureVisible(structured);
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'recipe-create-08-narrow-toggle');
      await tester.tap(structured);
      await tester.pumpAndSettle();
      await _addManualIngredient(tester, [
        'Rolled oats',
        '80',
        '372',
        '13.5',
        '58.7',
        '7',
      ]);
      await _unfocus(tester);
      await tester.ensureVisible(_key('ingredient-edit-0'));
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'recipe-create-09-narrow-ingredients');
      final portion = _key('recipe-portion-field');
      await tester.ensureVisible(portion);
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'recipe-create-10-narrow-portions');
      await _scrollToEnd(tester);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('light palette: preview and ingredient rows', (tester) async {
    await fixed(() async {
      await _open(tester, brightness: Brightness.light);
      await _type(tester, 'name', 'Overnight oats');
      final structured = _key('recipe-create-structured');
      await tester.ensureVisible(structured);
      await tester.pumpAndSettle();
      await tester.tap(structured);
      await tester.pumpAndSettle();
      await _addManualIngredient(tester, [
        'Rolled oats',
        '80',
        '372',
        '13.5',
        '58.7',
        '7',
      ]);
      await _unfocus(tester);
      await _scrollTo(tester, 0);
      await captureDesignShot(tester, 'recipe-create-11-light-top');
      await tester.ensureVisible(_key('ingredient-edit-0'));
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'recipe-create-12-light-ingredients');
      expect(tester.takeException(), isNull);
    });
  });
}
