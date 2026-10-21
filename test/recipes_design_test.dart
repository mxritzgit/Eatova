// Design refactor — recipes package.
//
// Checks the layout guarantees, not the behaviour (other suites do that):
//
//   1. Nothing overflows at textScaler 2.0 on the tab, the detail view and the
//      slot picker, and the nutrition values stay whole at 320 px. The other
//      recipe suites swallow overflows (testWidgetsRobust); this one collects
//      them. The create sheet is covered by recipe_create_photo_test.dart.
//   2. The hero title stays readable (4.5:1) below the photo in both modes.
//   3. Screen-reader labels of the create sheet, the list/detail numbers and
//      the pinned add card.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_tokens.dart' show AppType, AppTokens;
import 'package:eatova/src/widgets/recipes/recipe_photo.dart' show RecipeArt;

import 'support/harness.dart';
import 'support/recipe_navigation.dart';

const _remaining = MacroProgress(
  proteinG: 90,
  carbsG: 180,
  fatG: 50,
  kcal: 1600,
);

/// A user recipe without an image asset — the only case where the
/// [RecipeArt] placeholder may appear.
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

/// The recipes tab. Since the dark redesign the tab owns its gutters (its
/// chips and shelves run to the screen edge), so the home shell pads it with
/// nothing — see [_schalenrand]; any other padding would measure a width that
/// does not exist in the app.
Widget _tab() => RecipesScreen(
  onAddMeal: (MealAnalysisResult _, MealSlot __) {},
  remainingMacros: _remaining,
  onCreateRecipe: (_) async => SyncDelivery.delivered,
);

const EdgeInsets _schalenrand = EdgeInsets.zero;

/// Mounts the tab for one matrix case.
Future<void> _pumpTab(WidgetTester tester, RenderCase c) async {
  pinPhoneViewport(tester);
  await c.pump(
    tester,
    _tab(),
    padding: _schalenrand,
    settle: true,
  );
}

