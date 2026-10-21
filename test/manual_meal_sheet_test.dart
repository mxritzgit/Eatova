import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/design/design.dart'
    show FieldCapsule, PrimaryActionButton;
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';

import 'support/harness.dart';

// Manual entry: form per 100 g plus portion. Human input is REJECTED, not
// clamped — save locks and the field shows the range error.
//
// Macro input (audit 2026-08-14): the digitsOnly formatter silently turned
// "3,5" into 35, persisting a tenfold fat value while the calories stayed
// right, so nothing looked wrong. Comma AND dot must pass, and the 0..100 g
// bound must then apply to the DECIMAL value, not to the digit string. The
// bound is per 100 g of food (PlausibilityLimits.macroPer100GMax): it used to
// be the per-meal DB bound of 1000 g, which let an impossible 150 g of protein
// per 100 g through.

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
  );
  await tester.tap(find.byKey(const ValueKey('open-manual')));
  await tester.pumpAndSettle();
  return halter;
}

PrimaryActionButton _saveButton(WidgetTester tester) => tester
    .widget<PrimaryActionButton>(find.byKey(const ValueKey('manual-meal-save')));

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
  testWidgets('Save sperrt, bis Name + kcal/100 g + Gramm gültig sind', (
    tester,
  ) async {
    await _open(tester);
    expect(
      _saveButton(tester).onTap,
      isNull,
      reason: 'leeres Formular (Gramm ist mit 100 vorbelegt) sperrt',
    );

    await _tippe(tester, 'manual-meal-name', 'Bauern-Mozzarella');
    await _tippe(tester, 'manual-meal-kcal100', '2000');
    await tester.pump();
    expect(
      _saveButton(tester).onTap,
      isNull,
      reason: '2000 kcal/100 g ist physikalisch unmöglich',
    );
    expect(
      find.text('0–900 kcal'),
      findsOneWidget,
      reason: 'Ablehnen mit Bereichs-Fehler statt stiller Klemmung',
    );

    await _tippe(tester, 'manual-meal-kcal100', '265');
    await tester.pump();
    expect(_saveButton(tester).onTap, isNotNull);
  });

  testWidgets('liefert das gerechnete Ergebnis samt Vorschau zurück', (
    tester,
  ) async {
    final halter = await _open(tester);
    await _tippe(tester, 'manual-meal-name', 'Bauern-Mozzarella');
    await _tippe(tester, 'manual-meal-kcal100', '265');
    await _tippe(tester, 'manual-meal-grams', '125');
    await _tippe(tester, 'manual-meal-protein', '18');
    await tester.pump();

    expect(find.byKey(const ValueKey('manual-meal-computed')), findsOneWidget);
    expect(find.text('= 331 kcal für 125 g'), findsOneWidget);

    await _speichern(tester);

    final r = halter.result;
    expect(r, isNotNull);
    expect(r!.mealName, 'Bauern-Mozzarella');
    expect(r.caloriesKcal, 331);
    expect(r.estimatedGrams, 125);
    expect(r.protein, '22,5 g');
    expect(r.carbs, '-');
    expect(r.sourceLabel, 'manual');
    expect(r.explicitZeroKcal, isFalse);

    // The sheet rebuilds the result in _save: it must match the factory
    // field for field, provenance codes included.
    final referenz = MealAnalysisResult.manualEntry(
      name: 'Bauern-Mozzarella',
      kcalPer100G: 265,
      grams: 125,
      proteinPer100G: 18,
    );
    expect(r.protein, referenz.protein);
    expect(r.carbs, referenz.carbs);
    expect(r.fat, referenz.fat);
    expect(r.caloriesKcal, referenz.caloriesKcal);
    expect(r.kcalPer100G, referenz.kcalPer100G);
    expect(r.confidence, referenz.confidence);
    expect(r.portionNotes, referenz.portionNotes);
    expect(r.sourceLabel, referenz.sourceLabel);
  });

  testWidgets('0 kcal (Wasser) ist speicherbar und trägt explicitZeroKcal', (
    tester,
  ) async {
    final halter = await _open(tester);
    await _tippe(tester, 'manual-meal-name', 'Wasser');
    await _tippe(tester, 'manual-meal-kcal100', '0');
    await _tippe(tester, 'manual-meal-grams', '500');
    await tester.pump();
    expect(_saveButton(tester).onTap, isNotNull);

    await _speichern(tester);

    expect(halter.result?.caloriesKcal, 0);
    expect(halter.result?.explicitZeroKcal, isTrue);
  });

  // Review 2026-10-04: 2 kcal/100 g at 20 g rounds to 0 kcal. Without the
  // marker the logged entry read as the legacy "unknown" sentinel: the Food
  // tab called it unloggable right after logging it, and its recent could
  // not be added again.
  testWidgets('eine auf 0 kcal gerundete Portion trägt explicitZeroKcal', (
    tester,
  ) async {
    final halter = await _open(tester);
    await _tippe(tester, 'manual-meal-name', 'Kräutertee');
    await _tippe(tester, 'manual-meal-kcal100', '2');
    await _tippe(tester, 'manual-meal-grams', '20');
    await tester.pump();

    await _speichern(tester);

    expect(halter.result?.caloriesKcal, 0);
    expect(halter.result?.kcalPer100G, 2);
    expect(halter.result?.explicitZeroKcal, isTrue);
  });

  // Final review B-I1: the theme's text height once shrank the dense 16 px
  // name field to 43 px. The whole capsule is the tap target.
  testWidgets('das Namensfeld bleibt mindestens 44 px hoch', (tester) async {
    await _open(tester);
    final capsule = find.ancestor(
      of: find.byKey(const ValueKey('manual-meal-name')),
      matching: find.byType(FieldCapsule),
    );
    expect(tester.getSize(capsule.first).height, greaterThanOrEqualTo(44));
  });

  testWidgets('Abbrechen liefert null', (tester) async {
    final halter = await _open(tester);
    // Close the sheet by tapping the barrier above it.
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(halter.result, isNull);
  });

  group('Makros mit Dezimalstelle', () {
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
        reason: '3,5 g/100 g auf 125 g sind 4,375 g — digitsOnly machte '
            'daraus 43,8 g',
      );
      expect(
        halter.result?.caloriesKcal,
        331,
        reason: 'die Kalorien waren nie falsch und bleiben es nicht',
      );
    });

    testWidgets('Punkt: „3.5" ergibt denselben Wert wie „3,5"', (
      tester,
    ) async {
      final halter = await _open(tester);
      await _pflichtfelder(tester);
      await _tippe(tester, 'manual-meal-fat', '3.5');
      await tester.pump();

      expect(_feldText(tester, 'manual-meal-fat'), '3.5');

      await _speichern(tester);

      expect(halter.result?.fat, '4,4 g');
    });

    // A small portion saved and later reused (recent, favorite): the typed
    // values per 100 g carry the new portion, not its rounded "0,2 g".
    testWidgets('eine kleine Portion wiederverwendet rechnet mit dem Etikett', (
      tester,
    ) async {
      final halter = await _open(tester);
      await _tippe(tester, 'manual-meal-name', 'Joghurt');
      await _tippe(tester, 'manual-meal-kcal100', '60');
      await _tippe(tester, 'manual-meal-grams', '5');
      await _tippe(tester, 'manual-meal-protein', '3,5');
      await _tippe(tester, 'manual-meal-fat', '3,8');
      await tester.pump();
      await _speichern(tester);

      final saved = halter.result!;
      expect(saved.protein, '0,2 g');
      expect(saved.fat, '0,2 g');
      final reused = saved.adjustedToGrams(200);
      expect(reused.protein, '7 g', reason: 'nicht 0,2 g mal 40 = 8 g');
      expect(reused.fat, '7,6 g', reason: 'nicht 8 g');
    });

    testWidgets('Bereichspruefung greift auf dem Dezimalwert (0..100 g)', (
      tester,
    ) async {
      await _open(tester);
      await _pflichtfelder(tester);
      await _tippe(tester, 'manual-meal-carbs', '1200,5');
      await tester.pump();
      expect(
        _saveButton(tester).onTap,
        isNull,
        reason: '1200,5 g/100 g liegt ueber der DB-Grenze',
      );
      expect(find.text('0–100 g'), findsOneWidget);

      // Below the old per-meal bound, above what 100 g of food can hold.
      await _tippe(tester, 'manual-meal-carbs', '150');
      await tester.pump();
      expect(
        _saveButton(tester).onTap,
        isNull,
        reason: '150 g Kohlenhydrate in 100 g Lebensmittel gibt es nicht',
      );
      expect(find.text('0–100 g'), findsOneWidget);

      // Several separators reach the validator; unparseable input is
      // rejected, not silently bent into shape.
      await _tippe(tester, 'manual-meal-carbs', '3,,5');
      await tester.pump();
      expect(_saveButton(tester).onTap, isNull);
      expect(find.text('0–100 g'), findsOneWidget);

      await _tippe(tester, 'manual-meal-carbs', '12,5');
      await tester.pump();
      expect(_saveButton(tester).onTap, isNotNull);
      expect(find.text('0–100 g'), findsNothing);

      await _tippe(tester, 'manual-meal-carbs', '100');
      await tester.pump();
      expect(
        _saveButton(tester).onTap,
        isNotNull,
        reason: '100 g/100 g (reiner Zucker) ist die inklusive Grenze',
      );
    });
  });
}
