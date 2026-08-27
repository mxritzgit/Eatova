// Light/dark pass for the favorites sheet (feature 2026-08-27), after
// food_sheets_light_dark_test: both modes render without exception or
// overflow, every text is visible, and the search capsule takes its fill and
// its focus lightening from the tokens (tile -> surf), never from a constant.
// Overflows are COLLECTED, not swallowed.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';

const Size _viewport = Size(393, 852);
const _suche = ValueKey('favorites-sheet-search');

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

/// The tokens the sheet is expected to draw with under [brightness].
AppTokens _tokens(Brightness brightness) =>
    buildEatovaTheme(brightness).extension<AppTokens>()!;

/// Pumps the sheet in the Eatova theme and returns the errors reported.
Future<List<Object>> _pump(
  WidgetTester tester,
  Brightness brightness,
  List<FavoriteMeal> favorites,
) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _viewport * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final fehler = <Object>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    fehler.add(details.exception);
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: FavoritesSheet(
            favorites: favorites,
            slot: MealSlot.lunch,
            onAdd: (_, __) => 'id-1',
            onUnpin: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fehler;
}

/// The soft capsule around the search field: the nearest AnimatedContainer.
BoxDecoration _kapsel(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find.ancestor(of: find.byKey(_suche), matching: find.byType(AnimatedContainer)).first,
  );
  return container.decoration! as BoxDecoration;
}

Color? _textfarbe(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).style?.color;

void main() {
  for (final brightness in Brightness.values) {
    final t = _tokens(brightness);

    testWidgets('Das Favoriten-Sheet rendert in $brightness sauber',
        (tester) async {
      final fehler = await _pump(tester, brightness, _zwei);

      expect(tester.takeException(), isNull);
      expect(fehler, isEmpty);
      expect(find.byKey(const ValueKey('favorites-sheet')), findsOneWidget);
      expect(find.text('Favoriten (2)'), findsOneWidget);
      expect(find.textContaining('Antippen zum Aufklappen'), findsOneWidget);
      expect(find.text('Haferdrink'), findsOneWidget);
      expect(find.text('Skyr'), findsOneWidget);
      expect(find.text('Favoriten durchsuchen'), findsOneWidget,
          reason: 'der Hint des Suchfelds ist sichtbar');

      // Title and hint take their ink from the tokens of THIS mode.
      expect(
        _textfarbe(tester, find.byKey(const ValueKey('favorites-sheet-title'))),
        t.ink,
      );
      final feld = tester.widget<TextField>(find.byKey(_suche));
      expect(feld.decoration!.hintStyle!.color, t.ink2);
      expect(feld.style!.color, t.ink);
    });

    testWidgets('Der Leer-Zustand rendert in $brightness sauber',
        (tester) async {
      final fehler = await _pump(tester, brightness, _nurRecents);

      expect(tester.takeException(), isNull);
      expect(fehler, isEmpty);
      expect(find.text('Favoriten (0)'), findsOneWidget);
      expect(find.byKey(const ValueKey('favorites-sheet-empty')), findsOneWidget);
      final hinweis = find.textContaining('Noch keine Favoriten');
      expect(hinweis, findsOneWidget);
      expect(_textfarbe(tester, hinweis), t.ink2);
      expect(find.byKey(_suche), findsNothing,
          reason: 'ohne Einträge gibt es nichts zu filtern');
    });

    testWidgets(
        'Die Suchkapsel nimmt in $brightness tile aus den Tokens und hellt '
        'bei Fokus auf surf auf — ohne Rahmen', (tester) async {
      await _pump(tester, brightness, _zwei);

      expect(_kapsel(tester).color, t.tile);
      expect(_kapsel(tester).border, isNull, reason: 'kein Hairline-Rahmen');

      // Repo rule: focus is a surface step (tile -> surf), no focus ring.
      final feld = tester.widget<TextField>(find.byKey(_suche));
      expect(feld.decoration!.enabledBorder, InputBorder.none);
      expect(feld.decoration!.focusedBorder, InputBorder.none);
      expect(feld.cursorColor, t.accent);

      await tester.tap(find.byKey(_suche));
      await tester.pumpAndSettle();
      expect(_kapsel(tester).color, t.surf);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Die Kapselfarbe unterscheidet sich zwischen Hell und Dunkel',
      (tester) async {
    // A hardcoded fill would survive the theme switch unchanged.
    await _pump(tester, Brightness.light, _zwei);
    final hell = _kapsel(tester).color;
    await _pump(tester, Brightness.dark, _zwei);
    final dunkel = _kapsel(tester).color;

    expect(hell, isNotNull);
    expect(dunkel, isNotNull);
    expect(hell, isNot(equals(dunkel)),
        reason: 'die Kapsel folgt nicht dem Theme — hardcodierte Farbe?');
    expect(hell, _tokens(Brightness.light).tile);
    expect(dunkel, _tokens(Brightness.dark).tile);
  });
}
