import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import '../support/harness.dart';

// The expanded item's live preview ("= 480 kcal   P 30 g · C 40 g · F 10 g")
// keeps its single line on regular phones and reflows below it once the
// kcal part no longer fits (320 px at 200 % text used to overflow by 71 px).

const _ergebnis = MealAnalysisResult(
  mealName: 'Haferbowl',
  caloriesKcal: 480,
  estimatedGrams: 300,
  kcalPer100G: 160,
  protein: '30 g',
  carbs: '40 g',
  fat: '10 g',
  confidence: 'database',
  portionNotes: '',
);

Future<List<FlutterErrorDetails>> _zeige(
  WidgetTester tester, {
  required Size size,
  required double textScale,
}) =>
    collectOverflows(() async {
      await pumpLocalized(
        tester,
        ListView(
          children: [
            MealSuggestionItem(
              result: _ergebnis,
              expanded: true,
              onTap: () {},
              onAdd: (_) {},
            ),
          ],
        ),
        locale: const Locale('de'),
        textScale: textScale,
        surfaceSize: size,
      );
      await tester.pumpAndSettle();
    });

void main() {
  final kcal = find.byKey(const ValueKey('live-preview-kcal'));
  final makros = find.byKey(const ValueKey('live-preview-macros'));

  testWidgets('regulaeres Handy: kcal und Makros stehen in einer Zeile',
      (tester) async {
    final fehler =
        await _zeige(tester, size: const Size(390, 844), textScale: 1);
    expect(fehler, isEmpty, reason: describeOverflows(fehler));
    expect(tester.getBottomLeft(makros).dy,
        moreOrLessEquals(tester.getBottomLeft(kcal).dy, epsilon: 1));
    expect(tester.getTopLeft(makros).dx,
        greaterThan(tester.getTopRight(kcal).dx));
  });

  testWidgets('320 px bei 200 %: nichts laeuft ueber, Makros darunter',
      (tester) async {
    final fehler =
        await _zeige(tester, size: const Size(320, 1400), textScale: 2);
    expect(fehler, isEmpty, reason: describeOverflows(fehler));
    expect(tester.getTopLeft(makros).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(kcal).dy));
    final text = tester.widget<Text>(makros);
    expect(text.overflow, isNot(TextOverflow.ellipsis),
        reason: 'reflowed macros must stay readable, not be cut');
  });
}
