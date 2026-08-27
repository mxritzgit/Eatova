import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';

import 'support/harness.dart';

// Macro input in the manual entry (Audit 2026-08-14): the digitsOnly
// formatter silently turned "3,5" into 35, persisting a tenfold fat value
// while the calories stayed right, so nothing looked wrong.
// Comma AND dot must pass, and the 0..1000 g bound must then apply to the
// DECIMAL value, not to the digit string.

class _ResultHalter {
  MealAnalysisResult? result;
}

Future<_ResultHalter> _open(WidgetTester tester) async {
  final halter = _ResultHalter();
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: FilledButton(
          key: const ValueKey('open-manual'),
          onPressed: () async {
            halter.result = await showManualMealSheet(context);
          },
          child: const Text('open'),
        ),
      ),
    ),
    // Motion as before the migration.
    reducedMotion: false,
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('open-manual')));
  await tester.pumpAndSettle();
  return halter;
}

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const ValueKey('manual-meal-save')));

Future<void> _tippe(WidgetTester tester, String key, String wert) =>
    tester.enterText(find.byKey(ValueKey(key)), wert);

String _feldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller?.text ?? '';

/// Name, kcal/100 g and portion: without them save stays disabled regardless
/// of the macros.
Future<void> _pflichtfelder(WidgetTester tester) async {
  await _tippe(tester, 'manual-meal-name', 'Hofladen-Butter');
  await _tippe(tester, 'manual-meal-kcal100', '265');
  await _tippe(tester, 'manual-meal-grams', '125');
}

Future<void> _speichern(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('manual-meal-save')));
  await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Komma: „3,5" g Fett bleibt 3,5 und wird nicht 35', (
    tester,
  ) async {
    final halter = await _open(tester);
    await _pflichtfelder(tester);
    await _tippe(tester, 'manual-meal-fat', '3,5');
    await tester.pump();

    expect(
      _feldText(tester, 'manual-meal-fat'),
      '3,5',
      reason: 'der Formatter darf das Dezimalkomma nicht stumm schlucken',
    );

    await _speichern(tester);

    expect(
      halter.result?.fat,
      '4,4 g',
      reason: '3,5 g/100 g auf 125 g sind 4,375 g',
    );
    expect(
      halter.result?.fat,
      isNot('43,8 g'),
      reason: 'digitsOnly hatte aus 3,5 die 35 gemacht — Faktor 10',
    );
    expect(
      halter.result?.caloriesKcal,
      331,
      reason: 'die Kalorien waren nie falsch und bleiben es nicht',
    );
  });

  testWidgets('Punkt: „3.5" ergibt denselben Wert wie „3,5"', (tester) async {
    final halter = await _open(tester);
    await _pflichtfelder(tester);
    await _tippe(tester, 'manual-meal-fat', '3.5');
    await tester.pump();

    expect(_feldText(tester, 'manual-meal-fat'), '3.5');

    await _speichern(tester);

    expect(halter.result?.fat, '4,4 g');
  });

  testWidgets('Bereichspruefung greift auf dem Dezimalwert (0..1000 g)', (
    tester,
  ) async {
    await _open(tester);
    await _pflichtfelder(tester);
    await _tippe(tester, 'manual-meal-carbs', '1200,5');
    await tester.pump();
    expect(
      _saveButton(tester).onPressed,
      isNull,
      reason: '1200,5 g/100 g liegt ueber der DB-Grenze',
    );
    expect(find.text('0–1000 g'), findsOneWidget);

    // The formatter lets several separators through; unparseable input is
    // rejected, not silently bent into shape.
    await _tippe(tester, 'manual-meal-carbs', '3,,5');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull);
    expect(find.text('0–1000 g'), findsOneWidget);

    await _tippe(tester, 'manual-meal-carbs', '12,5');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(find.text('0–1000 g'), findsNothing);
  });

  testWidgets('ganzzahliger Normalfall liefert weiter die Factory-Werte', (
    tester,
  ) async {
    final halter = await _open(tester);
    await _pflichtfelder(tester);
    await _tippe(tester, 'manual-meal-protein', '18');
    await tester.pump();
    await _speichern(tester);

    final referenz = MealAnalysisResult.manualEntry(
      name: 'Hofladen-Butter',
      kcalPer100G: 265,
      grams: 125,
      proteinPer100G: 18,
    );
    final r = halter.result;
    expect(r, isNotNull);
    expect(r!.protein, referenz.protein);
    expect(r.carbs, referenz.carbs);
    expect(r.fat, referenz.fat);
    expect(r.caloriesKcal, referenz.caloriesKcal);
    expect(r.estimatedGrams, referenz.estimatedGrams);
    expect(r.kcalPer100G, referenz.kcalPer100G);
    // Provenance codes and the zero-kcal origin survive the rebuild in _save.
    expect(r.confidence, referenz.confidence);
    expect(r.portionNotes, referenz.portionNotes);
    expect(r.sourceLabel, referenz.sourceLabel);
    expect(r.explicitZeroKcal, referenz.explicitZeroKcal);
  });
}
