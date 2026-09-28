import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// Manual entry: kcal/100 g and the portion are whole numbers (the factory takes
// ints), the three macros per 100 g are decimals. `digitsOnly` on the whole
// fields turned "3,5" into 35 kcal/100 g or 35 g; the decimal fields read
// "1.000" as 1 g.

class _Ergebnis {
  MealAnalysisResult? wert;
}

Future<_Ergebnis> _oeffne(WidgetTester tester, Locale locale) async {
  final ergebnis = _Ergebnis();
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: FilledButton(
          key: const ValueKey('open-manual'),
          onPressed: () async {
            ergebnis.wert = await showManualMealSheet(context);
          },
          child: const Text('open'),
        ),
      ),
    ),
    locale: locale,
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('open-manual')));
  await tester.pumpAndSettle();
  return ergebnis;
}

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  final feld = find.byKey(ValueKey(key));
  await tester.ensureVisible(feld);
  await tester.enterText(feld, text);
  await tester.pump();
}

String _inhalt(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

bool _speichernAktiv(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('manual-meal-save')))
        .onPressed !=
    null;

Future<void> _pflicht(WidgetTester tester) async {
  await _tippe(tester, 'manual-meal-name', 'Hofladen-Butter');
  await _tippe(tester, 'manual-meal-kcal100', '265');
  await _tippe(tester, 'manual-meal-grams', '100');
}

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);
    final code = locale.languageCode;

    testWidgetsRobust(
      'Manuell [$code]: kcal/100 g und Portion bleiben ganze Zahlen',
      (tester) async {
        await _oeffne(tester, locale);
        await _pflicht(tester);
        expect(_speichernAktiv(tester), isTrue);

        for (final (key, gueltig) in const <(String, String)>[
          ('manual-meal-kcal100', '265'),
          ('manual-meal-grams', '100'),
        ]) {
          for (final (eingabe, hinweis) in ganzzahlFaelle(l10n)) {
            await _tippe(tester, key, eingabe);
            expect(_inhalt(tester, key), eingabe, reason: '$key $eingabe');
            expect(find.text(hinweis), findsOneWidget, reason: '$key $eingabe');
            expect(_speichernAktiv(tester), isFalse, reason: '$key $eingabe');
          }
          await _tippe(tester, key, gueltig);
        }
        expect(_speichernAktiv(tester), isTrue);
      },
    );

    testWidgetsRobust(
      'Manuell [$code]: Makros pro 100 g lesen Komma und Punkt, raten nie',
      (tester) async {
        final ergebnis = await _oeffne(tester, locale);
        await _pflicht(tester);

        for (final key in const <String>[
          'manual-meal-protein',
          'manual-meal-carbs',
          'manual-meal-fat',
        ]) {
          await _tippe(tester, key, '1.000');
          expect(_inhalt(tester, key), '1.000');
          expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget,
              reason: '$key: 1.000 ist 1 g oder 1000 g');
          expect(_speichernAktiv(tester), isFalse, reason: key);

          await _tippe(tester, key, '1.000,5');
          expect(find.text('0–100 g'), findsOneWidget,
              reason: '$key: eindeutig 1000,5 g, ueber 100 g/100 g');
          expect(_speichernAktiv(tester), isFalse, reason: key);
          await _tippe(tester, key, '');
        }

        await _tippe(tester, 'manual-meal-protein', '3,5');
        await _tippe(tester, 'manual-meal-fat', '3.5');
        expect(_speichernAktiv(tester), isTrue);
        final speichern = find.byKey(const ValueKey('manual-meal-save'));
        await tester.ensureVisible(speichern);
        await tester.tap(speichern);
        await tester.pumpAndSettle();

        // 3.5 g per 100 g on a 100 g portion.
        expect(ergebnis.wert?.protein, '3,5 g');
        expect(ergebnis.wert?.fat, '3,5 g');
        expect(ergebnis.wert?.estimatedGrams, 100);
      },
    );
  }
}
