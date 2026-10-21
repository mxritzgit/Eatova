// The weekly receipt on screen (2026-10-11): one row per ingredient for the
// whole week with the days behind it, one check write per tap, spices and
// staples in a collapsed "Gewürze & Vorrat" that stays out of the totals,
// a note for recipes without ingredients, amounts the recipe gives
// unconverted, and the layout at 320 px with 2x text.

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/shopping_receipt.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';

/// A Monday, so the shown week is Sep 7 to Sep 13.
final _today = DateTime(2026, 9, 7, 12);

HomeStore _store() {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
  );
  addTearDown(store.dispose);
  return store;
}

/// An own recipe: its amounts are as written for one serving.
FitnessRecipe _own(String title, String ingredients) =>
    recipeCatalogDe.first.copyWith(
      slug: 'user_${title.toLowerCase().replaceAll(' ', '_')}',
      title: title,
      ingredients: ingredients,
      structuredIngredients: const [],
    );

Future<void> _plan(
  HomeStore store,
  FitnessRecipe recipe,
  int day,
  MealSlot slot, {
  double servings = 1,
}) => store.savePlannedMeal(
  PlannedMeal.create(
    recipe: recipe,
    day: DateTime(2026, 9, 7 + day),
    slot: slot,
    servings: servings,
  ),
);

/// Chicken on Monday and Thursday, with salt, pepper and olive oil.
Future<void> _chickenWeek(HomeStore store) async {
  await _plan(
    store,
    _own('Hähnchenpfanne', '180 g Hähnchenbrust\n1 Zwiebel\nSalz, Pfeffer'),
    0,
    MealSlot.dinner,
  );
  await _plan(
    store,
    _own('Hähnchenbowl', '250 g Hähnchenbrust\n1/2 Zwiebel\n1 EL Olivenöl'),
    3,
    MealSlot.lunch,
  );
}

ShoppingReceipt _receipt(HomeStore store, {AppLocalizations? l10n}) =>
    buildShoppingReceipt(
      store.plannedMeals,
      _today,
      decimalSeparator: (l10n ?? deL10n).localeName == 'de' ? ',' : '.',
      l10n: l10n ?? deL10n,
    );

ShoppingRow _row(List<ShoppingRow> rows, String label) =>
    rows.singleWhere((r) => r.label == label);

Future<void> _pump(
  WidgetTester tester,
  HomeStore store, {
  Locale locale = const Locale('de'),
  Size size = const Size(393, 852),
  double textScale = 1,
  bool reducedMotion = true,
}) async {
  await pumpLocalized(
    tester,
    MealPlanScreen(store: store),
    locale: locale,
    surfaceSize: size,
    textScale: textScale,
    reducedMotion: reducedMotion,
    settle: true,
  );
  await _tap(tester, _key('meal-plan-tab-shopping'));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey(key));

/// The week card's shopping progress, scrolled back into view.
Future<String> _progress(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 6000));
  await tester.pumpAndSettle();
  return tester.widget<Text>(_key('shopping-progress-label')).data!;
}

/// The footnote on merged rows and amounts read from text, at the end of
/// the list.
Future<Finder> _footnote(WidgetTester tester, AppLocalizations l10n) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, -6000));
  await tester.pumpAndSettle();
  return find.text(l10n.mealPlanUnquantifiedHint);
}

