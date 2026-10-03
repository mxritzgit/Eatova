// The lively favorites row (owner request 2026-10-03): the product photo of
// a favorite, the saved portion with kcal and macros at a glance, and a
// one-tap "+" that logs the saved portion into the sheet's meal.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';

import 'support/harness.dart';

const _photo =
    'https://images.openfoodfacts.org/images/products/400/054/000/0108/front_de.273.200.jpg';

MealAnalysisResult _bar({String? image = _photo}) => MealAnalysisResult(
  mealName: 'Proteinriegel Cookie · Bodylab',
  caloriesKcal: 212,
  estimatedGrams: 60,
  kcalPer100G: 353,
  protein: '20 g',
  carbs: '18 g',
  fat: '7 g',
  confidence: 'database',
  portionNotes: '',
  sourceLabel: 'open_food_facts',
  barcode: '4000540000108',
  brand: 'Bodylab',
  imageUrl: image,
);

const _oats = MealAnalysisResult(
  mealName: 'Overnight Oats',
  caloriesKcal: 412,
  estimatedGrams: 320,
  kcalPer100G: 128.75,
  protein: '-',
  carbs: '-',
  fat: '-',
  confidence: 'manual',
  portionNotes: '',
);

FavoriteMeal _fav(MealAnalysisResult result, int day) => FavoriteMeal(
  id: FavoriteMeal.idFor(result),
  result: result,
  addedAt: DateTime(2026, 10, day),
  pinned: true,
);

typedef _Added = ({MealAnalysisResult result, MealSlot slot});

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<FavoriteMeal> favorites,
  FutureOr<String> Function(MealAnalysisResult, MealSlot)? onAdd,
  Map<String, int> useCounts = const <String, int>{},
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  Size size = const Size(390, 844),
}) async {
  await pumpLocalized(
    tester,
    FavoritesSheet(
      favorites: favorites,
      slot: MealSlot.lunch,
      onAdd: onAdd ?? (_, __) => 'id',
      onUnpin: (_) {},
      useCounts: useCounts,
    ),
    locale: locale,
    textScale: textScale,
    surfaceSize: size,
    safeArea: false,
  );
  await tester.pump();
}

Finder _row(int i) => find.byKey(ValueKey('favorites-sheet-item-$i'));

Finder _quick(int i) => find.byKey(ValueKey('favorites-sheet-quick-$i'));

/// Lets the just-added check (2 s) and the toast expire.
Future<void> _expireTimers(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 5));

