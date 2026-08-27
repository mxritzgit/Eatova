// D6 (review 2026-08-08), recipes half: the tab loses search text, category
// filter and scroll position. Two independent causes, kept apart here:
//
// 1. RECYCLING — search field only, no tab switch needed: the screen is a lazy
//    `ListView`, so scrolling far enough recycles the field while `query` in
//    the state stays active — empty field, filtered list.
// 2. UNMOUNT on tab switch — `buildSelectedScreen()` builds one subtree via
//    `switch`. The harness models that and the `IndexedStack` target.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

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

/// Tab-switch harness modelling the home shell without its store wiring.
/// [keepAlive] switches between `switch` (unmounts) and `IndexedStack` (keeps).
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

    return localizedApp(
      Scaffold(
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
      // Motion as before the migration.
      reducedMotion: false,
      scaffold: false,
      safeArea: false,
    );
  }
}

void _pinViewport(WidgetTester tester) {
  // Fixed viewport: at the 800x600 default the list is too short for the
  // search field to scroll out of the cache at all.
  pinPhoneViewport(tester);
}

/// Scroll position of the main list (the inner carousels are horizontal).
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

/// Name of the active category chip, read from `FilterChipPill.selected`;
/// colour-based detection would silently fall back to none.
String _activeFilter(WidgetTester tester) {
  for (final filter in recipeFilters) {
    final chip = find.byKey(ValueKey('recipe-filter-$filter'));
    if (chip.evaluate().isEmpty) continue; // the chip row is lazy
    if (tester.widget<FilterChipPill>(chip).selected) return filter;
  }
  return '<keiner>';
}

/// Types the search text, sets the filter and scrolls down; returns the offset.
Future<double> _setUpState(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('recipes-search-input')),
    'reis',
  );
  await tester.pumpAndSettle();
  // Chip 2 is the last one fully inside the viewport in the test font.
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
    await pumpLocalized(
      tester,
      _recipesScreen(),
      // Motion as before the migration.
      reducedMotion: false,
      safeArea: false,
      settle: true,
    );

    await tester.enterText(
      find.byKey(const ValueKey('recipes-search-input')),
      'reis',
    );
    await tester.pumpAndSettle();
    expect(_searchText(tester), 'reis');

    // Drag, not jumpTo: dragging unfocuses the field, and only an unfocused
    // EditableText may be recycled.
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
    await pumpLocalized(
      tester,
      _recipesScreen(),
      // Motion as before the migration.
      reducedMotion: false,
      safeArea: false,
      settle: true,
    );

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

    // 1. Scroll position — must be checked BEFORE scrolling back up.
    expect(_listPosition(tester).pixels, offset);

    // 2. Search text and filter: bring the list head back into view.
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

    // The scroll position lives in the route's PageStorage and survives the
    // unmount.
    expect(_listPosition(tester).pixels, offset);

    // Search text and filter live in the screen state and go with it; only
    // the IndexedStack change can save them.
    _listPosition(tester).jumpTo(0);
    await tester.pumpAndSettle();
    expect(_searchText(tester), '');
    expect(_activeFilter(tester), 'Alle');
  });
}
