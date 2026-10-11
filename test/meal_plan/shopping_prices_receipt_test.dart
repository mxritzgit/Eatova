// The receipt with Open Prices estimates (docs/SHOPPING-PRICES.md): the
// price line under each row in every state, the sum and its note, no layout
// jump while prices arrive, checks unchanged, the region rule, cancellation
// when the receipt goes away, the attribution link and what a screen reader
// hears. Prices come from a scripted service.

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/shopping_price.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/fake_shopping_prices.dart';
import '../support/harness.dart';

/// Monday, so the shown week starts today.
final _now = DateTime(2026, 9, 28, 18, 30);
const _nb = ' ';

FitnessRecipe get _pizza => recipeCatalogDe.first.copyWith(
  title: 'Montag-Pizza',
  ingredients:
      '1 Packung Pizzateig\n125 g Mozzarella\n1 Prise Salz\nBasilikum\n'
      'Belag:\n250 g Butter',
  structuredIngredients: const [],
);

FitnessRecipe get _bowl => recipeCatalogEn.first.copyWith(
  ingredients: '',
  structuredIngredients: [
    RecipeIngredient(
      name: 'Rice',
      grams: 150,
      per100g: const RecipeNutrition(
        caloriesKcal: 350,
        proteinG: 8,
        carbsG: 75,
        fatG: 1,
      ),
    ),
  ],
);

LinePrice _outcome(PriceRequestLine line) => switch (line.label) {
  'Mozzarella' => fakeEstimate(53, median: 4.25),
  'Butter' => fakeEstimate(119),
  'Basilikum' => fakeEstimate(129, median: 2.58, kind: LinePriceKind.pack),
  'Salz' => const LinePriceSkipped(),
  'Rice' => fakeEstimate(60, median: 3.98),
  _ => const LinePriceNoData(),
};

Finder _key(String key) => find.byKey(ValueKey(key));

/// Mounts the planner on a phone whose region is [device], with [prices],
/// and opens the shopping list.
Future<HomeStore> _pump(
  WidgetTester tester, {
  FakeShoppingPriceService? prices,
  Locale locale = const Locale('de'),
  List<Locale> device = const [Locale('de', 'DE')],
}) async {
  tester.platformDispatcher.localesTestValue = device;
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
  );
  addTearDown(store.dispose);
  await store.savePlannedMeal(
    PlannedMeal.create(recipe: _pizza, day: _now, slot: MealSlot.dinner),
  );
  await store.savePlannedMeal(
    PlannedMeal.create(
      recipe: _bowl,
      day: _now.add(const Duration(days: 2)),
      slot: MealSlot.lunch,
    ),
  );
  await pumpLocalized(
    tester,
    MealPlanScreen(store: store, prices: prices),
    locale: locale,
    surfaceSize: const Size(390, 3000),
  );
  await tester.pumpAndSettle();
  await tester.tap(_key('meal-plan-tab-shopping'));
  await tester.pumpAndSettle();
  return store;
}

/// The receipt's lines as the screen builds them.
Map<String, String> _ids(HomeStore store) => {
  for (final line in priceRequestLines(
    buildShoppingList(store.plannedMeals, _now, decimalSeparator: ','),
  ))
    line.label: line.id,
};

String _text(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).data!;

String _total(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: _key('shopping-price-total'),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data)
    .join(' | ');

