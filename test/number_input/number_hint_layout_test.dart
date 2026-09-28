import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// The new hints are the longest error texts these fields show. They must wrap
// inside the narrowest cells — a 320 px phone at 200 % text — without a
// layout error.

const Size _schmal = Size(320, 1400);

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  final feld = find.byKey(ValueKey(key));
  await tester.ensureVisible(feld);
  await tester.enterText(feld, text);
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);
    final code = locale.languageCode;

    testWidgets('Rezeptformular [$code] bei 320 px und 200 %', (tester) async {
      final fehler = await collectOverflows(() async {
        await pumpLocalized(
          tester,
          RecipesScreen(onAddMeal: (MealAnalysisResult _, MealSlot _) {}),
          locale: locale,
          textScale: 2,
          surfaceSize: _schmal,
        );
        await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
        await tester.pumpAndSettle();
        await _tippe(tester, 'recipe-create-fat', '1.000');
        await _tippe(tester, 'recipe-create-kcal', '3,5');
      });
      expect(fehler, isEmpty, reason: describeOverflows(fehler));
      expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget);
      expect(find.text(ganzzahlHinweis(l10n)), findsOneWidget);
    });

    testWidgets('Manuell [$code] bei 320 px und 200 %', (tester) async {
      final fehler = await collectOverflows(() async {
        await pumpLocalized(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showManualMealSheet(context),
              child: const Text('open'),
            ),
          ),
          locale: locale,
          textScale: 2,
          surfaceSize: _schmal,
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await _tippe(tester, 'manual-meal-carbs', '1.000');
        await _tippe(tester, 'manual-meal-grams', '3,5');
      });
      expect(fehler, isEmpty, reason: describeOverflows(fehler));
      expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget);
      expect(find.text(ganzzahlHinweis(l10n)), findsOneWidget);
    });

    testWidgets('Ziele [$code] bei 320 px und 200 %', (tester) async {
      final fehler = await collectOverflows(() async {
        await pumpLocalized(
          tester,
          const GoalsScreen(profile: UserProfile()),
          locale: locale,
          textScale: 2,
          surfaceSize: _schmal,
        );
        await _tippe(tester, 'settings-weight', '1.000');
        await _tippe(tester, 'settings-height', '3,5');
      });
      expect(fehler, isEmpty, reason: describeOverflows(fehler));
      expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget);
      expect(find.text(ganzzahlHinweis(l10n)), findsOneWidget);
    });

    testWidgets('Portions-Gramm [$code] bei 320 px und 200 %', (tester) async {
      // The expanded item itself must fit first: its `_LivePreview` row
      // ("= 250 kcal ...") used to overflow at this size.
      final vorher = await collectOverflows(() async {
        await pumpLocalized(
          tester,
          ListView(
            children: [
              MealSuggestionItem(
                result: const MealAnalysisResult(
                  mealName: 'Haferdrink',
                  caloriesKcal: 250,
                  estimatedGrams: 100,
                  kcalPer100G: 250,
                  protein: '-',
                  carbs: '-',
                  fat: '-',
                  confidence: 'database',
                  portionNotes: '',
                ),
                expanded: true,
                onTap: () {},
                onAdd: (_) {},
              ),
            ],
          ),
          locale: locale,
          textScale: 2,
          surfaceSize: _schmal,
        );
        await tester.pumpAndSettle();
      });
      expect(vorher, isEmpty, reason: describeOverflows(vorher));
      final fehler = await collectOverflows(() async {
        await tester.enterText(find.byType(TextField), '1.000');
        await tester.pumpAndSettle();
      });
      expect(fehler, isEmpty, reason: describeOverflows(fehler));
      expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget);
    });
  }
}
