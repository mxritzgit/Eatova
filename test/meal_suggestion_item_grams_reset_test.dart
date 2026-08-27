import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import 'support/harness.dart';

// Review B of the favorites sheet (2026-08-27): rows are keyed by INDEX, so
// after an unpin/filter the State of row 0 receives the NEXT row's result.
// `didUpdateWidget` compared grams only, and two 100 g rows carried a
// user-edited 110 g onto the neighbour — a wrong kcal figure in the log. Rule
// pinned here: a different result instance resets the gram stepper.

MealAnalysisResult _mahlzeit(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 250,
      estimatedGrams: 100,
      kcalPer100G: 250,
      protein: '-',
      carbs: '-',
      fat: '-',
      confidence: 'database',
      portionNotes: '',
    );

final _haferdrink = _mahlzeit('Haferdrink');
final _skyr = _mahlzeit('Skyr');

Widget _liste(List<MealAnalysisResult> zeilen, {required String? offen}) {
  return ListView(
    children: [
      for (var i = 0; i < zeilen.length; i++)
        MealSuggestionItem(
          // Index keys on purpose: that is what the sheets use.
          key: ValueKey('row-$i'),
          result: zeilen[i],
          expanded: zeilen[i].mealName == offen,
          onTap: () {},
          onAdd: (_) {},
        ),
    ],
  );
}

Future<void> _pumpListe(WidgetTester tester, Widget liste) =>
    pumpLocalized(tester, liste, reducedMotion: false, safeArea: false);

String _grammText(WidgetTester tester, String rowKey) {
  final feld = tester.widget<TextField>(find.descendant(
    of: find.byKey(ValueKey(rowKey)),
    matching: find.byType(TextField),
  ));
  return feld.controller!.text;
}

void main() {
  testWidgets(
      'nach dem Entfernen von Zeile 0 zeigt die nachrueckende Zeile IHRE Gramm, '
      'nicht die bearbeiteten der entfernten', (tester) async {
    await _pumpListe(tester, _liste([_haferdrink, _skyr], offen: 'Haferdrink'));
    await tester.pumpAndSettle();
    expect(_grammText(tester, 'row-0'), '100');

    // Bump the oat drink to 110 g via the stepper.
    final plus = find.descendant(
      of: find.byKey(const ValueKey('row-0')),
      matching: find.byIcon(Icons.add_rounded),
    );
    await tester.tap(plus.first);
    await tester.pumpAndSettle();
    expect(_grammText(tester, 'row-0'), isNot('100'),
        reason: 'der Stepper muss die Gramm veraendert haben');

    // Row 0 disappears (unpin); Skyr moves into the same index key.
    await _pumpListe(tester, _liste([_skyr], offen: 'Skyr'));
    await tester.pumpAndSettle();

    expect(find.text('Skyr'), findsOneWidget);
    expect(_grammText(tester, 'row-0'), '100',
        reason: 'meal_suggestion_item.dart didUpdateWidget: bei neuer '
            'Result-Instanz muessen die Gramm auf deren estimatedGrams '
            'zurueckspringen');
  });

  testWidgets('ein Rebuild mit DERSELBEN Result-Instanz behaelt die Gramm',
      (tester) async {
    await _pumpListe(tester, _liste([_haferdrink], offen: 'Haferdrink'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();
    final bearbeitet = _grammText(tester, 'row-0');
    expect(bearbeitet, isNot('100'));

    // Parent rebuild (e.g. a setState elsewhere in the sheet) with the same
    // objects must not throw away what the user typed.
    await _pumpListe(tester, _liste([_haferdrink], offen: 'Haferdrink'));
    await tester.pumpAndSettle();
    expect(_grammText(tester, 'row-0'), bearbeitet);
  });
}
