import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import '../support/harness.dart';

// The expanded item's live preview: the kcal as the hero number with the
// macro legend below it, both left of the round add button (design polish
// 2026-10-02; it used to be one "= 480 kcal   P 30 g · ..." line). Nothing
// may overflow or be cut, also at 320 px and 200 % text (once 71 px over).

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

  testWidgets('regulaeres Handy: Makros unter den kcal, links vom Plus',
      (tester) async {
    final fehler =
        await _zeige(tester, size: const Size(390, 844), textScale: 1);
    expect(fehler, isEmpty, reason: describeOverflows(fehler));
    expect(tester.getTopLeft(makros).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(kcal).dy));
    expect(tester.getTopLeft(makros).dx,
        moreOrLessEquals(tester.getTopLeft(kcal).dx, epsilon: 1));
    expect(tester.getTopRight(makros).dx,
        lessThan(tester.getTopLeft(find.byType(FilledButton)).dx));
  });

  testWidgets('320 px bei 200 %: nichts laeuft ueber, Makros darunter',
      (tester) async {
    final fehler =
        await _zeige(tester, size: const Size(320, 1400), textScale: 2);
    expect(fehler, isEmpty, reason: describeOverflows(fehler));
    expect(tester.getTopLeft(makros).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(kcal).dy));
    for (final text in tester.widgetList<Text>(
      find.descendant(of: makros, matching: find.byType(Text)),
    )) {
      expect(text.overflow, isNot(TextOverflow.ellipsis),
          reason: 'reflowed macros must stay readable, not be cut');
    }
    expect(find.descendant(of: makros, matching: find.byType(Text)),
        findsNWidgets(3));
  });
}
