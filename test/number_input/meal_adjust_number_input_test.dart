import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// The component adjust sheet: the gram field of each row, and the "add
// component" dialog (grams, kcal whole; three macros decimal). `digitsOnly`
// turned "3,5" into 35 g in the row and the dialog; the macro fields read
// "1.000" as 1 g.

const _posten = MealAnalysisResult(
  mealName: 'Nussmus',
  caloriesKcal: 521,
  estimatedGrams: 100,
  kcalPer100G: 521,
  protein: '20 g',
  carbs: '12 g',
  fat: '45 g',
  confidence: 'Mittel',
  portionNotes: 'Testposten.',
  sourceLabel: 'Foto-KI',
  items: [
    MealComponent(
      name: 'Nussmus',
      grams: 100,
      caloriesKcal: 521,
      kcalPer100G: 521,
      proteinG: 20,
      carbsG: 12,
      fatG: 45,
    ),
  ],
);

class _Ergebnis {
  Object? wert;
}

Future<_Ergebnis> _oeffne(WidgetTester tester, Locale locale) async {
  final ergebnis = _Ergebnis();
  await tester.pumpWidget(
    localizedApp(
      Builder(
        builder: (context) => TextButton(
          key: const ValueKey('open-adjust'),
          onPressed: () async =>
              ergebnis.wert = await showWeightAdjustmentSheet(context, _posten),
          child: const Text('anpassen'),
        ),
      ),
      locale: locale,
      safeArea: false,
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-adjust')));
  await tester.pumpAndSettle();
  return ergebnis;
}

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  final feld = find.byKey(ValueKey(key));
  await tester.ensureVisible(feld);
  await tester.enterText(feld, text);
  await tester.pumpAndSettle();
}

String _inhalt(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

bool _aktiv(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(ValueKey(key))).onPressed != null;

String? _hinweis(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey(key));
  return finder.evaluate().isEmpty ? null : tester.widget<Text>(finder).data;
}

Future<void> _oeffneDialog(WidgetTester tester) async {
  final knopf = find.byKey(const ValueKey('analyse-item-add-button'));
  await tester.ensureVisible(knopf);
  await tester.pumpAndSettle();
  await tester.tap(knopf);
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);
    final code = locale.languageCode;

    testWidgetsRobust(
      'Posten-Gramm [$code]: 3,5 wird nicht zu 35 g, 1.000 wird nicht geraten',
      (tester) async {
        final ergebnis = await _oeffne(tester, locale);
        const feld = 'analyse-item-weight-input-0';
        const hinweis = 'analyse-item-weight-hint-0';

        for (final (eingabe, erwartet) in ganzzahlFaelle(l10n)) {
          await _tippe(tester, feld, eingabe);
          expect(_inhalt(tester, feld), eingabe, reason: eingabe);
          expect(_hinweis(tester, hinweis), erwartet, reason: eingabe);
          expect(_aktiv(tester, 'analyse-save-weight-button'), isFalse,
              reason: eingabe);
        }

        // The reason follows the text while the row stays invalid.
        await _tippe(tester, feld, '12000');
        expect(_hinweis(tester, hinweis), l10n.foodPortionRangeHint(1, 10000));

        await _tippe(tester, feld, '150');
        expect(_hinweis(tester, hinweis), isNull);
        await tester.tap(find.byKey(const ValueKey('analyse-save-weight-button')));
        await tester.pumpAndSettle();
        final posten = ergebnis.wert! as List<MealComponent>;
        expect(posten.single.grams, 150);
      },
    );

    testWidgetsRobust(
      'Bestandteil-Dialog [$code]: ganze Gramm/kcal, Makros mit Komma oder '
      'Punkt',
      (tester) async {
        final ergebnis = await _oeffne(tester, locale);
        await _oeffneDialog(tester);
        await _tippe(tester, 'analyse-add-item-name', 'Honig');
        await _tippe(tester, 'analyse-add-item-grams', '20');
        await _tippe(tester, 'analyse-add-item-kcal', '61');
        expect(_aktiv(tester, 'analyse-add-item-save'), isTrue);

        for (final (feld, hinweis, gueltig) in const <(String, String, String)>[
          ('analyse-add-item-grams', 'analyse-add-item-grams-hint', '20'),
          ('analyse-add-item-kcal', 'analyse-add-item-kcal-hint', '61'),
        ]) {
          for (final (eingabe, erwartet) in ganzzahlFaelle(l10n)) {
            await _tippe(tester, feld, eingabe);
            expect(_inhalt(tester, feld), eingabe, reason: '$feld $eingabe');
            expect(_hinweis(tester, hinweis), erwartet,
                reason: '$feld $eingabe');
            expect(_aktiv(tester, 'analyse-add-item-save'), isFalse,
                reason: '$feld $eingabe');
          }
          await _tippe(tester, feld, gueltig);
        }

        await tester.tap(
          find.byKey(const ValueKey('analyse-add-item-macros-toggle')),
        );
        await tester.pumpAndSettle();
        const makroHinweis = 'analyse-add-item-macro-range-hint';
        await _tippe(tester, 'analyse-add-item-carbs', '1.000');
        expect(_hinweis(tester, makroHinweis), mehrdeutigHinweis(l10n));
        expect(_aktiv(tester, 'analyse-add-item-save'), isFalse);
        await _tippe(tester, 'analyse-add-item-carbs', '1.000,5');
        expect(_hinweis(tester, makroHinweis), l10n.foodMacroRangeHint,
            reason: 'eindeutig 1000,5 g, ueber der 1000-g-Grenze');

        await _tippe(tester, 'analyse-add-item-protein', '0,5');
        await _tippe(tester, 'analyse-add-item-carbs', '16.5');
        await _tippe(tester, 'analyse-add-item-fat', '3,5');
        expect(_hinweis(tester, makroHinweis), isNull);
        await tester.tap(find.byKey(const ValueKey('analyse-add-item-save')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('analyse-save-weight-button')));
        await tester.pumpAndSettle();
        final honig = (ergebnis.wert! as List<MealComponent>).last;
        expect(honig.grams, 20);
        expect(honig.caloriesKcal, 61);
        expect(honig.proteinG, 0.5);
        expect(honig.carbsG, 16.5);
        expect(honig.fatG, 3.5);
      },
    );
  }
}
