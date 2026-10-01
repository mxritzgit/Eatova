// A meal logged into a slot that is already on screen grows in and the
// slot total counts to its new value (motion polish, 2026-10-01). Rows that
// were there at first display do not animate, and the end state carries the
// same data as before.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';

import '../../support/harness.dart';

MealAnalysisResult _result(String name, int kcal) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: 200,
  kcalPer100G: kcal / 2,
  protein: '10 g',
  carbs: '20 g',
  fat: '5 g',
  confidence: 'high',
  portionNotes: '',
);

final LoggedMeal _oats = LoggedMeal(
  id: 'm1',
  result: _result('Oats', 320),
  loggedAt: DateTime(2026, 9, 28, 8),
  forcedSlot: MealSlot.breakfast,
);

final LoggedMeal _skyr = LoggedMeal(
  id: 'm2',
  result: _result('Skyr', 210),
  loggedAt: DateTime(2026, 9, 28, 8, 30),
  forcedSlot: MealSlot.breakfast,
);

Widget _card(List<LoggedMeal> meals) => SizedBox(
  width: 360,
  child: DiaryMealCard(
    slot: MealSlot.breakfast,
    entries: <DiaryEntry>[
      for (var i = 0; i < meals.length; i++) DiaryEntry(meals[i], i),
    ],
    onAddToSlot: (_) {},
    onRemoveMeal: (_) {},
  ),
);

Future<void> _pump(
  WidgetTester tester,
  List<LoggedMeal> meals, {
  bool reducedMotion = false,
}) => pumpLocalized(
  tester,
  _card(meals),
  locale: const Locale('en'),
  reducedMotion: reducedMotion,
);

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

double _addRowTop(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const ValueKey('food-slot-add-breakfast'))).dy;

String _total(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const ValueKey('food-slot-kcal-breakfast')),
  );
  return text.data ?? text.textSpan!.toPlainText();
}

void main() {
  testWidgets(
    'ein neu geloggter Eintrag waechst herein, die Summe zaehlt mit',
    (tester) async {
      await _pump(tester, [_oats]);
      await tester.pumpAndSettle();
      final before = _addRowTop(tester);
      expect(_total(tester), '320');

      await _pump(tester, [_oats, _skyr]);
      // The new row starts without height: nothing below it jumps.
      expect(_addRowTop(tester), before);

      await _frames(tester, 6);
      final mid = _addRowTop(tester);
      expect(mid, greaterThan(before));
      expect(int.parse(_total(tester)), inExclusiveRange(320, 530));

      await tester.pumpAndSettle();
      final after = _addRowTop(tester);
      expect(mid, lessThan(after));
      // The end state carries the data: both rows, the new total.
      expect(find.text('Oats'), findsOneWidget);
      expect(find.text('Skyr'), findsOneWidget);
      expect(_total(tester), '530');
      expect(
        tester
            .getSize(find.byKey(const ValueKey('food-history-entry-1')))
            .height,
        after - before,
      );
    },
  );

  testWidgets('Eintraege der ersten Anzeige stehen sofort da, und die '
      'zaehlende Summe verschiebt nichts', (tester) async {
    await _pump(tester, [_oats, _skyr]);
    final first = _addRowTop(tester);
    final header = tester.getSize(
      find.byKey(const ValueKey('food-slot-toggle-breakfast')),
    );
    // While the total counts up from 0 the header keeps its resting size:
    // a narrower running figure must not unwrap the meta line for a frame.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(_addRowTop(tester), first);
      expect(
        tester.getSize(
          find.byKey(const ValueKey('food-slot-toggle-breakfast')),
        ),
        header,
      );
    }
    expect(int.parse(_total(tester)), inExclusiveRange(0, 530));
    await tester.pumpAndSettle();
    expect(_addRowTop(tester), first);
    expect(_total(tester), '530');
    expect(find.text('Skyr'), findsOneWidget);
  });

  testWidgets('reduzierte Bewegung: der neue Eintrag steht sofort da', (
    tester,
  ) async {
    await _pump(tester, [_oats], reducedMotion: true);
    final before = _addRowTop(tester);
    await _pump(tester, [_oats, _skyr], reducedMotion: true);
    await tester.pump();
    final rowHeight = tester
        .getSize(find.byKey(const ValueKey('food-history-entry-1')))
        .height;
    expect(_addRowTop(tester), before + rowHeight);
    expect(_total(tester), '530');
  });
}