/// Mounts the tab outside a matrix (fixed mode, fixed scale).
Future<void> _pumpTabPlain(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    _tab(),
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
  renderMatrix(
    'Rezept-Naehrwerte bleiben bei 320 px und doppelter Schrift vollstaendig',
    (tester, c) async {
      await c.pump(
        tester,
        RecipeDetailScreen(recipe: _eigenes, onAddMeal: (_, __) {}),
        surfaceSize: const Size(320, 720),
        settle: true,
      );

      final texts = [
        '${_eigenes.caloriesKcal}',
        '${_eigenes.proteinG} g',
        '${_eigenes.carbsG} g',
        '${_eigenes.fatG} g',
        c.l10n.recipesNutritionKcalLabel.toUpperCase(),
        c.l10n.todayMacroProtein.toUpperCase(),
        c.l10n.recipesNutritionCarbsLabel.toUpperCase(),
        c.l10n.todayMacroFat.toUpperCase(),
      ];
      for (final text in texts) {
        final finder = find.text(text);
        expect(finder, findsOneWidget);
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(finder);
        // Text finders still match the full string when an ellipsis hides it.
        expect(paragraph.didExceedMaxLines, isFalse, reason: text);
        expect(
          paragraph.size.height + 0.5,
          greaterThanOrEqualTo(
            paragraph.getMaxIntrinsicHeight(paragraph.size.width),
          ),
          reason: '$text braucht Platz fuer alle Zeilen.',
        );
        final bounds = tester.getRect(finder);
        expect(bounds.left, greaterThanOrEqualTo(20), reason: text);
        expect(bounds.right, lessThanOrEqualTo(300), reason: text);
      }
      expect(tester.takeException(), isNull);
    },
    locales: const [Locale('de'), Locale('en')],
    brightnesses: const [Brightness.dark],
    textScales: const [2.0],
  );

  // Dark redesign: the hero replaced the spotlight carousel. Its title still
  // sits below the photo, on the card surface, readable at 4.5:1.
  renderMatrix('Hero: lesbarer Titel unter dem Foto', (tester, c) async {
    await _pumpTab(tester, c);
    final hero = find.byKey(const ValueKey('recipe-hero'));
    final title = find.descendant(
      of: hero,
      matching: find.byWidgetPredicate((w) => w is Text &&
          w.style?.fontFamily == AppType.displayFamily &&
          w.style?.fontSize == 24),
    ).first;
    final photo = find.descendant(of: hero, matching: find.byType(Image)).first;
    expect(tester.getTopLeft(title).dy, greaterThan(tester.getBottomLeft(photo).dy));
    final text = tester.widget<Text>(title);
    final t = AppTokens.of(tester.element(title));
    final a = text.style!.color!.computeLuminance();
    final b = t.surf.computeLuminance();
    expect((a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05)),
        greaterThanOrEqualTo(4.5));
  });

  group('Textskalierung 2.0', () {
    // One mode each: the palette does not change the layout. These cases
    // scroll the whole list at 2x font, which is the expensive part.
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
      },
      brightnesses: const <Brightness>[Brightness.dark],
      textScales: const <double>[2.0],
    );
  });

  testWidgets('ein neues Rezept steht danach unter „Eigene“, mit Meldung',
      (tester) async {
    await _pumpTabPlain(tester, brightness: Brightness.light);

    await openRecipeCreateSheet(tester);
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
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('recipes-tab-own')))
        .properties.selected, isTrue);
    expect(find.text('Protein-Bowl'), findsOneWidget);
  });

  // The field label moved from `InputDecoration.labelText` to an uppercase line
  // ABOVE the field, which left the field unlabelled for screen readers
  // (getSemantics().label == ''). This test pins the restored association.
  testWidgets('Jedes Feld des Anlege-Sheets sagt sich mit Namen an',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpTabPlain(tester);

    await openRecipeCreateSheet(tester);

    const felder = <String, String>{
      'recipe-create-name': 'Name',
      'recipe-create-portion': 'Portion',
      'recipe-create-kcal': 'Kalorien',
      'recipe-create-grams': 'Gewicht',
      'recipe-create-protein': 'Protein',
      'recipe-create-carbs': 'Kohlenhydrate',
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

  testWidgets('Listen zeigen kcal und Protein; Details alle Makros',
      (tester) async {
    await _pumpTabPlain(tester, brightness: Brightness.light);
    final tile = find.byKey(
      const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
    );
    await _scrollTo(tester, tile);
    // The shelves' wording, with number and unit held together by no-break
    // spaces: at 2x text the line broke inside "55 g / Protein".
    expect(
      find.descendant(
        of: tile,
        matching: find.text('590\u00A0kcal · 55\u00A0g\u00A0Protein'),
      ),
      findsOneWidget,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    for (final value in ['590', '55 g', '62 g', '12 g']) {
      expect(find.text(value), findsOneWidget, reason: value);
    }
  });

  // The placeholder art is the exception (own recipes without a photo, see
  // recipes_redesign_details_test.dart), never a stand-in for real photos.
  testWidgets('Bestandsrezepte zeigen ihr Foto, keinen Platzhalter', (
    tester,
  ) async {
    await _pumpTabPlain(tester);

    expect(
      find.byType(RecipeArt),
      findsNothing,
      reason: 'Alle 30 Bestandsrezepte haben ein echtes Asset — der '
          'Platzhalter des Entwurfs darf sie nicht ersetzen.',
    );
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets(
    'die gepinnte Eintragen-Karte laesst den Grossteil fuer das Rezept',
    (tester) async {
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: recipeCatalogEn.first,
          onAddMeal: (_, __) {},
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      final body = tester.getRect(
        find.byKey(const ValueKey('recipe-detail-scroll')),
      );
      final action = tester.getRect(
        find.byKey(const ValueKey('recipe-add-card')),
      );
      expect(body.height, greaterThan(852 * .65));
      expect(action.height, lessThan(852 * .3));
      expect(body.bottom, lessThanOrEqualTo(action.top));
      expect(
        find.byKey(const ValueKey('recipe-add-button')).hitTestable(),
        findsOneWidget,
      );
    },
  );
}
