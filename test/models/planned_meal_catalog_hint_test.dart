import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:flutter_test/flutter_test.dart';

PlannedMeal _plan(FitnessRecipe recipe) => PlannedMeal.create(
  id: '7c000000-0000-4000-8000-000000000001',
  recipe: recipe,
  day: DateTime(2026, 9, 28),
  slot: MealSlot.dinner,
);

void main() {
  test('a planned German catalog recipe keeps its professional hint', () {
    final catalog = recipeCatalogDe.first;
    expect(catalog.professionalHint, isNotEmpty);
    final recipe = _plan(catalog).recipe;
    expect(recipe.displayProfessionalHint(deL10n), catalog.professionalHint);

    final note = recipe.toMealResultForServings(1, deL10n).portionNotes;
    expect(note, contains(catalog.professionalHint));
    expect(note, isNot(contains(deL10n.recipesSelfCreatedHint)));
  });

  test('a planned English catalog recipe keeps the English hint', () {
    final catalog = recipeCatalogEn.first;
    final note = _plan(
      catalog,
    ).recipe.toMealResultForServings(1, enL10n).portionNotes;
    expect(note, contains(catalog.professionalHint));
    expect(note, isNot(contains(enL10n.recipesSelfCreatedHint)));
  });

  test('own recipes and renamed catalog slugs keep the placeholder', () {
    final own = recipeCatalogDe.first.copyWith(slug: 'user_own');
    expect(
      _plan(own).recipe.displayProfessionalHint(deL10n),
      deL10n.recipesSelfCreatedHint,
    );
    final renamed = recipeCatalogDe.first.copyWith(title: 'Umbenannt');
    expect(
      _plan(renamed).recipe.displayProfessionalHint(deL10n),
      deL10n.recipesSelfCreatedHint,
    );
  });

  test('the persisted snapshot stays unchanged', () {
    final plan = _plan(recipeCatalogDe.first);
    expect(plan.toJson()['recipe'], recipeCatalogDe.first.toRow());
    expect(plan.recipe.toRow(), recipeCatalogDe.first.toRow());
  });
}
