import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/food_page_chrome.dart';

import 'support/harness.dart';

final _day = DateTime(2026, 9, 11);

LoggedMeal _meal(
  int index, {
  String? name,
  MealSlot slot = MealSlot.breakfast,
}) => LoggedMeal(
  id: 'meal-$index',
  forcedSlot: slot,
  loggedAt: DateTime(2026, 9, 11, 8, index),
  result: MealAnalysisResult(
    mealName: name ?? 'Food $index',
    caloriesKcal: 100 + index,
    estimatedGrams: 100,
    kcalPer100G: 100 + index.toDouble(),
    protein: '10 g',
    carbs: '12 g',
    fat: '3 g',
    confidence: '',
    portionNotes: '',
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  List<LoggedMeal> meals = const [],
  double width = 390,
  double height = 760,
  double scale = 1,
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
  bool loading = false,
  ValueChanged<DateTime>? onDate,
  String Function(MealAnalysisResult, MealSlot)? onAdd,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  await pumpLocalized(
    tester,
    MealAnalysisScreen(
      dailyConsumedKcal: meals.fold(0, (sum, m) => sum + m.result.caloriesKcal),
      loggedMeals: meals,
      selectedDate: _day,
      onDateSelected: onDate,
      dayLoading: loading,
      onAddMeal: onAdd,
    ),
    brightness: brightness,
    locale: locale,
    textScale: scale,
    settle: !loading,
  );
}

void main() {
  for (final action in ['profile', 'settings']) {
    testWidgets(
      'The $action menu selection survives a responsive layout change',
      (tester) async {
        await withClock(Clock.fixed(_day), () async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 760);
          addTearDown(tester.view.reset);
          String? chosen;
          await pumpLocalized(
            tester,
            MealAnalysisScreen(
              dailyConsumedKcal: 0,
              selectedDate: _day,
              onProfilePressed: () => chosen = 'profile',
              onSettingsPressed: () => chosen = 'settings',
            ),
          );
          await tester.tap(find.byKey(const ValueKey('food-options')));
          await tester.pumpAndSettle();
          tester.view.physicalSize = const Size(390, 540);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('topbar-$action')));
          await tester.pumpAndSettle();
          expect(chosen, action);
          expect(tester.takeException(), isNull);
        });
      },
    );
  }

  for (final loading in [false, true]) {
    testWidgets(
      'The capture dock touches the bottom even with spare height (loading=$loading)',
      (tester) async {
        await withClock(Clock.fixed(_day), () async {
          await _pump(tester, height: 900, loading: loading);
          expect(
            tester
                .getBottomLeft(find.byKey(const ValueKey('food-entry-dock')))
                .dy,
            closeTo(900, 0.1),
          );
          expect(tester.takeException(), isNull);
        });
      },
    );
  }

  testWidgets(
    'An open calendar still selects its day after the Food layout resizes',
    (tester) async {
      await withClock(Clock.fixed(_day), () async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 760);
        addTearDown(tester.view.reset);
        var selected = _day;
        await pumpLocalized(
          tester,
          StatefulBuilder(
            builder: (context, setState) => MealAnalysisScreen(
              dailyConsumedKcal: 0,
              selectedDate: selected,
              onDateSelected: (day) => setState(() => selected = day),
            ),
          ),
          locale: const Locale('en'),
        );
        await tester.tap(find.byKey(const ValueKey('food-date-calendar')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(390, 540);
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(selected, DateTime(2026, 9, 10));
        expect(find.byType(DatePickerDialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'A narrow short viewport keeps every meal and capture reachable',
    (tester) async {
      await withClock(Clock.fixed(_day), () async {
        await _pump(
          tester,
          width: 320,
          height: 500,
          scale: 1.4,
          locale: const Locale('de'),
        );
        expect(tester.takeException(), isNull);
        for (final key in [
          'food-slot-add-breakfast',
          'food-slot-add-snack',
          'food-action-manual',
        ]) {
          final target = find.byKey(ValueKey(key));
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          expect(target.hitTestable(), findsOneWidget, reason: key);
        }
      });
    },
  );

  testWidgets(
    'Resizing for another tab keyboard preserves expanded diary and scroll',
    (tester) async {
      await withClock(Clock.fixed(_day), () async {
        await _pump(tester, meals: List.generate(10, _meal));
        await tester.tap(
          find.byKey(const ValueKey('food-slot-toggle-breakfast')),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('food-diary-scroll')),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        ScrollPosition position() => tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byKey(const ValueKey('food-diary-scroll')),
                matching: find.byType(Scrollable),
              ),
            )
            .position;
        final offset = position().pixels;
        expect(offset, greaterThan(100));
        tester.view.physicalSize = const Size(390, 400);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('food-history-entry-9')),
          findsOneWidget,
        );
        tester.view.physicalSize = const Size(390, 760);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('food-history-entry-9')),
          findsOneWidget,
        );
        expect(position().pixels, closeTo(offset, 0.1));
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'Changing the day resets the diary scroll and expanded sections',
    (tester) async {
      await withClock(Clock.fixed(_day), () async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 760);
        addTearDown(tester.view.reset);
        var selected = _day;
        await pumpLocalized(
          tester,
          StatefulBuilder(
            builder: (context, setState) => MealAnalysisScreen(
              dailyConsumedKcal: selected == _day ? 1045 : 0,
              selectedDate: selected,
              loggedMeals: List.generate(10, _meal),
              onDateSelected: (day) => setState(() => selected = day),
            ),
          ),
          locale: const Locale('en'),
        );
        await tester.tap(
          find.byKey(const ValueKey('food-slot-toggle-breakfast')),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('food-diary-scroll')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('food-date-previous')));
        await tester.pumpAndSettle();
        final scroll = tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byKey(const ValueKey('food-diary-scroll')),
                matching: find.byType(Scrollable),
              ),
            )
            .position;
        expect(scroll.pixels, 0);
        expect(
          find.byKey(const ValueKey('food-slot-add-breakfast')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('food-date-next')));
        await tester.pumpAndSettle();
        expect(find.text('10 entries'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('food-history-entry-0')),
          findsNothing,
        );
      });
    },
  );

  testWidgets(
    'Ten breakfast entries stay compact and every entry can be revealed',
    (tester) async {
      await withClock(Clock.fixed(_day), () async {
        await _pump(tester, meals: List.generate(10, _meal));
        expect(find.text('10 entries'), findsOneWidget);
        expect(find.text('1,045'), findsNWidgets(2));
        expect(
          find.byKey(const ValueKey('food-history-entry-9')),
          findsNothing,
        );
        final dock = find.byKey(const ValueKey('food-entry-dock'));
        final dockTop = tester.getTopLeft(dock).dy;
        expect(dockTop, greaterThan(550));
        expect(
          find.byKey(const ValueKey('food-slot-add-lunch')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('food-slot-toggle-breakfast')),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 10; i++) {
          expect(find.text('Food $i'), findsOneWidget);
          expect(find.byKey(ValueKey('food-history-entry-$i')), findsOneWidget);
        }
        await tester.drag(
          find.byKey(const ValueKey('food-diary-scroll')),
          const Offset(0, -500),
        );
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(dock).dy, dockTop);
        await tester.ensureVisible(
          find.byKey(const ValueKey('food-slot-add-breakfast')),
        );
        await tester.tap(find.byKey(const ValueKey('food-slot-add-breakfast')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('slot-select-breakfast')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'Long expanded entries reflow at 320 px and 2x text ($brightness)',
      (tester) async {
        await withClock(Clock.fixed(_day), () async {
          const longName =
              'Vollkornbrot mit Frischkäse, gerösteten Tomaten und frischem Basilikum';
          await _pump(
            tester,
            meals: [
              _meal(1, name: longName),
              _meal(2),
            ],
            width: 320,
            scale: 2,
            brightness: brightness,
            locale: const Locale('de'),
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('food-slot-toggle-breakfast')),
          );
          await tester.tap(
            find.byKey(const ValueKey('food-slot-toggle-breakfast')),
          );
          await tester.pumpAndSettle();
          final fullTitle = tester.widget<Text>(find.text(longName));
          expect(fullTitle.maxLines, isNull);
          await tester.ensureVisible(
            find.byKey(const ValueKey('food-action-manual')),
          );
          expect(
            find.byKey(const ValueKey('food-action-manual')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        });
      },
    );
  }

  testWidgets('Loading a day never presents stale totals or entry actions', (
    tester,
  ) async {
    await withClock(Clock.fixed(_day), () async {
      await _pump(tester, meals: [_meal(1)], loading: true);
      expect(find.byKey(const ValueKey('food-day-loading')), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('101'), findsNothing);
      expect(find.byKey(const ValueKey('food-history')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('food-search')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('kcal-product-search-input')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Day arrows cross year boundaries and cannot select the future', (
    tester,
  ) async {
    await withClock(Clock.fixed(DateTime(2026, 1, 1)), () async {
      var day = DateTime(2026, 1, 1);
      await pumpLocalized(
        tester,
        StatefulBuilder(
          builder: (context, setState) => FoodDayNavigation(
            onCalendar: () {},
            day: day,
            label: '${day.year}-${day.month}-${day.day}',
            onSelected: (value) => setState(() => day = value),
          ),
        ),
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('food-date-next')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('food-date-previous')));
      await tester.pump();
      expect(day, DateTime(2025, 12, 31));
      await tester.tap(find.byKey(const ValueKey('food-date-next')));
      await tester.pump();
      expect(day, DateTime(2026, 1, 1));
    });
  });

  testWidgets(
    'Manual dock entry lets the user choose the meal and saves only on confirmation',
    (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 11, 20)), () async {
        final added = <(MealAnalysisResult, MealSlot)>[];
        await _pump(
          tester,
          onAdd: (result, slot) {
            added.add((result, slot));
            return 'new-meal';
          },
        );
        await tester.tap(find.byKey(const ValueKey('food-action-manual')));
        await tester.pumpAndSettle();
        expect(added, isEmpty);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('manual-meal-sheet')),
            matching: find.text('Friday, September 11'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('manual-slot-breakfast')));
        await tester.enterText(
          find.byKey(const ValueKey('manual-meal-name')),
          'Homemade granola',
        );
        await tester.enterText(
          find.byKey(const ValueKey('manual-meal-kcal100')),
          '450',
        );
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('manual-meal-save')),
        );
        await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
        await tester.pumpAndSettle();
        expect(added.single.$2, MealSlot.breakfast);
        expect(added.single.$1.mealName, 'Homemade granola');
        expect(added.single.$1.caloriesKcal, 450);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets('Expanded meals keep the real edit route and stable identity', (
    tester,
  ) async {
    await withClock(Clock.fixed(_day), () async {
      var removed = '';
      final meals = List.generate(10, _meal);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 760);
      addTearDown(tester.view.reset);
      await pumpLocalized(
        tester,
        MealEditScope(
          onUpdateMeal: (id, {result, slot, day}) => null,
          onRemoveMeal: (id) => removed = id,
          child: MealAnalysisScreen(
            dailyConsumedKcal: 1045,
            loggedMeals: meals,
            selectedDate: _day,
          ),
        ),
        locale: const Locale('en'),
        settle: true,
      );
      await tester.tap(
        find.byKey(const ValueKey('food-slot-toggle-breakfast')),
      );
      await tester.pumpAndSettle();
      final oldest = find.byKey(const ValueKey('food-history-entry-9'));
      await tester.ensureVisible(oldest);
      await tester.tap(oldest);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
      expect(removed, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
