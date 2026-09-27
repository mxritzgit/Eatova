import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/recipes/recipe_portion_selector.dart';

import '../support/harness.dart';

// The servings presets used to read "1 Portionen" / "1 servings" and
// "0.5 Portionen" under German, and the field prefilled "1.5" in a German UI.
// Labels now agree in number and use the locale's decimal separator, and the
// prefilled text still parses back to the same value.

Future<List<double?>> _pump(
  WidgetTester tester, {
  required Locale locale,
  double initial = 1,
}) async {
  final changes = <double?>[];
  await pumpLocalized(
    tester,
    RecipePortionSelector(initialServings: initial, onChanged: changes.add),
    locale: locale,
    brightness: Brightness.light,
    scrollable: true,
  );
  return changes;
}

String _field(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('recipe-portion-field')))
    .controller!
    .text;

void main() {
  testWidgets('Deutsch: Einzahl, Dezimalkomma und Vorbelegung', (tester) async {
    final changes = await _pump(tester, locale: const Locale('de'), initial: 1.5);
    expect(_field(tester), '1,5');
    for (final label in ['0,5 Portionen', '1 Portion', '2 Portionen']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('1 Portionen'), findsNothing);

    await tester.tap(find.text('0,5 Portionen'));
    await tester.pump();
    expect(_field(tester), '0,5');
    expect(changes.last, 0.5, reason: 'das Komma wird als Dezimalzeichen gelesen');
  });

  testWidgets('English: singular and decimal point', (tester) async {
    final changes = await _pump(tester, locale: const Locale('en'), initial: 1.5);
    expect(_field(tester), '1.5');
    for (final label in ['0.5 servings', '1 serving', '2 servings']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('1 serving'));
    await tester.pump();
    expect(_field(tester), '1');
    expect(changes.last, 1);
  });
}
