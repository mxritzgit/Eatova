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
}
