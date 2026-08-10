// D6 (Review 2026-08-08) — Rezepte-Haelfte: Der Rezepte-Tab wirft seinen
// Zustand weg. Der Review nennt drei Verluste: Suchtext, Kategorie-Filter und
// Scrollposition.
//
// Zwei unabhaengige Ursachen, die diese Suite auseinanderhaelt:
//
// 1. RECYCLING — betrifft NUR das Suchfeld und ist ohne jeden Tab-Wechsel
//    reproduzierbar: der Screen ist eine lazy `ListView`, das Suchfeld liegt
//    darin an Position 3. Scrollt der User weit genug nach unten, raeumt die
//    Liste das Element ab; ohne eigenen Controller stirbt der Text mit dem
//    `EditableText`-State. Der Filter (`query`) im `State` bleibt aber aktiv →
//    leeres Feld, trotzdem gefilterte Liste. Echter Bug, haengt an KEINER
//    fremden Datei.
//
// 2. UNMOUNT beim Tab-Wechsel — `eatova_home_page.buildSelectedScreen()` baut
//    per `switch` genau einen Teilbaum. Agent W3-01 ersetzt das durch einen
//    `IndexedStack`. Da die Datei fremd ist, bildet die Suite beide Varianten
//    im Harness `_TabHarness` nach und misst, was jeweils ueberlebt.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';

const _remaining = MacroProgress(
  proteinG: 90,
  carbsG: 180,
  fatG: 50,
  kcal: 1600,
);

Widget _recipesScreen() => RecipesScreen(
      onAddMeal: (MealAnalysisResult _, MealSlot __) {},
      remainingMacros: _remaining,
    );

/// Harness fuer den Tab-Wechsel. Bildet die Home-Schale nach, ohne deren
/// Store-/Sync-Verdrahtung. [keepAlive] schaltet zwischen dem heutigen Stand
/// (`switch` → Teilbaum wird unmounted) und dem Ziel von Agent W3-01
/// (`IndexedStack` → Teilbaum bleibt gemountet) um.
class _TabHarness extends StatefulWidget {
  const _TabHarness({required this.keepAlive});

  final bool keepAlive;

  @override
  State<_TabHarness> createState() => _TabHarnessState();
}

class _TabHarnessState extends State<_TabHarness> {
  int _tab = 1;

