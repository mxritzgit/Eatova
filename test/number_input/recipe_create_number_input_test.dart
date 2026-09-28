import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// The own-recipe form stores whole numbers (kcal, grams, macros per portion).
// `FilteringTextInputFormatter.digitsOnly` swallowed the separator, so "3,5" g
// fat became 35 g and was saved without a word. The fields now keep the typed
// text and refuse decimals and ambiguous groups with a hint.

const List<String> _zahlenfelder = <String>[
  'recipe-create-kcal',
  'recipe-create-grams',
  'recipe-create-protein',
  'recipe-create-carbs',
  'recipe-create-fat',
];

Future<List<FitnessRecipe>> _oeffne(WidgetTester tester, Locale locale) async {
  final angelegt = <FitnessRecipe>[];
  await pumpLocalized(
    tester,
    RecipesScreen(
      onAddMeal: (MealAnalysisResult _, MealSlot _) {},
      onCreateRecipe: (recipe) async {
        angelegt.add(recipe);
        return SyncDelivery.delivered;
      },
    ),
    locale: locale,
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
  return angelegt;
}

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  final feld = find.byKey(ValueKey(key));
  await tester.ensureVisible(feld);
  await tester.enterText(feld, text);
  await tester.pumpAndSettle();
}

String _inhalt(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

bool _speichernAktiv(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('recipe-create-save')))
        .onPressed !=
    null;

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);

    testWidgetsRobust(
      'Rezeptformular [${locale.languageCode}]: Dezimalzahlen und '
      'Tausendergruppen werden nicht zu anderen ganzen Zahlen',
      (tester) async {
        final angelegt = await _oeffne(tester, locale);
        await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');
        await _tippe(tester, 'recipe-create-kcal', '520');
        expect(_speichernAktiv(tester), isTrue);

        for (final key in _zahlenfelder) {
          final vorher = _inhalt(tester, key);
          for (final (eingabe, hinweis) in ganzzahlFaelle(l10n)) {
            await _tippe(tester, key, eingabe);
            expect(
              _inhalt(tester, key),
              eingabe,
              reason: '$key: "$eingabe" muss stehen bleiben (digitsOnly '
                  'machte aus 3,5 die 35)',
            );
            expect(find.text(hinweis), findsOneWidget, reason: '$key $eingabe');
            expect(_speichernAktiv(tester), isFalse, reason: '$key $eingabe');
          }
          await _tippe(tester, key, vorher);
        }

        // Whole numbers still save exactly as typed.
        await _tippe(tester, 'recipe-create-fat', '4');
        await _tippe(tester, 'recipe-create-grams', '350');
        expect(_speichernAktiv(tester), isTrue);
        await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
        await tester.pumpAndSettle();
        expect(angelegt.single.fatG, 4);
        expect(angelegt.single.estimatedGrams, 350);
        expect(angelegt.single.caloriesKcal, 520);
      },
    );
  }

  testWidgetsRobust(
    'eindeutige Tausendergruppe als ganze Zahl wird gespeichert',
    (tester) async {
      final angelegt = await _oeffne(tester, const Locale('de'));
      await _tippe(tester, 'recipe-create-name', 'Familienblech');
      // Two groups can only be grouping — no hint, no guess.
      await _tippe(tester, 'recipe-create-kcal', '1.000.000');
      expect(find.text('1–10000 kcal'), findsOneWidget,
          reason: 'eindeutig 1 000 000, also ausserhalb des Bereichs');
      await _tippe(tester, 'recipe-create-kcal', '2.500,0');
      expect(_speichernAktiv(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
      await tester.pumpAndSettle();
      expect(angelegt.single.caloriesKcal, 2500);
    },
  );
}
