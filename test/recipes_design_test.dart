// Design refactor — recipes package.
//
// This suite checks not behaviour (other suites do that) but the three
// guarantees of the refactor itself:
//
//   1. Tab, detail view and both sheets render exception-free in BOTH display
//      modes — `AppTokens.of` throws without a theme, and a hardcoded dark
//      colour only shows up here in light mode.
//   2. Nothing overflows at textScaler 2.0. The other recipe suites swallow
//      overflows (testWidgetsRobust); this one collects them.
//   3. The tab's key inventory is complete, so a lost key fails ONE test
//      instead of scattering across four suites.
//
// The mode loops are `renderMatrix` calls now; it declares the same cases and
// asserts the overflow freedom this file used to hand-roll.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_tokens.dart' show AppType;
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

const _remaining = MacroProgress(
  proteinG: 90,
  carbsG: 180,
  fatG: 50,
  kcal: 1600,
);

/// A user recipe without an image asset — the only case where the
/// [ImagePlaceholder] may appear.
final _eigenes = FitnessRecipe(
  slug: FitnessRecipe.userRecipeSlug(),
  title: 'Mein Testteller',
  description: 'Eigenes Rezept',
  portion: '1 Portion',
  ingredients: 'Keine Angabe',
  preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
  professionalHint: 'Selbst angelegt.',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 40,
  carbsG: 50,
  fatG: 15,
  estimatedGrams: 300,
  categories: const <String>['Eigene'],
  userCreated: true,
);

/// The recipes tab. In its real environment the home shell pads every tab
/// with `EdgeInsets.fromLTRB(20, 12, 20, 12)` — see [_schalenrand]; without
/// that padding the test would measure a width that does not exist in the app.
Widget _tab({List<FitnessRecipe> userRecipes = const <FitnessRecipe>[]}) =>
    RecipesScreen(
      onAddMeal: (MealAnalysisResult _, MealSlot __) {},
      remainingMacros: _remaining,
      onCreateRecipe: (_) async => SyncDelivery.delivered,
      initialUserRecipes: userRecipes,
    );

const EdgeInsets _schalenrand = EdgeInsets.fromLTRB(20, 12, 20, 12);

/// Mounts the tab for one matrix case.
Future<void> _pumpTab(
  WidgetTester tester,
  RenderCase c, {
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
}) async {
  pinPhoneViewport(tester);
  await c.pump(
    tester,
    _tab(userRecipes: userRecipes),
    padding: _schalenrand,
    settle: true,
  );
}

/// Mounts the tab outside a matrix (fixed mode, fixed scale).
Future<void> _pumpTabPlain(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    _tab(userRecipes: userRecipes),
    brightness: brightness,
    padding: _schalenrand,
    settle: true,
  );
}

/// Scrolls the main list until [finder] is visible.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.dragUntilVisible(
    finder,
    find.byKey(const ValueKey('screen-recipes')),
    const Offset(0, -250),
  );
  await tester.pumpAndSettle();
}

Finder _scrollableIn(Key key) => find
    .descendant(of: find.byKey(key), matching: find.byType(Scrollable))
    .first;

/// Runs a scroller once from top to bottom.
///
/// Via [ScrollPosition] rather than `dragUntilVisible`: at 2x font the content
/// is several screens tall and would hit its 50-iteration limit. It also builds
/// EVERY card once, which is what the overflow collector needs to see.
Future<void> _scrollThrough(WidgetTester tester, Key key) async {
  var position = tester.state<ScrollableState>(_scrollableIn(key)).position;
  while (position.pixels < position.maxScrollExtent) {
    position.jumpTo(
      (position.pixels + 700).clamp(0.0, position.maxScrollExtent),
    );
    await tester.pumpAndSettle();
    // The lazy list grows while scrolling — re-read the position.
    position = tester.state<ScrollableState>(_scrollableIn(key)).position;
  }
}

