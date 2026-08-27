// A11y of the favorites sheet (feature 2026-08-27): what heart, add, search
// and clear SAY to a screen reader (tooltip / label / hint), the title as a
// header, the 44 pt tap floor for clear and the shared 40 pt floor for the
// heart. `getSemantics` walks
// UP the render tree, so the text field is found via a semantics finder.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';

const _titel = ValueKey('favorites-sheet-title');
const _suche = ValueKey('favorites-sheet-search');
const _clear = ValueKey('favorites-sheet-search-clear');
const _herz0 = ValueKey('favorites-sheet-fav-0');
const _add0 = ValueKey('favorites-sheet-add-0');
const _zeile0 = ValueKey('favorites-sheet-item-0');

/// Apple HIG floor; Material asks for 48.
const double _mindestTap = 44;

MealAnalysisResult _mahlzeit(String name, {String? marke}) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 250,
      estimatedGrams: 100,
      kcalPer100G: 250,
      protein: '-',
      carbs: '-',
      fat: '-',
      confidence: 'database',
      portionNotes: '',
      brand: marke,
    );

FavoriteMeal _favorit(MealAnalysisResult result, {required DateTime am}) =>
    FavoriteMeal(
      id: FavoriteMeal.idFor(result),
      result: result,
      addedAt: am,
      pinned: true,
    );

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: FavoritesSheet(
          favorites: [
            _favorit(_mahlzeit('Haferdrink', marke: 'Alpro'),
                am: DateTime(2026, 8, 20)),
            _favorit(_mahlzeit('Skyr'), am: DateTime(2026, 8, 10)),
          ],
          slot: MealSlot.snack,
          onAdd: (_, __) => 'id',
          onUnpin: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The one text-field node in the tree (rows are collapsed, so the gram
/// field of MealSuggestionItem is not mounted).
SemanticsNode _textfeldKnoten() => find.semantics
    .byPredicate((node) => node.flagsCollection.isTextField)
    .evaluate()
    .single;

void main() {
  // The handle is disposed inside the body: the end-of-test check runs before
  // tearDowns, so addTearDown would report it as leaked.
  testWidgets('Herz ist eine Schaltfläche und sagt „Aus Favoriten entfernen"',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);

    expect(
      tester.getSemantics(find.byKey(_herz0)),
      isSemantics(
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        tooltip: 'Aus Favoriten entfernen',
      ),
    );
    handle.dispose();
  });

  testWidgets('Hinzufügen ist eine Schaltfläche mit dem Label „Hinzufügen"',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await tester.tap(find.byKey(_zeile0));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(_add0)),
      isSemantics(
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        label: 'Hinzufügen',
      ),
    );
    handle.dispose();
  });

  testWidgets('Suchfeld ist ein Textfeld und nennt „Favoriten durchsuchen"',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);

    final knoten = _textfeldKnoten();
    expect(
      '${knoten.label} ${knoten.hint}',
      contains('Favoriten durchsuchen'),
      reason: 'der Hint muss dem Screenreader als Label oder Hint vorliegen '
          '(label=„${knoten.label}", hint=„${knoten.hint}")',
    );
    handle.dispose();
  });

  testWidgets('Clear-Button erscheint bei Eingabe, sagt „Suche leeren" und leert',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    expect(find.byKey(_clear), findsNothing, reason: 'leer: kein Clear');

    await tester.enterText(find.byKey(_suche), 'alp');
    await tester.pumpAndSettle();
    expect(find.text('Skyr'), findsNothing);
    expect(
      tester.getSemantics(find.byKey(_clear)),
      isSemantics(
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        tooltip: 'Suche leeren',
      ),
    );

    await tester.tap(find.byKey(_clear));
    await tester.pumpAndSettle();
    expect(find.byKey(_clear), findsNothing);
    expect(find.text('Skyr'), findsOneWidget, reason: 'Filter aufgehoben');
    expect(_textfeldKnoten().value, isEmpty);
    handle.dispose();
  });

  testWidgets('Titel ist als Überschrift markiert', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);

    // Read the node first, so a red expectation does not also leak the handle.
    final knoten = tester.getSemantics(find.byKey(_titel));
    handle.dispose();
    expect(
      knoten,
      isSemantics(label: 'Favoriten (2)', isHeader: true),
      reason: 'favorites_sheet.dart: der Titel-Text trägt kein '
          'Semantics(header: true); ein Screenreader kann nicht zum '
          'Sheet-Kopf springen',
    );
  });

  testWidgets('Herz hat mindestens 40×40 pt Tap-Fläche (geteilte Kachel)',
      (tester) async {
    await _pump(tester);

    // The heart lives in the shared MealSuggestionItem, which uses
    // VisualDensity.compact app-wide (48 - 8 = 40 pt). Raising it to 44 is a
    // repo-wide layout change outside the favorites feature; this pins the
    // shared floor so a regression below Material's compact size is caught.
    const geteilteKachelMindestTap = 40.0;
    final groesse = tester.getSize(find.byKey(_herz0));
    expect(groesse.width, greaterThanOrEqualTo(geteilteKachelMindestTap),
        reason: 'Herz-IconButton (meal_suggestion_item.dart) ist $groesse');
    expect(groesse.height, greaterThanOrEqualTo(geteilteKachelMindestTap),
        reason: 'Herz-IconButton (meal_suggestion_item.dart) ist $groesse');
  });

  testWidgets('Clear-Button hat mindestens 44×44 pt Tap-Fläche',
      (tester) async {
    await _pump(tester);
    await tester.enterText(find.byKey(_suche), 'x');
    await tester.pumpAndSettle();

    final groesse = tester.getSize(find.byKey(_clear));
    expect(groesse.width, greaterThanOrEqualTo(_mindestTap),
        reason: 'Clear-IconButton (favorites_sheet.dart) ist $groesse');
    expect(groesse.height, greaterThanOrEqualTo(_mindestTap),
        reason: 'Clear-IconButton (favorites_sheet.dart) ist $groesse');
  });
}