void main() {
  testWidgets('a favorite with a photo shows it, one without the letter', (
    tester,
  ) async {
    await _pumpSheet(tester, favorites: [_fav(_bar(), 3), _fav(_oats, 2)]);

    final photo = find.descendant(
      of: _row(0),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is ResizeImage &&
            ((w.image as ResizeImage).imageProvider as NetworkImage).url ==
                _photo,
      ),
    );
    expect(photo, findsOneWidget);
    expect(
      find.descendant(of: _row(1), matching: find.byType(Image)),
      findsNothing,
    );
    expect(
      find.descendant(of: _row(1), matching: find.text('O')),
      findsOneWidget,
    );
  });

  testWidgets('a photo that fails to load falls back to the letter', (
    tester,
  ) async {
    await _pumpSheet(tester, favorites: [_fav(_bar(), 3)]);
    // The test HTTP client answers 400: the image provider reports an error.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(
      find.descendant(of: _row(0), matching: find.text('P')),
      findsOneWidget,
    );
  });

  testWidgets('the row shows portion, kcal and macros of the saved portion', (
    tester,
  ) async {
    await _pumpSheet(tester, favorites: [_fav(_bar(), 3)]);
    expect(
      find.descendant(of: _row(0), matching: find.text('Proteinriegel Cookie')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row(0),
        matching: find.text('Bodylab · 60 g · 212 kcal', findRichText: true),
      ),
      findsOneWidget,
    );
    for (final macro in ['P 20 g', 'C 18 g', 'F 7 g']) {
      expect(
        find.descendant(of: _row(0), matching: find.text(macro)),
        findsOneWidget,
        reason: macro,
      );
    }
  });

  testWidgets('"+" logs the saved portion once into the sheet slot', (
    tester,
  ) async {
    final added = <_Added>[];
    final pending = Completer<String>();
    final bar = _bar();
    await _pumpSheet(
      tester,
      favorites: [_fav(bar, 3)],
      onAdd: (result, slot) {
        added.add((result: result, slot: slot));
        return pending.future;
      },
    );

    await tester.tap(_quick(0));
    await tester.pump();
    // A second tap while the first add is still saving adds nothing.
    await tester.tap(_quick(0));
    await tester.pump();
    expect(added, hasLength(1));
    expect(identical(added.single.result, bar), isTrue);
    expect(added.single.slot, MealSlot.lunch);

    pending.complete('logged-1');
    await tester.pump();
    await tester.pump();
    expect(find.text('Added 212 kcal to Lunch.'), findsOneWidget);
    expect(find.byKey(const ValueKey('meal-item-added-check')), findsOneWidget);
    await _expireTimers(tester);
  });

  testWidgets('the open row has only the panel add', (tester) async {
    await _pumpSheet(tester, favorites: [_fav(_bar(), 3)]);
    expect(_quick(0), findsOneWidget);
    await tester.tap(find.text('Proteinriegel Cookie'));
    await tester.pumpAndSettle();
    expect(_quick(0), findsNothing);
    expect(find.byKey(const ValueKey('favorites-sheet-add-0')), findsOneWidget);
  });

  testWidgets('"+" says what it adds, and both actions are 44 px', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final added = <String>[];
      await _pumpSheet(
        tester,
        favorites: [_fav(_bar(), 3), _fav(_oats, 2)],
        onAdd: (result, _) {
          added.add(result.mealName);
          return 'id';
        },
      );
      expect(
        tester.getSemantics(_quick(0)),
        isSemantics(
          label: 'Add Proteinriegel Cookie, 212 kcal, to Lunch',
          isButton: true,
          hasTapAction: true,
        ),
      );
      tester.semantics.performAction(
        find.semantics.byLabel('Add Overnight Oats, 412 kcal, to Lunch'),
        SemanticsAction.tap,
      );
      await tester.pump();
      await tester.pump();
      expect(added, ['Overnight Oats'], reason: 'the screen reader tap adds');
      for (final key in ['favorites-sheet-quick-0', 'favorites-sheet-fav-0']) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(44), reason: key);
        expect(size.height, greaterThanOrEqualTo(44), reason: key);
      }
      await _expireTimers(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('"+" on a row without known kcal logs nothing and says why', (
    tester,
  ) async {
    final added = <MealAnalysisResult>[];
    const unknown = MealAnalysisResult(
      mealName: 'Altes Müsli',
      caloriesKcal: 0,
      estimatedGrams: 80,
      kcalPer100G: 0,
      protein: '-',
      carbs: '-',
      fat: '-',
      confidence: 'medium',
      portionNotes: '',
    );
    await _pumpSheet(
      tester,
      favorites: [_fav(unknown, 3)],
      onAdd: (result, _) {
        added.add(result);
        return 'id';
      },
    );
    await tester.tap(_quick(0));
    await tester.pump();
    expect(added, isEmpty);
    expect(
      find.textContaining("This can't be logged without a calorie value."),
      findsOneWidget,
    );
    await _expireTimers(tester);
  });

  for (final locale in ['de', 'en']) {
    testWidgets('320 px at 2x text without overflow ($locale)', (tester) async {
      await _pumpSheet(
        tester,
        favorites: [_fav(_bar(), 3), _fav(_oats, 2)],
        locale: Locale(locale),
        textScale: 2,
        size: const Size(320, 640),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_quick(0), findsOneWidget);
    });
  }

  group('sorting', () {
    MealAnalysisResult meal(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 100,
      estimatedGrams: 100,
      kcalPer100G: 100,
      protein: '-',
      carbs: '-',
      fat: '-',
      confidence: 'manual',
      portionNotes: '',
    );
    final favorites = [
      _fav(meal('Skyr'), 3),
      _fav(meal('Banane'), 2),
      _fav(meal('Äpfel'), 1),
    ];
    List<String> order(WidgetTester tester) => [
      for (var i = 0; i < 3; i++)
        if (_row(i).evaluate().isNotEmpty)
          tester
              .widgetList<Text>(
                find.descendant(of: _row(i), matching: find.byType(Text)),
              )
              .firstWhere((text) => text.data != null)
              .data!,
    ];

    testWidgets('chips sort by recent, frequent and name', (tester) async {
      await _pumpSheet(
        tester,
        favorites: favorites,
        useCounts: const {'name:banane': 5, 'name:äpfel': 2},
      );
      expect(order(tester), ['Skyr', 'Banane', 'Äpfel']);

      await tester.tap(
        find.byKey(const ValueKey('favorites-sheet-sort-frequent')),
      );
      await tester.pumpAndSettle();
      expect(order(tester), ['Banane', 'Äpfel', 'Skyr']);

      await tester.tap(
        find.byKey(const ValueKey('favorites-sheet-sort-alphabetical')),
      );
      await tester.pumpAndSettle();
      expect(order(tester), ['Äpfel', 'Banane', 'Skyr']);

      // The search filters within the chosen order.
      await tester.enterText(
        find.byKey(const ValueKey('favorites-sheet-search')),
        'a',
      );
      await tester.pumpAndSettle();
      expect(order(tester), ['Banane']);
    });

    testWidgets('fast chip changes keep one list that takes the taps', (
      tester,
    ) async {
      // Motion on: the fade is what a fast second change interrupts.
      await pumpLocalized(
        tester,
        FavoritesSheet(
          favorites: favorites,
          slot: MealSlot.lunch,
          onAdd: (_, __) => 'id',
          onUnpin: (_) {},
        ),
        locale: const Locale('en'),
        reducedMotion: false,
        surfaceSize: const Size(390, 844),
        safeArea: false,
      );
      await tester.pump();
      for (final key in ['frequent', 'recent', 'frequent']) {
        await tester.tap(find.byKey(ValueKey('favorites-sheet-sort-$key')));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(tester.takeException(), isNull);
      expect(_row(0), findsOneWidget, reason: 'one list, never two');
      await tester.pumpAndSettle();
      expect(order(tester), ['Skyr', 'Banane', 'Äpfel']);
    });

    testWidgets('the chosen chip is announced as selected', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _pumpSheet(tester, favorites: favorites);
        expect(
          tester.getSemantics(
            find.byKey(const ValueKey('favorites-sheet-sort-recent')),
          ),
          isSemantics(isButton: true, isSelected: true, label: 'Recent'),
        );
        await tester.tap(
          find.byKey(const ValueKey('favorites-sheet-sort-frequent')),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(
            find.byKey(const ValueKey('favorites-sheet-sort-frequent')),
          ),
          isSemantics(isSelected: true, label: 'Frequent'),
        );
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('one favorite needs no sorting; the slot line stays', (
      tester,
    ) async {
      await _pumpSheet(tester, favorites: [_fav(meal('Skyr'), 3)]);
      expect(
        find.byKey(const ValueKey('favorites-sheet-sort-recent')),
        findsNothing,
      );
      expect(find.text('For Lunch'), findsOneWidget);
      expect(
        find.text('Your go-to meals, ready for another day.'),
        findsNothing,
      );
    });
  });
}
