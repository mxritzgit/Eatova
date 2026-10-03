// The favorites sheet's sort chips with the app's real fonts (the test font
// draws every glyph as a square and would overstate their width).

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/design_capture.dart';
import 'support/harness.dart';

FavoriteMeal _fav(String name, int day) {
  final result = MealAnalysisResult(
    mealName: name,
    caloriesKcal: 100,
    estimatedGrams: 100,
    kcalPer100G: 100,
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'manual',
    portionNotes: '',
  );
  return FavoriteMeal(
    id: FavoriteMeal.idFor(result),
    result: result,
    addedAt: DateTime(2026, 10, day),
    pinned: true,
  );
}

void main() {
  setUpAll(loadDesignFonts);

  for (final (locale, width) in [('en', 320.0), ('de', 320.0), ('de', 390.0)]) {
    testWidgets('all three chips fit $width px ($locale)', (tester) async {
      await pumpLocalized(
        tester,
        FavoritesSheet(
          favorites: [_fav('Skyr', 3), _fav('Banane', 2)],
          slot: MealSlot.lunch,
          onAdd: (_, __) => 'id',
          onUnpin: (_) {},
        ),
        locale: Locale(locale),
        surfaceSize: Size(width, 700),
        safeArea: false,
        settle: true,
      );
      for (final key in [
        'favorites-sheet-sort-recent',
        'favorites-sheet-sort-frequent',
        'favorites-sheet-sort-alphabetical',
      ]) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.left, greaterThanOrEqualTo(20), reason: key);
        expect(rect.right, lessThanOrEqualTo(width - 20), reason: key);
        expect(rect.height, greaterThanOrEqualTo(42), reason: key);
      }
    });
  }
}
