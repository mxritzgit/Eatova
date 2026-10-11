// The shopping receipt (2026-10-10): a recipe's free-text ingredients become
// lines with their own check. Ids stay locale-neutral and survive edits to
// other lines; amounts are only split off for display; section labels are
// never checked; a recipe checked as a whole before keeps its lines checked.

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 10, 5);

FitnessRecipe _recipe(String ingredients) => recipeCatalogEn.first.copyWith(
  title: 'Bowl',
  ingredients: ingredients,
  structuredIngredients: const [],
);

PlannedMeal _plan(
  String ingredients, {
  String id = '00000000-0000-4000-8000-00000000000a',
  double servings = 1,
  MealSlot slot = MealSlot.dinner,
}) => PlannedMeal.create(
  recipe: _recipe(ingredients),
  day: _day,
  slot: slot,
  servings: servings,
  id: id,
);

List<ShoppingLine> _lines(PlannedMeal plan, {String separator = '.'}) =>
    buildShoppingList([plan], _day, decimalSeparator: separator).single.lines;

void main() {
  test('every free-text line gets its own valid, stable check id', () {
    const text =
        '- 180 g chicken breast fillet, raw\n- 1 small garlic clove\n- Salt';
    final lines = _lines(_plan(text));
    expect(lines, hasLength(3));
    expect(lines.map((l) => l.id).toSet(), hasLength(3));
    for (final line in lines) {
      // The id is a valid check of the week the list belongs to.
      expect(
        ShoppingCheck.fromJson({'id': line.id, 'checked': true}).id,
        startsWith('2026-10-05:'),
      );
    }

    // A slot change keeps the checks; new servings change every amount.
    expect(
      _lines(_plan(text, slot: MealSlot.lunch)).map((l) => l.id),
      lines.map((l) => l.id),
    );
    expect(
      _lines(_plan(text, servings: 2)).map((l) => l.id).toSet().intersection(
        lines.map((l) => l.id).toSet(),
      ),
      isEmpty,
    );
    // Another plan of the same recipe is its own shopping.
    expect(
      _lines(_plan(text, id: '00000000-0000-4000-8000-00000000000b')).first.id,
      isNot(lines.first.id),
    );

    // Editing one line keeps the other lines' checks.
    final edited = _lines(
      _plan('- 200 g chicken breast fillet, raw\n- 1 small garlic clove\n'
          '- Salt'),
    );
    expect(edited.first.id, isNot(lines.first.id));
    expect(edited.skip(1).map((l) => l.id), lines.skip(1).map((l) => l.id));
  });

  test('a repeated line is two checks', () {
    final [first, second] = _lines(_plan('1 lemon\n1 lemon'));
    expect(first.id, isNot(second.id));
  });

  test('German decimals change the display, never the line ids', () {
    final recipe = RecipeImportCandidate.fromJson({
      'id': 'mince',
      'title': 'Mince pockets',
      'ingredients': '½ Zwiebel\n1 kg Kartoffeln',
      'preparation': 'Bake.',
      'portion': '4 portions',
      'nutrition_estimated': false,
      'nutrition_basis': 'per_serving',
      'ingredients_basis': 'per_recipe',
      'servings': 4,
      'calories_kcal': 350,
      'protein_g': 30,
      'carbs_g': 25,
      'fat_g': 10,
    });
    final plan = PlannedMeal.create(
      recipe: recipe.toRecipe(slug: recipe.stableSlug(), sourceLabel: 'Source'),
      day: _day,
      slot: MealSlot.lunch,
    );
    final german = _lines(plan, separator: ',');
    final english = _lines(plan);
    expect(german.map((l) => l.amount), ['0,125', '0,25 kg']);
    expect(english.map((l) => l.amount), ['0.125', '0.25 kg']);
    expect(german.map((l) => l.id), english.map((l) => l.id));
  });

  test('a leading amount is split off for display only', () {
    const cases = {
      '180 g chicken breast fillet, raw': ('180 g', 'Chicken breast fillet, raw'),
      '1½ EL Backpulver': ('1 1/2 EL', 'Backpulver'),
      '½ weiße Zwiebel': ('1/2', 'Weiße Zwiebel'),
      '1 Dose Thunfisch im eigenen Saft': ('1 Dose', 'Thunfisch im eigenen Saft'),
      'ca. 2–3 Eier': ('ca. 2–3', 'Eier'),
      '2 x 150 g Lachs': ('2 x 150 g', 'Lachs'),
      '100g Mehl': ('100g', 'Mehl'),
      '1 sprig rosemary': ('1 sprig', 'Rosemary'),
      // "l" is a unit only as a word of its own.
      '2 large eggs': ('2', 'Large eggs'),
      '200 g äpfel': ('200 g', 'Äpfel'),
      'Salt, pepper to taste': (null, 'Salt, pepper to taste'),
      // A capital "ß" would be "SS"; the label stays as written.
      'ßirup': (null, 'ßirup'),
    };
    for (final MapEntry(key: text, value: (amount, label)) in cases.entries) {
      final line = _lines(_plan(text)).single;
      expect((line.amount, line.label), (amount, label), reason: text);
      expect(line.heading, isFalse, reason: text);
    }
  });

  test('section labels are shown but never checked', () {
    final item = buildShoppingList([
      _plan('Für den Pizzaboden:\n200 g Frischkäse\nBelag:\n20 g Mais\n'
          'Zutaten: 1 Ei'),
    ], _day).single;
    expect(item.lines.map((l) => l.heading), [true, false, true, false, false]);
    expect(item.lines.first.label, 'Für den Pizzaboden:');
    expect(shoppingProgress([item], const {}), (done: 0, total: 3));
  });

  test('progress counts weighed items and lines; a recipe checked as a whole '
      'keeps its lines checked until one is changed', () {
    final mixed = PlannedMeal.create(
      recipe: _recipe('Topping:\n1 lemon\nSalt').copyWith(
        structuredIngredients: [
          RecipeIngredient(
            name: 'Oats',
            grams: 100,
            source: IngredientSource.manual,
            per100g: const RecipeNutrition(
              caloriesKcal: 370,
              proteinG: 13,
              carbsG: 60,
              fatG: 7,
            ),
          ),
        ],
      ),
      day: _day,
      slot: MealSlot.breakfast,
    );
    final items = buildShoppingList([mixed], _day);
    final weighed = items.singleWhere((i) => i.grams != null);
    final text = items.singleWhere((i) => i.grams == null);
    final [_, lemon, salt] = text.lines;
    expect(shoppingProgress(items, const {}), (done: 0, total: 3));
    expect(
      shoppingProgress(items, {weighed.id: true, salt.id: true}),
      (done: 2, total: 3),
    );

    // Checked as a whole by an earlier version: every line follows.
    final legacy = {text.id: true};
    expect(shoppingLineChecked(legacy, text, lemon), isTrue);
    expect(shoppingProgress(items, legacy), (done: 2, total: 3));
    // A line's own check wins.
    final reopened = {...legacy, lemon.id: false};
    expect(shoppingLineChecked(reopened, text, lemon), isFalse);
    expect(shoppingLineChecked(reopened, text, salt), isTrue);
    expect(shoppingProgress(items, reopened), (done: 1, total: 3));
  });

  test('a recipe without ingredient text offers nothing to check', () {
    final item = buildShoppingList([_plan('')], _day).single;
    expect(item.lines, isEmpty);
    expect(shoppingProgress([item], const {}), (done: 0, total: 0));
  });
}
