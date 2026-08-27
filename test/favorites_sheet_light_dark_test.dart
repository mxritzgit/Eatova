// Light/dark pass for the favorites sheet (feature 2026-08-27), after
// food_sheets_light_dark_test: every combination renders without exception or
// overflow, every text is visible, and the search capsule takes its fill and
// its focus lightening from the tokens (field -> fieldFocus), never from a
// constant.
//
// The old hand-written `for (brightness)` loop is now a `renderMatrix`, which
// checks overflows itself and adds the `en` column the loop never had.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';

import 'support/harness.dart';

const _suche = ValueKey('favorites-sheet-search');

const List<Locale> _beideSprachen = <Locale>[Locale('de'), Locale('en')];

MealAnalysisResult _mahlzeit(String name, {int kcal = 250, String? marke}) {
  return MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: 100,
    kcalPer100G: kcal.toDouble(),
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'database',
    portionNotes: '',
    brand: marke,
  );
}

FavoriteMeal _favorit(MealAnalysisResult result,
        {required DateTime am, bool gepinnt = true}) =>
    FavoriteMeal(
      id: FavoriteMeal.idFor(result),
      result: result,
      addedAt: am,
      pinned: gepinnt,
    );

final List<FavoriteMeal> _zwei = <FavoriteMeal>[
  _favorit(_mahlzeit('Haferdrink', marke: 'Alpro'), am: DateTime(2026, 8, 20)),
  _favorit(_mahlzeit('Skyr', kcal: 90), am: DateTime(2026, 8, 10)),
];

final List<FavoriteMeal> _nurRecents = <FavoriteMeal>[
  _favorit(_mahlzeit('Pizza'), am: DateTime(2026, 8, 26), gepinnt: false),
];

Widget _sheet(List<FavoriteMeal> favorites) => Align(
      alignment: Alignment.bottomCenter,
      child: FavoritesSheet(
        favorites: favorites,
        slot: MealSlot.lunch,
        onAdd: (_, __) => 'id-1',
        onUnpin: (_) {},
      ),
    );

/// The soft capsule around the search field: the nearest AnimatedContainer.
BoxDecoration _kapsel(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find
        .ancestor(
          of: find.byKey(_suche),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return container.decoration! as BoxDecoration;
}

Color? _textfarbe(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).style?.color;

void main() {
  renderMatrix(
    'Das Favoriten-Sheet rendert sauber',
    (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(tester, _sheet(_zwei), settle: true);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('favorites-sheet')), findsOneWidget);
      expect(find.text(c.l10n.foodFavoritesSheetTitle(2)), findsOneWidget);
      expect(find.text(c.l10n.foodFavoritesSheetSubtitle), findsOneWidget);
      expect(find.text('Haferdrink'), findsOneWidget);
      expect(find.text('Skyr'), findsOneWidget);
      expect(find.text(c.l10n.foodFavoritesSearchHint), findsOneWidget,
          reason: 'der Hint des Suchfelds ist sichtbar');

      // Title and hint take their ink from the tokens of THIS mode.
      expect(
        _textfarbe(tester, find.byKey(const ValueKey('favorites-sheet-title'))),
        c.t.ink,
      );
      final feld = tester.widget<TextField>(find.byKey(_suche));
      expect(feld.decoration!.hintStyle!.color, c.t.ink2);
      expect(feld.style!.color, c.t.ink);
    },
    locales: _beideSprachen,
  );

  renderMatrix(
    'Der Leer-Zustand des Favoriten-Sheets rendert sauber',
    (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(tester, _sheet(_nurRecents), settle: true);

      expect(tester.takeException(), isNull);
      expect(find.text(c.l10n.foodFavoritesSheetTitle(0)), findsOneWidget);
      expect(
          find.byKey(const ValueKey('favorites-sheet-empty')), findsOneWidget);
      final hinweis = find.text(c.l10n.foodFavoritesEmptyHint);
      expect(hinweis, findsOneWidget);
      expect(_textfarbe(tester, hinweis), c.t.ink2);
      expect(find.byKey(_suche), findsNothing,
          reason: 'ohne Einträge gibt es nichts zu filtern');
    },
    locales: _beideSprachen,
  );

  renderMatrix(
    'Die Suchkapsel nimmt field aus den Tokens und hellt bei Fokus auf '
    'fieldFocus auf — ohne Rahmen',
    (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(tester, _sheet(_zwei), settle: true);

      expect(_kapsel(tester).color, c.t.field);
      expect(_kapsel(tester).border, isNull, reason: 'kein Hairline-Rahmen');

      // Repo rule: focus is a surface step (field -> fieldFocus), no ring.
      final feld = tester.widget<TextField>(find.byKey(_suche));
      expect(feld.decoration!.enabledBorder, InputBorder.none);
      expect(feld.decoration!.focusedBorder, InputBorder.none);
      expect(feld.cursorColor, c.t.accent);

      await tester.tap(find.byKey(_suche));
      await tester.pumpAndSettle();
      expect(_kapsel(tester).color, c.t.fieldFocus);
      expect(tester.takeException(), isNull);
    },
    locales: _beideSprachen,
  );

  testWidgets('Auf Englisch steht die englische Ueberschrift im Baum',
      (tester) async {
    // Counter-check to the matrices above: they read the same ARB the sheet
    // reads, so a regress in app_en.arb would pass unnoticed. One hard anchor
    // per language proves the title really CHANGES with the language.
    pinPhoneViewport(tester);
    await pumpLocalized(tester, _sheet(_zwei),
        locale: const Locale('en'), settle: true);

    expect(find.text('Favorites (2)'), findsOneWidget);
    expect(find.text('Favoriten (2)'), findsNothing);
    expect(find.text('Search favorites'), findsOneWidget);
  });

  testWidgets('Die Kapselfarbe unterscheidet sich zwischen Hell und Dunkel',
      (tester) async {
    // A hardcoded fill would survive the theme switch unchanged. Not part of
    // the matrix: it COMPARES two cases instead of asserting inside one.
    pinPhoneViewport(tester);
    await pumpLocalized(tester, _sheet(_zwei),
        brightness: Brightness.light, settle: true);
    final hell = _kapsel(tester).color;
    await pumpLocalized(tester, _sheet(_zwei),
        brightness: Brightness.dark, settle: true);
    final dunkel = _kapsel(tester).color;

    expect(hell, isNotNull);
    expect(dunkel, isNotNull);
    expect(hell, isNot(equals(dunkel)),
        reason: 'die Kapsel folgt nicht dem Theme — hardcodierte Farbe?');
    expect(hell, AppTokens.light.field);
    expect(dunkel, AppTokens.dark.field);
  });
}
