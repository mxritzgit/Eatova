// Regression: a toast in the add sheet on a phone with a home indicator.
//
// The sheet reaches the screen's bottom edge, so its SnackHost strip sits on
// the 34 pt bottom inset. The strip's Scaffold lifts a floating SnackBar
// above that inset, but the strip's height did not count it: the toast was
// pushed above the strip's top and debug Flutter threw "Floating SnackBar
// presented off screen" on the first add (found in the design polish run,
// 2026-10-02). The favorites sheet already avoided it with
// `MediaQuery.removeViewPadding`.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

import 'flows/flow_test_helpers.dart' show FakeProductLookupService, storeOf;
import 'support/design_capture.dart' show kDesignSafeArea, pinDesignViewport;
import 'support/food_design_fixture.dart';
import 'support/harness.dart';

const _banana = MealAnalysisResult(
  mealName: 'Banana',
  caloriesKcal: 105,
  estimatedGrams: 118,
  kcalPer100G: 89,
  protein: '1 g',
  carbs: '27 g',
  fat: '0 g',
  confidence: 'database',
  portionNotes: '',
);

void main() {
  for (final textScale in <double>[1.0, 2.0]) {
    testWidgets('Toast im Add-Sheet bleibt ueber dem Home-Indikator '
        '(Schrift $textScale)', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        pinDesignViewport(tester);
        await tester.pumpWidget(
          localizedApp(
            EatovaHomePage(productService: FakeProductLookupService()),
            locale: const Locale('en'),
            textScale: textScale,
            safeArea: false,
            scaffold: false,
          ),
        );
        await tester.pumpAndSettle();
        storeOf(tester)
          ..profile = foodDesignProfile
          ..loggedMeals = foodDesignMeals()
          ..favorites = <FavoriteMeal>[
            FavoriteMeal(
              id: FavoriteMeal.idFor(_banana),
              result: _banana,
              addedAt: foodDesignNow,
            ),
          ];
        await tester.tap(find.byKey(const ValueKey('nav-Food')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('food-search')));
        await tester.pumpAndSettle();

        final row = find.byKey(const ValueKey('favorite-tile-0'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        final add = find.byKey(const ValueKey('favorite-tile-add-0'));
        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        await tester.tap(add);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull);
        final snack = find.byType(SnackBar);
        expect(snack, findsOneWidget);
        // Fully on screen and clear of the home indicator.
        final rect = tester.getRect(snack);
        final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(
          rect.bottom,
          lessThanOrEqualTo(screen.height - kDesignSafeArea.bottom + 0.5),
        );
        // Inside the sheet, above its content.
        final sheet = tester.getRect(
          find.byKey(const ValueKey('add-meal-sheet')),
        );
        expect(rect.top, greaterThanOrEqualTo(sheet.top));

        await tester.pumpAndSettle(const Duration(seconds: 5));
      });
    });
  }
}
