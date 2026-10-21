// Rezepte-Tab, Fix-Lauf 2026-08-27 (F6-09/F8-03): Suchfeld und Sheet-Felder
// sind RAHMENLOS — weiche Kapsel mit Schatten, Fokus = Flächen-Aufhellung,
// Fehler = Danger-Tönung plus Textzeile.
//
// Only the light palette: the capsule's colours per palette are FieldCapsule's
// own contract (widgets/design/fixlauf_h_design_system_test.dart); here only
// that the recipe fields use it. The hero's readability lives in
// recipes_design_test.dart, the discard dialog's actions in
// widgets/design/dialogs_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import '../support/harness.dart';
import '../support/recipe_navigation.dart';

/// The recipes screen in the tab's own padding.
Future<void> _pumpApp(WidgetTester tester, Brightness brightness) =>
    pumpLocalized(
      tester,
      RecipesScreen(
        onAddMeal: (MealAnalysisResult _, MealSlot __) {},
      ),
      reducedMotion: false,
      brightness: brightness,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    );

void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);
}

/// Die Kapsel eines Feldes: der nächste [AnimatedContainer] über dem
/// [TextField] mit [key].
BoxDecoration _kapsel(WidgetTester tester, String key) {
  final container = find
      .ancestor(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(AnimatedContainer),
      )
      .first;
  return tester.widget<AnimatedContainer>(container).decoration!
      as BoxDecoration;
}

Future<void> _openSheet(WidgetTester tester) => openRecipeCreateSheet(tester);

void main() {
  for (final (modus, brightness, t) in <(String, Brightness, AppTokens)>[
    ('Light', Brightness.light, AppTokens.light),
  ]) {
    group('$modus-Modus', () {
      testWidgets('Suchfeld: kein Rahmen, weicher Schatten, Fokus hellt auf',
          (tester) async {
        _pinViewport(tester);
        await _pumpApp(tester, brightness);
        await tester.pumpAndSettle();

        final ruhe = _kapsel(tester, 'recipes-search-input');
        expect(ruhe.border, isNull, reason: 'Hairline-Rahmen sind verboten.');
        expect(ruhe.boxShadow, isNotEmpty);
        expect(ruhe.color, t.field);

        await tester.tap(find.byKey(const ValueKey('recipes-search-input')));
        await tester.pump();
        await tester.pump();

        expect(_kapsel(tester, 'recipes-search-input').color, t.fieldFocus,
            reason: 'Fokus = Flächen-Aufhellung, kein Fokusring.');
        expect(_kapsel(tester, 'recipes-search-input').border, isNull);
      });

      testWidgets('Sheet-Felder: rahmenlos, Fehler = Danger-Tönung + Text',
          (tester) async {
        _pinViewport(tester);
        await _pumpApp(tester, brightness);
        await tester.pumpAndSettle();
        await _openSheet(tester);

        for (final key in const <String>[
          'recipe-create-name',
          'recipe-create-portion',
          'recipe-create-kcal',
          'recipe-create-grams',
          'recipe-create-protein',
          'recipe-create-carbs',
          'recipe-create-fat',
          'recipe-create-ingredients',
        ]) {
          final kapsel = _kapsel(tester, key);
          expect(kapsel.border, isNull, reason: key);
          expect(kapsel.boxShadow, isNotEmpty, reason: key);
          expect(kapsel.color, t.field, reason: key);
        }

        await tester.enterText(
          find.byKey(const ValueKey('recipe-create-kcal')),
          '50000',
        );
        await tester.pumpAndSettle();

        final fehler = _kapsel(tester, 'recipe-create-kcal');
        expect(fehler.border, isNull);
        expect(
          fehler.color,
          t.fieldError,
          reason: 'Fehler als Tönung der Fläche, nicht als roter Rand.',
        );
        expect(find.text('1–10000 kcal'), findsOneWidget);
      });
    });
  }
}