void main() {
  testWidgets('loading, then prices, "k. A.", "–" and a pack price; the sum '
      'is a subtotal while a line has no price', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final prices = FakeShoppingPriceService(priceOf: _outcome);
      final store = await _pump(tester, prices: prices);
      final ids = _ids(store);
      expect(prices.runs, hasLength(1));
      expect(prices.lastRun.region, PriceRegion.germany);
      expect(
        prices.lastRun.lines.map((l) => l.id),
        unorderedEquals(ids.values),
      );

      for (final id in ids.values) {
        expect(_text(tester, _key('shopping-price-$id')), '…');
      }
      expect(_total(tester), 'SUMME | …');
      expect(
        _text(tester, _key('shopping-price-note')),
        'Preise werden geladen …',
      );

      prices.lastRun.complete();
      await tester.pumpAndSettle();
      String price(String label) =>
          _text(tester, _key('shopping-price-${ids[label]}'));
      expect(price('Mozzarella'), '≈${_nb}0,53$_nb€');
      expect(price('Butter'), '≈${_nb}1,19$_nb€');
      expect(price('Basilikum'), '≈${_nb}1,29$_nb€/Pck.');
      expect(price('Salz'), '–');
      expect(price('Pizzateig'), 'k.${_nb}A.');
      expect(price('Rice'), '≈${_nb}0,60$_nb€');
      expect(find.text('Ø${_nb}4,25$_nb€/kg'), findsOneWidget);
      // 0.53 + 1.19 + 1.29 + 0.60, without the dough.
      expect(_total(tester), 'TEILSUMME | ≈${_nb}3,61$_nb€');
      expect(
        _text(tester, _key('shopping-price-note')),
        '1 Position ohne Preis',
      );
      expect(
        _text(
          tester,
          find.descendant(
            of: _key('shopping-price-source'),
            matching: find.textContaining('6 Wochen'),
          ),
        ),
        startsWith('Ø-Preise der letzten 6 Wochen in Deutschland'),
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('every line priced makes it a sum; a failure says so', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final prices = FakeShoppingPriceService(
        priceOf: (line) =>
            line.label == 'Pizzateig' ? fakeEstimate(149) : _outcome(line),
      );
      await _pump(tester, prices: prices);
      prices.lastRun.complete();
      await tester.pumpAndSettle();
      expect(_total(tester), 'SUMME | ≈${_nb}5,10$_nb€');
      expect(
        _text(tester, _key('shopping-price-note')),
        'Alle Positionen geschätzt',
      );
    });
  });

  testWidgets('a failed lookup shows "k. A." and a note, no sum', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final prices = FakeShoppingPriceService();
      await _pump(tester, prices: prices);
      prices.lastRun.fail();
      await tester.pumpAndSettle();
      expect(_total(tester), 'TEILSUMME | k.${_nb}A.');
      expect(
        _text(tester, _key('shopping-price-note')),
        'Preise gerade nicht abrufbar',
      );
    });
  });

  testWidgets('rows and totals keep their height while prices arrive', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      /// Every row's size in receipt order, then the sum's.
      Future<List<Size>> sizes() async {
        await tester.pumpAndSettle();
        final rows = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('shopping-item-'),
        );
        return [
          for (final element in rows.evaluate()) element.size!,
          tester.getSize(_key('shopping-price-total')),
        ];
      }

      final loaded = FakeShoppingPriceService(priceOf: _outcome);
      await _pump(tester, prices: loaded);
      final loading = await sizes();
      expect(loading.length, greaterThan(5));
      loaded.lastRun.complete();
      expect(await sizes(), loading);

      final failing = FakeShoppingPriceService();
      await _pump(tester, prices: failing);
      expect(await sizes(), loading);
      failing.lastRun.fail();
      expect(await sizes(), loading);
    });
  });

  testWidgets('checks toggle the same ids with prices shown', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final prices = FakeShoppingPriceService(priceOf: _outcome);
      final store = await _pump(tester, prices: prices);
      prices.lastRun.complete();
      await tester.pumpAndSettle();
      final id = _ids(store)['Mozzarella']!;
      await tester.tap(_key('shopping-item-$id'));
      await tester.pumpAndSettle();
      expect(store.shoppingChecks[id], isTrue);
      // A tick changes no line: no new lookup.
      expect(prices.runs, hasLength(1));
      // The price is struck through with its row.
      expect(
        tester.widget<Text>(_key('shopping-price-$id')).style!.decoration,
        TextDecoration.lineThrough,
      );
    });
  });

  testWidgets('English on a German device: prices in English', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final prices = FakeShoppingPriceService(priceOf: _outcome);
      final store = await _pump(
        tester,
        prices: prices,
        locale: const Locale('en'),
        device: const [Locale('en', 'US'), Locale('de', 'DE')],
      );
      prices.lastRun.complete();
      await tester.pumpAndSettle();
      final ids = _ids(store);
      expect(
        _text(tester, _key('shopping-price-${ids['Mozzarella']}')),
        '≈$_nb€0.53',
      );
      expect(_text(tester, _key('shopping-price-${ids['Pizzateig']}')), 'n/a');
      expect(find.text('avg$_nb€4.25/kg'), findsOneWidget);
      expect(_total(tester), 'SUBTOTAL | ≈$_nb€3.61');
      expect(
        _text(tester, _key('shopping-price-note')),
        '1 line without a price',
      );
    });
  });

  for (final device in const [
    [Locale('en', 'US')],
    [Locale('de', 'AT')],
  ]) {
    testWidgets('outside Germany ($device): no prices, no request', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final prices = FakeShoppingPriceService(priceOf: _outcome);
        await _pump(tester, prices: prices, device: device);
        expect(prices.runs, isEmpty);
        expect(_key('shopping-price-total'), findsNothing);
        expect(_key('shopping-price-source'), findsNothing);
        expect(find.textContaining('k.${_nb}A.'), findsNothing);
      });
    });
  }

  testWidgets('without a service the receipt is as before', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final store = await _pump(tester);
      for (final id in _ids(store).values) {
        expect(_key('shopping-price-$id'), findsNothing);
      }
      expect(_key('shopping-price-total'), findsNothing);
      expect(_key('shopping-price-source'), findsNothing);
      expect(_key('shopping-receipt'), findsOneWidget);
    });
  });

  testWidgets('another week, the week tab and leaving cancel the lookup', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final prices = FakeShoppingPriceService();
      await _pump(tester, prices: prices);
      expect(prices.lastRun.cancelled, isFalse);

      await tester.tap(_key('meal-plan-next-week'));
      await tester.pumpAndSettle();
      expect(prices.runs.first.cancelled, isTrue);
      // An empty week asks nothing.
      expect(prices.runs, hasLength(1));
      await tester.tap(_key('meal-plan-previous-week'));
      await tester.pumpAndSettle();
      expect(prices.runs, hasLength(2));

      await tester.tap(_key('meal-plan-tab-week'));
      await tester.pumpAndSettle();
      expect(prices.runs[1].cancelled, isTrue);
    });
  });

  testWidgets('closing the planner cancels the lookup', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final store = HomeStore(
        sync: null,
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'Fixture',
        emitSnack: h.SnackCapture().call,
      );
      addTearDown(store.dispose);
      await store.savePlannedMeal(
        PlannedMeal.create(recipe: _pizza, day: _now, slot: MealSlot.dinner),
      );
      final prices = FakeShoppingPriceService();
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                MealPlanScreen.open(context, store, prices: prices),
            child: const Text('open'),
          ),
        ),
        surfaceSize: const Size(390, 3000),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(_key('meal-plan-tab-shopping'));
      await tester.pumpAndSettle();
      expect(prices.runs, hasLength(1));
      await tester.tap(_key('meal-plan-back'));
      await tester.pumpAndSettle();
      expect(find.byType(MealPlanScreen), findsNothing);
      expect(prices.lastRun.cancelled, isTrue);
    });
  });

  testWidgets('the source note opens Open Prices', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final launched = <String>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'launch') return null;
        launched.add(
          (call.arguments as Map<Object?, Object?>)['url']! as String,
        );
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final prices = FakeShoppingPriceService(priceOf: _outcome);
      await _pump(tester, prices: prices);
      await tester.tap(_key('shopping-price-source'));
      await tester.pumpAndSettle();
      expect(launched, ['https://prices.openfoodfacts.org']);
      expect(
        tester.getSize(_key('shopping-price-source')).height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  testWidgets('a screen reader hears the estimate, not the symbols', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await withClock(Clock.fixed(_now), () async {
      final prices = FakeShoppingPriceService(priceOf: _outcome);
      final store = await _pump(tester, prices: prices);
      final ids = _ids(store);
      final loading = tester.getSemantics(
        _key('shopping-item-${ids['Mozzarella']}'),
      );
      expect(loading.label, contains('Preis wird geladen'));
      prices.lastRun.complete();
      await tester.pumpAndSettle();
      String label(String name) =>
          tester.getSemantics(_key('shopping-item-${ids[name]}')).label;
      expect(label('Mozzarella'), contains('etwa 0,53$_nb€'));
      expect(label('Mozzarella'), isNot(contains('Ø')));
      expect(label('Pizzateig'), contains('kein aktueller Preis'));
      expect(label('Salz'), contains('nicht geschätzt'));
      expect(
        tester.getSemantics(_key('shopping-price-source')),
        isSemantics(
          isLink: true,
          hasTapAction: true,
          hint: 'Öffnet Open Prices im Browser',
        ),
      );
    });
    semantics.dispose();
  });
}