  @override
  Widget build(BuildContext context) {
    const other = Center(
      key: ValueKey('screen-other'),
      child: Text('Anderer Tab'),
    );
    final body = widget.keepAlive
        ? IndexedStack(
            index: _tab,
            sizing: StackFit.expand,
            children: <Widget>[other, _recipesScreen()],
          )
        : (_tab == 0 ? other : _recipesScreen());

    return MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: body,
          ),
        ),
        bottomNavigationBar: Row(
          children: <Widget>[
            Expanded(
              child: TextButton(
                key: const ValueKey('harness-tab-0'),
                onPressed: () => setState(() => _tab = 0),
                child: const Text('Anderer'),
              ),
            ),
            Expanded(
              child: TextButton(
                key: const ValueKey('harness-tab-1'),
                onPressed: () => setState(() => _tab = 1),
                child: const Text('Rezepte'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _pinViewport(WidgetTester tester) {
  // Fester Viewport (iPhone 14 portrait). Im 800x600-Default ist die Liste zu
  // kurz, dann scrollt das Suchfeld gar nicht erst aus dem Cache heraus.
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Scrollposition der Haupt-Liste (die inneren Carousels sind horizontal).
ScrollPosition _listPosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byKey(const ValueKey('screen-recipes')),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position;
}

String _searchText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('recipes-search-input')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

/// Name des aktiven Kategorie-Chips.
///
/// Fragt seit dem Design-Refactor 2026-08-09 direkt `FilterChipPill.selected`
/// ab. Vorher suchte der Helfer ein `AnimatedContainer` mit limefarbener
/// `decoration.color` — beides gibt es in der neuen Chip-Pille nicht mehr
/// (sie faerbt mit `t.forest` und ohne Animation), der Helfer waere still auf
/// `<keiner>` zurueckgefallen. Gleiche Zusicherung, farb- und tokenfrei
/// abgelesen.
String _activeFilter(WidgetTester tester) {
  for (final filter in recipeFilters) {
    final chip = find.byKey(ValueKey('recipe-filter-$filter'));
    if (chip.evaluate().isEmpty) continue; // Chip-Leiste ist lazy.
    if (tester.widget<FilterChipPill>(chip).selected) return filter;
  }
  return '<keiner>';
}

/// Tippt den Suchtext, setzt den Kategorie-Filter und scrollt nach unten.
/// Liefert den erreichten Scroll-Offset zurueck.
Future<double> _setUpState(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('recipes-search-input')),
    'reis',
  );
  await tester.pumpAndSettle();
  // „High Protein" ist Chip 2 und liegt im Test-Font noch vollstaendig im
  // Viewport — weiter hinten liegende Chips sind horizontal abgeschnitten.
  await tester.tap(find.byKey(const ValueKey('recipe-filter-High Protein')));
  await tester.pumpAndSettle();

  final position = _listPosition(tester);
  expect(position.maxScrollExtent, greaterThan(600),
      reason: 'Vorbedingung: die gefilterte Liste muss lang genug sein, damit '
          'das Suchfeld ueberhaupt aus dem Cache scrollen kann.');
  position.jumpTo(600);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('recipes-search-input')), findsNothing,
      reason: 'Vorbedingung: das Suchfeld muss wirklich abgeraeumt sein.');
  return position.pixels;
}

void main() {
  testWidgets(
      'Suchtext ueberlebt das Wegscrollen des Suchfelds (Listen-Recycling)',
      (tester) async {
    _pinViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        home: Scaffold(body: _recipesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('recipes-search-input')),
      'reis',
    );
    await tester.pumpAndSettle();
    expect(_searchText(tester), 'reis');

    // Ziehen statt jumpTo: die Liste nimmt dem Feld beim Ziehen den Fokus
    // (`keyboardDismissBehavior: onDrag`). Genau das ist die Bedingung, unter
    // der die Liste das Feld ueberhaupt abraeumen darf — ein fokussiertes
    // EditableText haelt sich per AutomaticKeepAlive selbst am Leben.
    await tester.drag(
      find.byKey(const ValueKey('screen-recipes')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();

    final position = _listPosition(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipes-search-input')), findsNothing,
        reason: 'Vorbedingung: das Suchfeld muss wirklich abgeraeumt worden '
            'sein, sonst testet der Fall nichts.');

    position.jumpTo(0);
    await tester.pumpAndSettle();

    expect(_searchText(tester), 'reis',
        reason: 'Ohne eigenen Controller stirbt der Text mit dem '
            'EditableText-State — die Liste bleibt aber gefiltert.');
  });

  testWidgets('Loesch-X leert Suchtext und Trefferliste sichtbar',
      (tester) async {
    _pinViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        home: Scaffold(body: _recipesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('recipes-search-clear')), findsNothing,
        reason: 'Leeres Feld braucht kein Loesch-X.');

    await tester.enterText(
      find.byKey(const ValueKey('recipes-search-input')),
      'lachs',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipes-search-clear')), findsOneWidget);
    expect(find.text('${fitnessRecipes.length} Treffer'), findsNothing,
        reason: 'Vorbedingung: die Liste ist gerade gefiltert.');

    await tester.tap(find.byKey(const ValueKey('recipes-search-clear')));
    await tester.pumpAndSettle();

    expect(_searchText(tester), '');
    expect(find.byKey(const ValueKey('recipes-search-clear')), findsNothing);
    expect(
      find.text('${fitnessRecipes.length} Treffer'),
      findsOneWidget,
      reason: 'Nach dem Leeren muss die volle Liste zurueck sein.',
    );
  });

  testWidgets(
      'Tab-Wechsel mit IndexedStack: Suchtext, Filter und Scrollposition bleiben',
      (tester) async {
    _pinViewport(tester);
    await tester.pumpWidget(const _TabHarness(keepAlive: true));
    await tester.pumpAndSettle();

    final offset = await _setUpState(tester);

    await tester.tap(find.byKey(const ValueKey('harness-tab-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('harness-tab-1')));
    await tester.pumpAndSettle();

    // 1. Scrollposition — muss VOR dem Hochscrollen geprueft werden.
    expect(_listPosition(tester).pixels, offset);

    // 2. Suchtext + Filter: dafuer den Kopf der Liste wieder ins Bild holen.
    _listPosition(tester).jumpTo(0);
    await tester.pumpAndSettle();
    expect(_searchText(tester), 'reis');
    expect(_activeFilter(tester), 'High Protein');
  });

  testWidgets(
      'Tab-Wechsel ohne IndexedStack: Scrollposition kommt aus dem PageStorage zurueck',
      (tester) async {
    _pinViewport(tester);
    await tester.pumpWidget(const _TabHarness(keepAlive: false));
    await tester.pumpAndSettle();

    final offset = await _setUpState(tester);

    await tester.tap(find.byKey(const ValueKey('harness-tab-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-recipes')), findsNothing,
        reason: 'Vorbedingung: der Teilbaum wird hier wirklich unmounted.');
    await tester.tap(find.byKey(const ValueKey('harness-tab-1')));
    await tester.pumpAndSettle();

    // Die Scrollposition haengt am PageStorage der Route und ueberlebt auch
    // das Unmounten des Teilbaums.
    expect(_listPosition(tester).pixels, offset);

    // Suchtext + Filter leben dagegen im State des Screens und sind mit ihm
    // weg — das kann nur W3-01 (IndexedStack) retten, nicht diese Datei.
    _listPosition(tester).jumpTo(0);
    await tester.pumpAndSettle();
    expect(_searchText(tester), '');
    expect(_activeFilter(tester), 'Alle');
  });
}