/// Opens the slot picker from the detail view.
///
/// `ensureVisible` is not cosmetic: at textScaler 2.0 the add button sits about
/// 1760 px deep, far below the 852 px viewport, and a plain `tap()` missed it
/// with only a warning, leaving the overflow case waiting on a sheet that never
/// opened.
Future<void> _openSlotPicker(WidgetTester tester) async {
  final addButton = find.byKey(const ValueKey('recipe-add-button'));
  await tester.ensureVisible(addButton);
  await tester.pumpAndSettle();
  await tester.tap(addButton);
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('recipe-meal-picker-sheet')),
    findsOneWidget,
    reason: 'Vorbedingung: der Slot-Picker muss wirklich offen sein.',
  );
}

/// Opens the detail view of the chicken recipe.
Future<void> _openDetail(WidgetTester tester) async {
  final tile = find.byKey(
    const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
  );
  await _scrollTo(tester, tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  // The tab itself: both modes AND both languages from one call. The old file
  // had this as two separate loops (mode loop + EN-Render-Smoke group), and it
  // never paired `en` with the 2.0 case at all.
  renderMatrix(
    'Der Rezepte-Tab rendert overflow-frei',
    (tester, c) async {
      await _pumpTab(tester, c);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
      expect(find.text(c.l10n.navRecipes), findsOneWidget);
      expect(find.text(c.l10n.recipesRecommendedTitle), findsOneWidget);
    },
    locales: const <Locale>[Locale('de'), Locale('en')],
  );

  renderMatrix('Die Rezept-Detailansicht rendert overflow-frei',
      (tester, c) async {
    await _pumpTab(tester, c);
    await _openDetail(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(
        const ValueKey('recipe-detail-hahnchen_mit_reis_and_brokkoli'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('recipe-add-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-add-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-detail-back')), findsOneWidget);
  });

  renderMatrix('Der Slot-Picker rendert overflow-frei', (tester, c) async {
    await _pumpTab(tester, c);
    await _openDetail(tester);
    await _openSlotPicker(tester);

    expect(tester.takeException(), isNull);
    for (final slot in MealSlot.values) {
      expect(
        find.byKey(ValueKey('recipe-meal-picker-${slot.name}')),
        findsOneWidget,
        reason: '${slot.name} fehlt im Picker',
      );
    }
    expect(
      find.byKey(const ValueKey('recipe-meal-picker-cancel')),
      findsOneWidget,
    );
    expect(find.text(c.l10n.recipesWhenToLogTitle), findsOneWidget);
  });

  // The only place in this package where text does NOT sit on a token
  // surface: the carousel image tile. Its scrim is dark in both modes, so
  // `t.ink` would be black on black in light mode — an exception-free test
  // would not catch that.
  renderMatrix('Text auf dem Foto bleibt hell', (tester, c) async {
    await _pumpTab(tester, c);

    final overlay = find
        .ancestor(
          of: find.text('EMPFOHLEN').first,
          matching: find.byType(Column),
        )
        .first;
    final texte = tester
        .widgetList<Text>(
          find.descendant(of: overlay, matching: find.byType(Text)),
        )
        .toList();

    // The title uses the display family, the metrics row 11 pt; the badge
    // (onForest on forest, 9.5 pt) falls through both filters.
    final aufDemFoto = texte.where(
      (w) =>
          w.style?.fontFamily == AppType.displayFamily ||
          w.style?.fontSize == 11,
    );
    expect(
      aufDemFoto.length,
      greaterThanOrEqualTo(2),
      reason: 'Titel und Kennzahlen der Bildkachel wurden nicht gefunden.',
    );
    for (final w in aufDemFoto) {
      expect(
        w.style!.color!.computeLuminance(),
        greaterThan(0.5),
        reason: '„${w.data}" steht auf dem dunklen Foto-Scrim und braucht '
            'helle Schrift.',
      );
    }
  });

  renderMatrix('Das Anlege-Sheet rendert overflow-frei', (tester, c) async {
    await _pumpTab(tester, c);

    await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
    expect(find.text(c.l10n.recipesOwnTitle), findsWidgets);
  });

  group('Textskalierung 2.0', () {
    // One mode each, deliberately: these cases scroll the whole list at 2x
    // font, which is the expensive part; the mode-specific metrics are already
    // covered by the matrices above.
    renderMatrix(
      'Der Rezepte-Tab overflowt bei doppelter Schrift nicht',
      (tester, c) async {
        await _pumpTab(tester, c);
        // To the end of the list: the goal section sits behind the main list.
        await _scrollThrough(tester, const ValueKey('screen-recipes'));
        expect(
          find.byKey(const ValueKey('recipe-goal-matches')),
          findsOneWidget,
          reason: 'Vorbedingung: die Ziel-Sektion muss erreicht worden sein.',
        );
      },
      brightnesses: const <Brightness>[Brightness.dark],
      textScales: const <double>[2.0],
    );

    renderMatrix(
      'Die Rezept-Detailansicht overflowt bei doppelter Schrift nicht',
      (tester, c) async {
        await _pumpTab(tester, c);
        await _openDetail(tester);
        // All the way down: at 2x font the four info sections sit several
        // screens deep; a single -600 drag did not reach them.
        await _scrollThrough(tester, const ValueKey('recipe-detail-scroll'));
        expect(
          find.text(c.l10n.recipesSectionProHint),
          findsOneWidget,
          reason: 'Vorbedingung: das Listenende muss erreicht worden sein.',
        );
      },
      brightnesses: const <Brightness>[Brightness.light],
      textScales: const <double>[2.0],
    );

    renderMatrix(
      'Der Slot-Picker overflowt bei doppelter Schrift nicht',
      (tester, c) async {
        await _pumpTab(tester, c);
        await _openDetail(tester);
        await _openSlotPicker(tester);
      },
      brightnesses: const <Brightness>[Brightness.dark],
      textScales: const <double>[2.0],
    );

    renderMatrix(
      'Das Anlege-Sheet overflowt bei doppelter Schrift nicht',
      (tester, c) async {
        await _pumpTab(tester, c);
        await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
        await tester.pumpAndSettle();
      },
      brightnesses: const <Brightness>[Brightness.dark],
      textScales: const <double>[2.0],
    );
  });

  testWidgets('Key-Inventar des Rezepte-Tabs ist vollstaendig', (tester) async {
    await _pumpTabPlain(tester);

    expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipes-search-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-create-button')), findsOneWidget);

    // The search field carries the key DIRECTLY on the TextField; other suites
    // cast on it.
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('recipes-search-input')))
          .controller,
      isNotNull,
    );

    // The clear X only appears when the field is non-empty.
    expect(find.byKey(const ValueKey('recipes-search-clear')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('recipes-search-input')),
      'reis',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipes-search-clear')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recipes-search-clear')));
    await tester.pumpAndSettle();

    // The chip strip is lazy: later chips only exist once scrolled into the
    // cache area, so run through it once and collect.
    final strip = find
        .ancestor(
          of: find.byKey(const ValueKey('recipe-filter-Alle')),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(strip).position;
    final gesehen = <String>{};
    for (var offset = 0.0;; offset += 120) {
      for (final filter in recipeFilters) {
        if (find.byKey(ValueKey('recipe-filter-$filter')).evaluate().isNotEmpty) {
          gesehen.add(filter);
        }
      }
      if (offset > position.maxScrollExtent) break;
      position.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
      await tester.pumpAndSettle();
    }
    expect(gesehen, containsAll(recipeFilters));

    await _scrollTo(tester, find.byKey(const ValueKey('recipe-goal-matches')));
    expect(find.byKey(const ValueKey('recipe-goal-matches')), findsOneWidget);
  });

  // These three messages used to run through `showAppSnack(accent: …)` and
  // never reached `context.t` (short-circuiting expression). With `tone:` the
  // token access is live, so a toast without a theme would throw.
  group('Toasts', () {
    testWidgets('Eintragen meldet „590 kcal zu Mittagessen hinzugefügt."',
        (tester) async {
      await _pumpTabPlain(tester, brightness: Brightness.light);
      await _openDetail(tester);
      await _openSlotPicker(tester);

      await tester.tap(find.byKey(const ValueKey('recipe-meal-picker-lunch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('590 kcal zu Mittagessen hinzugefügt.'), findsOneWidget);
    });

    testWidgets('Loeschen eines Eigen-Rezepts meldet den Titel',
        (tester) async {
      await _pumpTabPlain(tester, userRecipes: [_eigenes]);

      final tile = find.byKey(ValueKey('recipe-tile-${_eigenes.slug}'));
      await _scrollTo(tester, tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('„${_eigenes.title}" gelöscht.'), findsOneWidget);
      expect(find.byKey(ValueKey('recipe-tile-${_eigenes.slug}')), findsNothing);
    });

    testWidgets('Speichern eines neuen Rezepts meldet den Titel',
        (tester) async {
      await _pumpTabPlain(tester, brightness: Brightness.light);

      await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recipe-create-name')),
        'Protein-Bowl',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recipe-create-kcal')),
        '520',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('„Protein-Bowl" gespeichert.'), findsOneWidget);
    });
  });

  // The field label moved from `InputDecoration.labelText` to an uppercase line
  // ABOVE the field, which left the field unlabelled for screen readers
  // (getSemantics().label == ''). This test pins the restored association.
  testWidgets('Jedes Feld des Anlege-Sheets sagt sich mit Namen an',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpTabPlain(tester);

    await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
    await tester.pumpAndSettle();

    const felder = <String, String>{
      'recipe-create-name': 'Name',
      'recipe-create-portion': 'Portion',
      'recipe-create-kcal': 'Kalorien',
      'recipe-create-grams': 'Gewicht',
      'recipe-create-protein': 'Protein',
      'recipe-create-carbs': 'KH',
      'recipe-create-fat': 'Fett',
      'recipe-create-ingredients': 'Zutaten',
    };
    felder.forEach((key, label) {
      expect(
        tester.getSemantics(find.byKey(ValueKey(key))).label,
        contains(label),
        reason: '„$key" sagt sich dem Screenreader nicht als „$label" an',
      );
    });

    semantics.dispose();
  });

  // The metrics row briefly showed only kcal, protein and portion weight; carbs
  // and fat had been on every card before. This test pins the full macro trio
  // on the list tile.
  testWidgets('Die Listenkachel zeigt kcal und alle drei Makros',
      (tester) async {
    await _pumpTabPlain(tester, brightness: Brightness.light);

    final tile = find.byKey(
      const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
    );
    await _scrollTo(tester, tile);

    for (final kennzahl in <String>['590 kcal', '55g P', '62g KH', '12g F']) {
      expect(
        find.descendant(of: tile, matching: find.text(kennzahl)),
        findsOneWidget,
        reason: '„$kennzahl" fehlt auf der Rezept-Kachel',
      );
    }
  });

  group('Echte Bilder bleiben, der Platzhalter ist der Ausnahmefall', () {
    testWidgets('Bestandsrezepte zeigen keinen Platzhalter', (tester) async {
      await _pumpTabPlain(tester);

      expect(
        find.byType(ImagePlaceholder),
        findsNothing,
        reason: 'Alle 30 Bestandsrezepte haben ein echtes Asset — der '
            'Platzhalter des Entwurfs darf sie nicht ersetzen.',
      );
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('ein Eigen-Rezept ohne Bild bekommt den Platzhalter',
        (tester) async {
      await _pumpTabPlain(tester, userRecipes: [_eigenes]);

      expect(find.byType(ImagePlaceholder), findsWidgets);
    });
  });

  testWidgets('unter en ist der Katalog selbst uebersetzt, nicht nur die '
      'Schale', (tester) async {
    // The `en` chrome is covered by the matrix at the top of this file; what
    // it cannot show is that the CATALOG is bilingual too. The first catalog
    // recipe always shows in the carousel without scrolling.
    pinPhoneViewport(tester);
    await pumpLocalized(
      tester,
      _tab(),
      locale: const Locale('en'),
      padding: _schalenrand,
      settle: true,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Recipes'), findsOneWidget);
    expect(find.text('Recommendations'), findsOneWidget);
    expect(find.text('Chicken with Rice & Broccoli'), findsWidgets);
  });
}
