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
// Deliberately without design_harness.dart: no dependency on a foreign helper.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

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

/// The tab in its real environment: the home shell pads every tab with
/// `EdgeInsets.fromLTRB(20, 12, 20, 12)`. Without that padding the test would
/// measure a width that does not exist in the app.
Widget _app(
  Brightness brightness, {
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
  Locale locale = const Locale('de'),
}) {
  return MaterialApp(
    theme: buildEatovaTheme(brightness),
    // RecipesScreen calls slot.label(l10n) for the slot picker, so it needs
    // context.l10n.
    locale: locale,
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: RecipesScreen(
            onAddMeal: (MealAnalysisResult _, MealSlot __) {},
            remainingMacros: _remaining,
            onCreateRecipe: (_) async => SyncDelivery.delivered,
            initialUserRecipes: userRecipes,
          ),
        ),
      ),
    ),
  );
}

void _pinViewport(WidgetTester tester, {double textScale = 1.0}) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Collects overflow errors during [body] and reports them together.
///
/// `FlutterError.onError` is restored BEFORE the `expect`: otherwise the
/// binding asserts on the first TestFailure while the handler is still in
/// place.
Future<void> _expectNoOverflow(
  String was,
  Future<void> Function() body,
) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      final culprit =
          RegExp(r'\S+:file:///\S+').firstMatch(details.toString())?.group(0);
      overflows.add('${details.summary} (${culprit ?? 'Verursacher unbekannt'})');
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  expect(
    overflows,
    isEmpty,
    reason: '$was overflowt bei doppelter Schrift:\n${overflows.join('\n')}',
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
  group('Beide Anzeige-Modi', () {
    for (final brightness in Brightness.values) {
      final modus = brightness == Brightness.light ? 'hell' : 'dunkel';

      testWidgets('Rezepte-Tab rendert im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
        expect(find.text('Rezepte'), findsOneWidget);
        expect(find.text('Empfehlungen'), findsOneWidget);
      });

      testWidgets('Detail-Ansicht rendert im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();
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

      testWidgets('Slot-Picker rendert im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();
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
        expect(find.text('Wann eintragen?'), findsOneWidget);
      });

      // The only place in this package where text does NOT sit on a token
      // surface: the carousel image tile. Its scrim is dark in both modes, so
      // `t.ink` would be black on black in light mode — an exception-free test
      // would not catch that.
      testWidgets('Text auf dem Foto bleibt im $modus-Modus hell',
          (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();

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

      testWidgets('Anlege-Sheet rendert im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('recipe-create-sheet')),
          findsOneWidget,
        );
        expect(find.text('Eigenes Rezept'), findsWidgets);
      });
    }
  });

  group('Textskalierung 2.0', () {
    testWidgets('Rezepte-Tab overflowt nicht', (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Der Rezepte-Tab', () async {
        await tester.pumpWidget(_app(Brightness.dark));
        await tester.pumpAndSettle();
        // To the end of the list: the goal section sits behind the main list.
        await _scrollThrough(tester, const ValueKey('screen-recipes'));
        expect(
          find.byKey(const ValueKey('recipe-goal-matches')),
          findsOneWidget,
          reason: 'Vorbedingung: die Ziel-Sektion muss erreicht worden sein.',
        );
      });
    });

    testWidgets('Detail-Ansicht overflowt nicht', (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Die Rezept-Detailansicht', () async {
        await tester.pumpWidget(_app(Brightness.light));
        await tester.pumpAndSettle();
        await _openDetail(tester);
        // All the way down: at 2x font the four info sections sit several
        // screens deep; a single -600 drag did not reach them.
        await _scrollThrough(tester, const ValueKey('recipe-detail-scroll'));
        expect(
          find.text('Profi-Hinweis'),
          findsOneWidget,
          reason: 'Vorbedingung: das Listenende muss erreicht worden sein.',
        );
      });
    });

    testWidgets('Slot-Picker overflowt nicht', (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Der Slot-Picker', () async {
        await tester.pumpWidget(_app(Brightness.dark));
        await tester.pumpAndSettle();
        await _openDetail(tester);
        await _openSlotPicker(tester);
      });
    });

    testWidgets('Anlege-Sheet overflowt nicht', (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Das Anlege-Sheet', () async {
        await tester.pumpWidget(_app(Brightness.dark));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
        await tester.pumpAndSettle();
      });
    });
  });

  testWidgets('Key-Inventar des Rezepte-Tabs ist vollstaendig', (tester) async {
    _pinViewport(tester);
    await tester.pumpWidget(_app(Brightness.dark));
    await tester.pumpAndSettle();

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
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.light));
      await tester.pumpAndSettle();
      await _openDetail(tester);
      await _openSlotPicker(tester);

      await tester.tap(find.byKey(const ValueKey('recipe-meal-picker-lunch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('590 kcal zu Mittagessen hinzugefügt.'), findsOneWidget);
    });

    testWidgets('Loeschen eines Eigen-Rezepts meldet den Titel',
        (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.dark, userRecipes: [_eigenes]));
      await tester.pumpAndSettle();

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
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.light));
      await tester.pumpAndSettle();

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
    _pinViewport(tester);
    await tester.pumpWidget(_app(Brightness.dark));
    await tester.pumpAndSettle();

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
    _pinViewport(tester);
    await tester.pumpWidget(_app(Brightness.light));
    await tester.pumpAndSettle();

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
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.dark));
      await tester.pumpAndSettle();

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
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.dark, userRecipes: [_eigenes]));
      await tester.pumpAndSettle();

      expect(find.byType(ImagePlaceholder), findsWidgets);
    });
  });

  group('EN-Render-Smoke (i18n-Paket 3, Spec §6)', () {
    // Renders under locale `en` in both brightnesses: no crash, and at least
    // one real English translation is in the tree. English strings are
    // sometimes longer than German, catching overflows a pure `de` run misses.
    for (final helligkeit in Brightness.values) {
      testWidgets('Rezepte-Tab rendert unter en in $helligkeit ohne Ausnahme',
          (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(helligkeit, locale: const Locale('en')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull,
            reason: 'Rendering unter en/$helligkeit ist fehlgeschlagen');
        // Screen chrome in English.
        expect(find.text('Recipes'), findsOneWidget);
        expect(find.text('Recommendations'), findsOneWidget);
        // The catalog itself is bilingual, so under en the real translation is
        // in the tree, not just the screen chrome. The first catalog recipe
        // always shows in the carousel without scrolling.
        expect(find.text('Chicken with Rice & Broccoli'), findsWidgets);
      });
    }
  });
}
