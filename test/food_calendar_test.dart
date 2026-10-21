import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clock/clock.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';
import 'package:eatova/src/widgets/kcal/food_page_chrome.dart';

import 'support/harness.dart';

// Calendar access to older days in the food tab: a calendar button next to
// the date chips whose selection runs through the same onDateSelected path as
// the chips. Plus the states of on-demand days: dayLoading replaces the
// history with slot silhouettes, a failed load says so and offers a retry.
//
// No `renderMatrix` here: nothing in this file is duplicated per brightness,
// locale or text scale — it is one dark-mode flow per state. Viewport pinning
// and overflow tolerance come from the harness's `testWidgetsRobust`.

/// Food tab harness in the same shell as EatovaHomePage.
Future<void> _pumpFoodTab(
  WidgetTester tester, {
  ValueChanged<DateTime>? onDateSelected,
  bool dayLoading = false,
  bool dayLoadFailed = false,
  VoidCallback? onRetryDayLoad,
  DateTime? selectedDate,
}) async {
  await pumpLocalized(
    tester,
    MealAnalysisScreen(
      dailyConsumedKcal: 0,
      selectedDate: selectedDate,
      onDateSelected: onDateSelected,
      dayLoading: dayLoading,
      dayLoadFailed: dayLoadFailed,
      onRetryDayLoad: onRetryDayLoad,
    ),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );
  // With dayLoading the spinner never stops, so pumpAndSettle would never
  // settle: pump a bounded amount instead.
  if (dayLoading) {
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgetsRobust(
    'Kalender-Knopf oeffnet deutschen DatePicker; Auswahl laeuft durch den '
    'Chip-Callback (onDateSelected)',
    (WidgetTester tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 14)), () async {
        DateTime? selected;
        await _pumpFoodTab(tester, onDateSelected: (d) => selected = d);

        expect(
          find.byKey(const ValueKey('food-date-calendar')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('food-date-calendar')));
        await tester.pumpAndSettle();

        // Localized calendar sheet with explicit confirmation.
        expect(find.byKey(const ValueKey('food-date-picker')), findsOneWidget);
        expect(find.text('Tag wählen'), findsOneWidget);
        expect(find.byKey(const ValueKey('food-date-close')), findsOneWidget);

        // Page to the PREVIOUS month and pick the 15th: it exists in every month,
        // is always in the past (lastDate = today never bites) and never collides
        // with the today special case.
        await tester.tap(
          find.byKey(const ValueKey('food-date-month-previous')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(FoodMonthCalendar),
            matching: find.text('15'),
          ),
        );
        await tester.pumpAndSettle();
        expect(selected, isNull);
        await tester.tap(find.byKey(const ValueKey('food-date-confirm')));
        await tester.pumpAndSettle();

        final today = DateUtils.dateOnly(clock.now());
        expect(selected, DateTime(today.year, today.month - 1, 15));
        expect(find.byKey(const ValueKey('food-date-picker')), findsNothing);
      });
    },
  );

  testWidgetsRobust(
    'dayLoading zeigt die Slot-Silhouetten statt der Verlaufskarte',
    (WidgetTester tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpFoodTab(tester, dayLoading: true);

      final laden = find.byKey(const ValueKey('food-day-loading'));
      expect(laden, findsOneWidget);
      // One silhouette per slot card, no spinner of its own.
      expect(
        find.descendant(of: laden, matching: find.byType(SkeletonCard)),
        findsNWidgets(MealSlot.values.length),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // History slots are absent while loading; the state is one label.
      expect(find.byKey(const ValueKey('food-history')), findsNothing);
      expect(find.bySemanticsLabel('Tag wird geladen…'), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgetsRobust(
    'FOOD-8: a failed archive day says it is not loaded instead of empty, '
    'offers a retry and keeps the dock usable',
    (WidgetTester tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 14, 12)), () async {
        var retries = 0;
        await _pumpFoodTab(
          tester,
          selectedDate: DateTime(2026, 7, 1),
          dayLoadFailed: true,
          onRetryDayLoad: () => retries++,
        );

        final card = find.byKey(const ValueKey('food-day-load-failed'));
        expect(card, findsOneWidget);
        expect(find.text('Dieser Tag konnte nicht geladen werden'),
            findsOneWidget);
        // No slot claims the day is empty; each says it is not loaded.
        expect(find.text('Noch nichts eingetragen'), findsNothing);
        expect(find.text('Nicht geladen'),
            findsNWidgets(MealSlot.values.length));
        // The dock stays enabled: the card is the signal, not a lock.
        expect(
          tester.widget<FoodEntryDock>(find.byType(FoodEntryDock)).enabled,
          isTrue,
        );

        await tester.ensureVisible(
          find.byKey(const ValueKey('food-day-load-retry')),
        );
        await tester.tap(find.byKey(const ValueKey('food-day-load-retry')));
        await tester.pump();
        expect(retries, 1);
      });
    },
  );

  testWidgetsRobust('FOOD-8: a retry in flight shows the loading state', (
    WidgetTester tester,
  ) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 14, 12)), () async {
      await _pumpFoodTab(
        tester,
        selectedDate: DateTime(2026, 7, 1),
        dayLoading: true,
        dayLoadFailed: true,
      );
      expect(find.byKey(const ValueKey('food-day-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-day-load-failed')), findsNothing);
    });
  });
}
