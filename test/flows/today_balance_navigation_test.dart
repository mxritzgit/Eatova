import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/main.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/widgets/kcal/slot_selector.dart';
import '../support/harness.dart' show pinPhoneViewport;
import 'flow_test_helpers.dart';

void main() {
  testWidgets(
    'Today add action opens Food with the chosen day and current slot',
    (tester) async {
      pinPhoneViewport(tester);
      tester.platformDispatcher.localesTestValue = const [Locale('de')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await withClock(Clock.fixed(DateTime(2026, 9, 11, 19)), () async {
        await tester.pumpWidget(
          EatovaApp(productService: FakeProductLookupService()),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('today-date-prev')));
        await tester.pumpAndSettle();
        expect(storeOf(tester).selectedFoodDate, DateTime(2026, 9, 10));
        await tester.tap(find.byKey(const ValueKey('today-add-meal')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);
        expect(
          tester.widget<SlotSelector>(find.byType(SlotSelector)).selected,
          MealSlot.dinner,
        );
        expect(storeOf(tester).selectedFoodDate, DateTime(2026, 9, 10));

        await tester.ensureVisible(
          find.byKey(const ValueKey('manual-entry-button')),
        );
        await tester.tap(find.byKey(const ValueKey('manual-entry-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('manual-meal-name')),
          'Testmahlzeit',
        );
        await tester.enterText(
          find.byKey(const ValueKey('manual-meal-kcal100')),
          '200',
        );
        await tester.enterText(
          find.byKey(const ValueKey('manual-meal-grams')),
          '150',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('manual-meal-save')),
        );
        await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
        await tester.pumpAndSettle();
        await expectTagestotalAufHeute(tester, '300');
        expect(storeOf(tester).loggedMeals.single.slot, MealSlot.dinner);
        expect(storeOf(tester).loggedMeals.single.loggedAt.day, 10);

        await tester.tap(find.byKey(const ValueKey('today-date-next')));
        await tester.pumpAndSettle();
        expectTodayEaten(tester, '0');
        expect(tester.takeException(), isNull);
      });
    },
  );
}
