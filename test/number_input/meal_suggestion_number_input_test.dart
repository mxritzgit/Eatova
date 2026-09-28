import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// The gram pill of a search hit, favorite or recent meal. `digitsOnly` turned
// "3,5" into 35 g and logged it.

const _haferdrink = MealAnalysisResult(
  mealName: 'Haferdrink',
  caloriesKcal: 250,
  estimatedGrams: 100,
  kcalPer100G: 250,
  protein: '-',
  carbs: '-',
  fat: '-',
  confidence: 'database',
  portionNotes: '',
);

Finder get _feld => find.byType(TextField);

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);

    testWidgets(
      'Portions-Gramm [${locale.languageCode}]: keine 35 g aus "3,5"',
      (tester) async {
        final hinzugefuegt = <MealAnalysisResult>[];
        await pumpLocalized(
          tester,
          ListView(
            children: [
              MealSuggestionItem(
                result: _haferdrink,
                expanded: true,
                onTap: () {},
                onAdd: hinzugefuegt.add,
                addButtonKey: const ValueKey('add'),
              ),
            ],
          ),
          locale: locale,
          safeArea: false,
        );
        await tester.pumpAndSettle();
        final hinweis = find.byKey(const ValueKey('kcal-suggestion-grams-hint'));
        final hinzufuegen = find.byKey(const ValueKey('add'));

        for (final (eingabe, erwartet) in ganzzahlFaelle(l10n)) {
          await tester.enterText(_feld, eingabe);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(_feld).controller!.text,
            eingabe,
            reason: eingabe,
          );
          expect(tester.widget<Text>(hinweis).data, erwartet, reason: eingabe);
          expect(tester.widget<ButtonStyleButton>(hinzufuegen).onPressed,
              isNull, reason: eingabe);
        }

        // Five digits and a separator fit the five-digit budget.
        await tester.enterText(_feld, '10.000');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(_feld).controller!.text, '10.000');
        expect(tester.widget<Text>(hinweis).data,
            l10n.numberInputAmbiguous('10', '10000'));

        await tester.enterText(_feld, '150');
        await tester.pumpAndSettle();
        expect(hinweis, findsNothing);
        await tester.tap(hinzufuegen);
        await tester.pumpAndSettle();
        expect(hinzugefuegt.single.estimatedGrams, 150);
      },
    );
  }
}
