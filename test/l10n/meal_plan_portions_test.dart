import 'package:eatova/src/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('meal plan portions use localized singular and fractional plurals', () {
    expect(deL10n.mealPlanPortionCount(1), '1 Portion');
    expect(deL10n.mealPlanPortionCount(1.0), '1 Portion');
    expect(deL10n.mealPlanPortionCount(2), '2 Portionen');
    expect(deL10n.mealPlanPortionCount(0.5), '0,5 Portionen');
    expect(deL10n.mealPlanPortionCount(1.5), '1,5 Portionen');
    expect(enL10n.mealPlanPortionCount(1), '1 serving');
    expect(enL10n.mealPlanPortionCount(1.0), '1 serving');
    expect(enL10n.mealPlanPortionCount(2), '2 servings');
    expect(enL10n.mealPlanPortionCount(0.5), '0.5 servings');
    expect(enL10n.mealPlanPortionCount(1.5), '1.5 servings');
  });

  test('ingredient hints name one serving or several, never "Portion(en)"', () {
    for (final (l10n, one, two) in [
      (deL10n, 'für 1 Portion', 'für 2 Portionen'),
      (enL10n, 'for 1 serving', 'for 2 servings'),
    ]) {
      for (final hint in [
        l10n.recipeIngredientsForServings,
        l10n.recipeIngredientsOriginalBatch,
      ]) {
        expect(hint(1), matches(RegExp('$one\\b')), reason: l10n.localeName);
        expect(hint(2), matches(RegExp('$two\\b')), reason: l10n.localeName);
        expect(hint(2), isNot(contains('(')), reason: l10n.localeName);
      }
    }
    expect(deL10n.recipeIngredientsForServings(1.5), contains('1,5 Portionen'));
  });
}
