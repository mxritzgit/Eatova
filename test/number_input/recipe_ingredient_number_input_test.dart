import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/recipe_ingredient.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/recipes/recipe_ingredient_editor.dart';
import 'package:eatova/src/widgets/recipes/recipe_portion_selector.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// Ingredient grams, nutrition per 100 g and batch servings are decimals. They
// were parsed with `double.tryParse(text.replaceAll(',', '.'))`, so "1.000" g
// became 1 g and "1.000" servings became one serving.

class _KeineSuche implements ProductLookupService {
  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnimplementedError();
}

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  final feld = find.byKey(ValueKey(key));
  await tester.ensureVisible(feld);
  await tester.enterText(feld, text);
  await tester.pump();
}

String _inhalt(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Liste {
  List<RecipeIngredient> zutaten;
  _Liste(this.zutaten);
}

Future<_Liste> _pumpEditor(
  WidgetTester tester,
  Locale locale, {
  List<RecipeIngredient> zutaten = const <RecipeIngredient>[],
}) async {
  final liste = _Liste(zutaten);
  await pumpLocalized(
    tester,
    StatefulBuilder(
      builder: (context, setState) => RecipeIngredientEditor(
        ingredients: liste.zutaten,
        productService: _KeineSuche(),
        onChanged: (value) => setState(() => liste.zutaten = value),
      ),
    ),
    locale: locale,
    surfaceSize: const Size(390, 1400),
  );
  return liste;
}

bool _speichernAktiv(WidgetTester tester, String label) {
  final knopf = find.ancestor(
    of: find.text(label),
    matching: find.byType(PrimaryActionButton),
  );
  return tester.widget<PrimaryActionButton>(knopf).onTap != null;
}

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);
    final code = locale.languageCode;

    testWidgets('Zutat [$code]: Gramm und Naehrwerte lesen Komma und Punkt, '
        'raten 1.000 nie', (tester) async {
      final liste = await _pumpEditor(tester, locale);
      await _tap(tester, find.byKey(const ValueKey('ingredient-add')));
      await _tap(tester, find.byKey(const ValueKey('ingredient-manual')));
      await _tippe(tester, 'ingredient-field-0', 'Mehl');

      for (var feld = 1; feld <= 5; feld++) {
        final key = 'ingredient-field-$feld';
        await _tippe(tester, key, '1.000');
        expect(_inhalt(tester, key), '1.000');
        expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget,
            reason: '$key: 1.000 ist 1 oder 1000');
        expect(_speichernAktiv(tester, l10n.ingredientSave), isFalse,
            reason: key);
        await _tippe(tester, key, feld == 1 ? '100' : '');
      }

      // "1.000,5" is unambiguous: fits the gram bound, not the per-100 g ones.
      await _tippe(tester, 'ingredient-field-3', '1.000,5');
      expect(find.text(l10n.ingredientNumberError('0', '100')), findsOneWidget);
      await _tippe(tester, 'ingredient-field-3', '3,5');
      await _tippe(tester, 'ingredient-field-5', '3.5');
      await _tippe(tester, 'ingredient-field-1', '1.000,5');
      expect(_speichernAktiv(tester, l10n.ingredientSave), isTrue);
      await _tap(tester, find.text(l10n.ingredientSave));

      final mehl = liste.zutaten.single;
      expect(mehl.grams, 1000.5);
      expect(mehl.per100g.proteinG, 3.5);
      expect(mehl.per100g.fatG, 3.5);
    });

    testWidgets('Zutat [$code]: gespeicherte Werte kommen unveraendert zurueck',
        (tester) async {
      // 1.125 g would prefill as "1,125" — ambiguous by the typing rule. The
      // prefill writes it unambiguously and saving without an edit keeps the
      // stored number.
      final liste = await _pumpEditor(
        tester,
        locale,
        zutaten: <RecipeIngredient>[
          RecipeIngredient(
            name: 'Safran',
            grams: 1.125,
            per100g: const RecipeNutrition(
              caloriesKcal: 310,
              proteinG: 11.432,
              carbsG: 65.37,
              fatG: 5.85,
            ),
          ),
        ],
      );
      await _tap(tester, find.byKey(const ValueKey('ingredient-edit-0')));
      expect(
        _inhalt(tester, 'ingredient-field-1'),
        code == 'de' ? '1,1250' : '1.1250',
      );
      expect(
        _inhalt(tester, 'ingredient-field-3'),
        code == 'de' ? '11,4320' : '11.4320',
      );
      expect(
        _inhalt(tester, 'ingredient-field-4'),
        code == 'de' ? '65,37' : '65.37',
      );
      expect(_speichernAktiv(tester, l10n.ingredientSave), isTrue);
      await _tap(tester, find.text(l10n.ingredientSave));
      final safran = liste.zutaten.single;
      expect(safran.grams, 1.125);
      expect(safran.per100g.proteinG, 11.432);
      expect(safran.per100g.carbsG, 65.37);
      expect(safran.per100g.fatG, 5.85);
    });

    testWidgets('Portionen [$code]: 1.000 ist keine Portion', (tester) async {
      final werte = <double?>[];
      await pumpLocalized(
        tester,
        RecipePortionSelector(onChanged: werte.add, showPresets: false),
        locale: locale,
        scrollable: true,
      );
      const feld = 'recipe-portion-field';

      await _tippe(tester, feld, '3,5');
      expect(werte.last, 3.5);
      await _tippe(tester, feld, '3.5');
      expect(werte.last, 3.5);

      await _tippe(tester, feld, '1.000');
      expect(werte.last, isNull, reason: 'frueher still 1 Portion');
      expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget);

      await _tippe(tester, feld, '1.000,5');
      expect(werte.last, isNull, reason: 'eindeutig 1000,5 — ueber 100');
      expect(find.text(l10n.recipeCalcServingsError), findsOneWidget);
    });

    testWidgets('Portionen [$code]: Vorbelegung mit drei Nachkommastellen',
        (tester) async {
      final werte = <double?>[];
      await pumpLocalized(
        tester,
        RecipePortionSelector(initialServings: 2.125, onChanged: werte.add),
        locale: locale,
        scrollable: true,
      );
      expect(
        _inhalt(tester, 'recipe-portion-field'),
        code == 'de' ? '2,1250' : '2.1250',
      );
      expect(find.text(l10n.recipeCalcServingsError), findsNothing);
      expect(werte, isEmpty, reason: 'nur die Vorbelegung, nichts getippt');
      expect(find.textContaining('2125'), findsNothing);
    });
  }
}