/// The receipt's text with every space but the one after a dot unbreakable,
/// the way a detail line keeps each meal on one line.
String _kept(String text) => text
    .replaceAll(' · ', '\u0000')
    .replaceAll(' ', '\u00A0')
    .replaceAll('\u0000', '\u00A0· ');

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets('dieselbe Zutat aus zwei Mahlzeiten: eine Zeile mit Summe und '
      'Tagen, ein Tipp schreibt genau einen Haken', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _chickenWeek(store);
      final receipt = _receipt(store);
      final chicken = _row(receipt.rows, 'Hähnchenbrust');
      expect(chicken.merged, isTrue);
      await _pump(tester, store);

      // No recipe headings, one row for both meals.
      expect(
        find.textContaining(RegExp('hähnchenpfanne', caseSensitive: false)),
        findsNothing,
      );
      final row = _key('shopping-item-${chicken.id}');
      expect(
        find.descendant(of: row, matching: find.text('430 g')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(_kept('Mo 180 g · Do 250 g')),
        ),
        findsOneWidget,
      );
      expect(find.text('1 1/2'), findsOneWidget);
      expect(find.text(_kept('Mo 1 · Do 1/2')), findsOneWidget);
      // One node, read with full weekdays.
      expect(
        tester.getSemantics(row),
        isSemantics(
          hasCheckedState: true,
          isChecked: false,
          label: 'Hähnchenbrust\n430 g\nMontag 180 g, Donnerstag 250 g',
        ),
      );

      await _tap(tester, row);
      // Exactly one write, under the row's own id; the old line ids of
      // either recipe are untouched.
      expect(store.shoppingChecks, {chicken.id: true});
      expect(tester.getSemantics(row), isSemantics(isChecked: true));
      final detail = tester.widget<Text>(
        find.descendant(
          of: row,
          matching: find.text(_kept('Mo 180 g · Do 250 g')),
        ),
      );
      expect(detail.style!.decoration, TextDecoration.lineThrough);
      expect(await _progress(tester), '1 von 2 abgehakt');

      // The receipt is kept between ticks, never between weeks or plans; a
      // tick outlasts a change of week.
      await _tap(tester, _key('meal-plan-next-week'));
      expect(_key('shopping-receipt'), findsNothing);
      expect(_key('shopping-empty-plan'), findsOneWidget);
      await _tap(tester, _key('meal-plan-previous-week'));
      expect(tester.getSemantics(row), isSemantics(isChecked: true));

      await _tap(tester, row);
      expect(store.shoppingChecks, {chicken.id: false});
      await _plan(
        store,
        _own('Wrap', '100 g Hähnchenbrust'),
        4,
        MealSlot.lunch,
      );
      await tester.pumpAndSettle();
      expect(row, findsNothing);
      expect(find.text('530 g'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('ein Haken von der alten Liste bleibt in der Wochenliste', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _chickenWeek(store);
      // The per-recipe receipt ticked off both chicken lines.
      final items = buildShoppingList(store.plannedMeals, _today);
      for (final item in items) {
        final line = item.lines.firstWhere((l) => l.label.contains('Hähnchen'));
        await store.setShoppingChecked(
          ShoppingCheck(id: line.id, checked: true),
        );
      }
      final chicken = _row(_receipt(store).rows, 'Hähnchenbrust');
      await _pump(tester, store);
      expect(
        tester.getSemantics(_key('shopping-item-${chicken.id}')),
        isSemantics(hasCheckedState: true, isChecked: true),
      );
      expect(await _progress(tester), '1 von 2 abgehakt');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('eine gegessene Mahlzeit lässt Gekauftes abgehakt und den '
      'Stempel stehen', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _chickenWeek(store);
      await _pump(tester, store);
      for (final row in _receipt(store).rows) {
        await _tap(tester, _key('shopping-item-${row.id}'));
      }
      expect(_key('shopping-receipt-stamp'), findsOneWidget);

      // Monday's meal is eaten: Thursday's share of the bought rows is left.
      final monday = store.plannedMeals.singleWhere(
        (p) => p.day == '2026-09-07',
      );
      await store.eatPlannedMeal(monday.id);
      await tester.pumpAndSettle();
      final chicken = _row(_receipt(store).rows, 'Hähnchenbrust');
      final row = _key('shopping-item-${chicken.id}');
      expect(find.descendant(of: row, matching: find.text('250 g')), findsOne);
      expect(
        tester.getSemantics(row),
        isSemantics(hasCheckedState: true, isChecked: true),
      );
      expect(_key('shopping-receipt-stamp'), findsOneWidget);
      expect(await _progress(tester), 'Alles eingekauft');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Gewürze & Vorrat: eingeklappt eine Zeile, aufgeklappt einzeln '
      'abhaken, zählt nicht zu den Summen', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _chickenWeek(store);
      final receipt = _receipt(store);
      expect(receipt.pantry.map((r) => r.label), [
        'Olivenöl',
        'Pfeffer',
        'Salz',
      ]);
      await _pump(tester, store);

      final pantry = _key('shopping-pantry');
      expect(
        find.descendant(of: pantry, matching: find.text('GEWÜRZE & VORRAT')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: pantry, matching: find.text('0 von 3 abgehakt')),
        findsOneWidget,
      );
      expect(find.text('Olivenöl\u00A0· Pfeffer\u00A0· Salz'), findsOneWidget);
      // Read under its own heading, not with the receipt's header.
      final summaryNode = tester.getSemantics(_key('shopping-pantry-summary'));
      expect(summaryNode.label, 'Olivenöl\nPfeffer\nSalz');
      expect(summaryNode.label, isNot(contains('Einkaufsliste')));
      final receiptNode = tester.getSemantics(_key('shopping-receipt'));
      expect(receiptNode.label, contains('Einkaufsliste'));
      expect(receiptNode.label, isNot(contains('0 von 3 abgehakt')));
      expect(receiptNode.label, isNot(contains('Olivenöl')));
      expect(
        tester
            .getSemantics(
              find.descendant(
                of: pantry,
                matching: find.text('0 von 3 abgehakt'),
              ),
            )
            .label,
        '0 von 3 abgehakt\nMeist schon im Schrank. Hake ab, was du noch hast.',
      );
      for (final row in receipt.pantry) {
        expect(_key('shopping-item-${row.id}'), findsNothing);
      }
      final toggle = _key('shopping-pantry-toggle');
      expect(
        tester.getSemantics(toggle),
        isSemantics(
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
          label: 'Einzeln abhaken',
        ),
      );
      expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
      // Totals and progress count the main rows only.
      expect(await _progress(tester), '0 von 2 abgehakt');

      await _tap(tester, toggle);
      expect(_key('shopping-pantry-summary'), findsNothing);
      expect(
        tester.getSemantics(toggle),
        isSemantics(
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
          label: 'Einklappen',
        ),
      );
      final salt = _row(receipt.pantry, 'Salz');
      final oil = _key('shopping-item-${_row(receipt.pantry, 'Olivenöl').id}');
      expect(
        find.descendant(of: oil, matching: find.text('1 EL')),
        findsOneWidget,
      );
      await _tap(tester, _key('shopping-item-${salt.id}'));
      expect(store.shoppingChecks, {salt.id: true});
      expect(
        find.descendant(of: pantry, matching: find.text('1 von 3 abgehakt')),
        findsOneWidget,
      );
      expect(await _progress(tester), '0 von 2 abgehakt');

      // Collapsed again, the ticked-off name is struck through.
      await _tap(tester, toggle);
      final summary = tester.widget<Text>(_key('shopping-pantry-summary'));
      final spans = (summary.textSpan! as TextSpan).children!.cast<TextSpan>();
      final saltSpan = spans.singleWhere((s) => s.text == 'Salz');
      expect(saltSpan.style!.decoration, TextDecoration.lineThrough);
      expect(spans.singleWhere((s) => s.text == 'Pfeffer').style, isNull);
      // A screen reader hears it too.
      expect(
        tester.getSemantics(_key('shopping-pantry-summary')).label,
        'Olivenöl\nPfeffer\nSalz (abgehakt)',
      );

      // Every main row bought: done and stamped, with the pantry still open.
      for (final row in receipt.rows) {
        await _tap(tester, _key('shopping-item-${row.id}'));
      }
      expect(_key('shopping-receipt-stamp'), findsOneWidget);
      expect(await _progress(tester), 'Alles eingekauft');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'das Aufklappen animiert ohne Fehler, wenn Bewegung erlaubt ist',
    (tester) async {
      await withClock(Clock.fixed(_today), () async {
        final store = _store();
        await _chickenWeek(store);
        await _pump(tester, store, reducedMotion: false);
        final toggle = _key('shopping-pantry-toggle');
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        final collapsed = tester.getSize(_key('shopping-pantry')).height;
        await tester.tap(toggle);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final midway = tester.getSize(_key('shopping-pantry')).height;
        await tester.pumpAndSettle();
        final expanded = tester.getSize(_key('shopping-pantry')).height;
        expect(midway, inExclusiveRange(collapsed, expanded));
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets('ein Rezept ohne Zutatenliste ist ein Hinweis unter den Zeilen', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _plan(store, _own('Resteessen', ''), 2, MealSlot.dinner);
      await _pump(tester, store);
      // The receipt shows, without rows or a progress to fill.
      final note = _key('shopping-empty-recipes');
      expect(
        find.descendant(
          of: note,
          matching: find.text(
            'Ohne Zutatenliste: Resteessen (Mi). Rezept vor dem Einkauf '
            'prüfen.',
          ),
        ),
        findsOneWidget,
      );
      // A screen reader hears the full weekday.
      expect(
        tester.getSemantics(note),
        isSemantics(
          label:
              'Ohne Zutatenliste: Resteessen (Mittwoch). Rezept vor dem '
              'Einkauf prüfen.',
        ),
      );
      expect(_key('shopping-receipt'), findsOneWidget);
      expect(_key('shopping-pantry'), findsNothing);
      expect(find.textContaining('abgehakt'), findsNothing);

      // Under rows, two of them name both.
      await _plan(store, _own('Pizza', ''), 4, MealSlot.dinner);
      await _plan(store, _own('Omelett', '3 Eier'), 0, MealSlot.breakfast);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Ohne Zutatenliste: Resteessen (Mi), Pizza (Fr). Rezepte vor dem '
          'Einkauf prüfen.',
        ),
        findsOneWidget,
      );
      expect(await _progress(tester), '0 von 1 abgehakt');

      // Each one links to its recipe, where the list can be checked.
      final pizza = store.plannedMeals.firstWhere(
        (p) => p.recipe.title == 'Pizza',
      );
      final link = _key('shopping-empty-recipe-${pizza.id}');
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.byType(RecipeDetailScreen), findsOneWidget);
      expect(_key('recipe-detail-${pizza.recipe.slug}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('nicht umgerechnete Mengen stehen mit ihrem Rezeptbezug in der '
      'Detailzeile, nicht in der Summe', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      // An import for four, planned for two: the leek cannot be converted.
      await _plan(
        store,
        recipeCatalogDe.first.copyWith(
          slug: 'user_import_soup',
          title: 'Kartoffel-Lauch-Suppe',
          ingredients: '2 Stangen Lauch\n800 g Kartoffeln',
          structuredIngredients: const [],
          categories: ['Eigene', '${recipeIngredientsBasisPrefix}per_recipe'],
          batchServings: 4,
        ),
        2,
        MealSlot.dinner,
        servings: 2,
      );
      // An own recipe for three: its basis is unknown.
      await _plan(
        store,
        _own('Chili', '2 Dosen Kidneybohnen'),
        4,
        MealSlot.dinner,
        servings: 3,
      );
      final receipt = _receipt(store);
      await _pump(tester, store);
      final leek = _key('shopping-item-${_row(receipt.rows, 'Lauch').id}');
      expect(
        find.descendant(
          of: leek,
          matching: find.text('Mi\u00A02\u00A0Stangen (Rezept für 4 Port.)'),
        ),
        findsOneWidget,
      );
      // Heard without the abbreviation.
      expect(
        tester.getSemantics(leek),
        isSemantics(
          label: 'Lauch\nMittwoch 2 Stangen (Rezept für 4 Portionen)',
        ),
      );
      // The converted potatoes need no detail.
      final potatoes = _key(
        'shopping-item-${_row(receipt.rows, 'Kartoffeln').id}',
      );
      expect(
        find.descendant(of: potatoes, matching: find.text('400 g')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: potatoes, matching: find.byType(Text)),
        findsNWidgets(2),
      );
      final beans = _key(
        'shopping-item-${_row(receipt.rows, 'Kidneybohnen').id}',
      );
      expect(
        find.descendant(
          of: beans,
          matching: find.text('Fr\u00A02\u00A0Dosen (Originalrezept)'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(beans),
        isSemantics(label: 'Kidneybohnen\nFreitag 2 Dosen (Originalrezept)'),
      );
      expect(await _footnote(tester, deL10n), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('englische Hinweise und der Hinweis zu zusammengelegten Zeilen', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _plan(
        store,
        recipeCatalogDe.first.copyWith(
          slug: 'user_import_soup',
          title: 'Leek soup',
          ingredients: '2 stalks leek\n800 g potatoes\napprox. 4 carrots',
          structuredIngredients: const [],
          categories: ['Eigene', '${recipeIngredientsBasisPrefix}per_recipe'],
          batchServings: 4,
        ),
        2,
        MealSlot.dinner,
        servings: 2,
      );
      await _plan(
        store,
        _own('Chili', '2 cans kidney beans'),
        4,
        MealSlot.dinner,
        servings: 3,
      );
      await _pump(tester, store, locale: const Locale('en'));
      final rows = _receipt(store, l10n: enL10n).rows;
      expect(
        find.descendant(
          of: _key('shopping-item-${_row(rows, 'Leek').id}'),
          matching: find.text('We\u00A02\u00A0stalks (recipe serves 4)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('shopping-item-${_row(rows, 'Kidney beans').id}'),
          matching: find.text('Fr\u00A02\u00A0cans (original recipe)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('shopping-item-${_row(rows, 'Carrots').id}'),
          matching: find.text('approx. 2'),
        ),
        findsOneWidget,
      );
      expect(await _footnote(tester, enL10n), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Weighed ingredients only: nothing merged, nothing read from text.
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _plan(
        store,
        _own('Bowl', '').copyWith(
          structuredIngredients: [
            RecipeIngredient(
              name: 'Haferflocken',
              grams: 80,
              per100g: const RecipeNutrition(
                caloriesKcal: 370,
                proteinG: 13,
                carbsG: 60,
                fatG: 7,
              ),
            ),
          ],
        ),
        0,
        MealSlot.breakfast,
      );
      await _pump(tester, store);
      expect(find.text('80 g'), findsOneWidget);
      expect(await _footnote(tester, deL10n), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Mengen: kg ab 1.000 g, Einheiten im Plural, Spannen, ca., '
      'Teile verschiedener Einheiten', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _plan(
        store,
        _own(
          'Vorrat',
          '700 g Mehl\n1 Dose Kichererbsen\nca. 4-5 Kartoffeln\n'
              '300 g Spinat\n1 Glas Pesto',
        ),
        0,
        MealSlot.dinner,
      );
      await _plan(
        store,
        _own(
          'Nachschub',
          '500 g Mehl\n1 Dose Kichererbsen\n1 Handvoll Spinat\n'
              '1 1/2 Gläser Pesto',
        ),
        1,
        MealSlot.dinner,
      );
      await _pump(tester, store);
      for (final text in [
        '1,2 kg',
        '2 Dosen',
        'ca. 4–5',
        '300 g + 1 Handvoll',
        '2 1/2 Gläser',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.text(_kept('Mo 1 Glas · Di 1 1/2 Gläser')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _plan(
        store,
        _own('Bowl', '1 can chickpeas\n2 garlic cloves\n1/2 cup rice'),
        0,
        MealSlot.dinner,
      );
      await _plan(
        store,
        _own('Wrap', '1 can chickpeas\n1 garlic clove'),
        1,
        MealSlot.dinner,
      );
      await _pump(tester, store, locale: const Locale('en'));
      final rows = _receipt(store, l10n: enL10n).rows;
      for (final (label, text) in [
        ('Chickpeas', '2 cans'),
        // The name already counts cloves.
        ('Garlic clove', '3'),
        ('Rice', '1/2 cup'),
      ]) {
        expect(
          find.descendant(
            of: _key('shopping-item-${_row(rows, label).id}'),
            matching: find.text(text),
          ),
          findsOneWidget,
          reason: text,
        );
      }
      expect(find.text(_kept('Mo 1 can · Tu 1 can')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Cloves next to a name that does not count them, centimetres,
    // pinches (in the pantry), eighths and decimals.
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _plan(
        store,
        _own(
          'Würze',
          '2 Zehen Knoblauch\n1 cm Ingwer\n1 Prise Muskat\n'
              '1/8 Tasse Mandeln',
        ),
        0,
        MealSlot.dinner,
      );
      // An import for six, planned for one: a sixth of an onion, a third of
      // about two carrots; one for four planned for two halves a quarter.
      await _plan(
        store,
        recipeCatalogDe.first.copyWith(
          slug: 'user_import_salad',
          title: 'Salat',
          ingredients: '1 Zwiebel\nca. 2 Möhren\n3/4 Gurke',
          structuredIngredients: const [],
          categories: ['Eigene', '${recipeIngredientsBasisPrefix}per_recipe'],
          batchServings: 6,
        ),
        1,
        MealSlot.dinner,
      );
      await _plan(
        store,
        recipeCatalogDe.first.copyWith(
          slug: 'user_import_bowl',
          title: 'Bowl',
          ingredients: '1/4 Tasse Feta\n1 1/4 rote Zwiebeln',
          structuredIngredients: const [],
          categories: ['Eigene', '${recipeIngredientsBasisPrefix}per_recipe'],
          batchServings: 4,
        ),
        2,
        MealSlot.dinner,
        servings: 2,
      );
      await _pump(tester, store);
      final receipt = _receipt(store);
      String amountOf(String label) {
        final row = _key(
          'shopping-item-${_row([...receipt.rows, ...receipt.pantry], label).id}',
        );
        return tester
            .widgetList<Text>(
              find.descendant(of: row, matching: find.byType(Text)),
            )
            .map((t) => t.data)
            .elementAt(1)!;
      }

      expect(amountOf('Knoblauch'), '2 Zehen');
      expect(amountOf('Ingwer'), '1 cm');
      expect(amountOf('Mandeln'), '1/8 Tasse');
      expect(amountOf('Zwiebel'), '0,17');
      expect(amountOf('Möhren'), 'ca. 1/3');
      expect(amountOf('Gurke'), '1/8');
      expect(amountOf('Feta'), '1/8 Tasse');
      expect(amountOf('Rote Zwiebeln'), '5/8');
      await _tap(tester, _key('shopping-pantry-toggle'));
      expect(amountOf('Muskat'), '1 Prise');
      expect(tester.takeException(), isNull);
    });
  });

  for (final locale in ['de', 'en']) {
    testWidgets('320 px und 2x Text: Wochenliste mit Details und Vorrat '
        '$locale', (tester) async {
      await withClock(Clock.fixed(_today), () async {
        final store = _store();
        await _chickenWeek(store);
        await _plan(
          store,
          recipeCatalogDe.first.copyWith(
            slug: 'user_import_soup',
            title: 'Kartoffel-Lauch-Suppe',
            ingredients: '2 Stangen Lauch\n800 g Kartoffeln\nÖl zum Braten',
            structuredIngredients: const [],
            categories: ['Eigene', '${recipeIngredientsBasisPrefix}per_recipe'],
            batchServings: 4,
          ),
          3,
          MealSlot.dinner,
          servings: 2,
        );
        await _plan(store, _own('Resteessen', ''), 4, MealSlot.dinner);
        await _pump(
          tester,
          store,
          locale: Locale(locale),
          size: const Size(320, 850),
          textScale: 2,
        );
        final l10n = locale == 'de' ? deL10n : enL10n;
        final rows = _receipt(store, l10n: l10n).rows;
        final chicken = _row(rows, 'Hähnchenbrust');
        final row = _key('shopping-item-${chicken.id}');
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        // Large text: one meal per line, each amount whole.
        for (final entry in [
          'Mo 180\u00A0g',
          locale == 'de' ? 'Do 250\u00A0g' : 'Th 250\u00A0g',
        ]) {
          expect(
            find.descendant(of: row, matching: find.text(entry)),
            findsOneWidget,
            reason: entry,
          );
        }
        // Read as before: full weekdays.
        expect(
          tester.getSemantics(row).label,
          endsWith(
            locale == 'de'
                ? 'Montag 180 g, Donnerstag 250 g'
                : 'Monday 180 g, Thursday 250 g',
          ),
        );
        expect(tester.takeException(), isNull);
        await _tap(tester, _key('shopping-pantry-toggle'));
        expect(_key('shopping-pantry-summary'), findsNothing);
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -6000),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          _key('shopping-pantry-toggle'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(_key('shopping-pantry-toggle').hitTestable(), findsOneWidget);
        expect(tester.getSize(_key('shopping-pantry-toggle')).width, 280);
      });
    });
  }
}
