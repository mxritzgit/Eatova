// The app's month grid in the "Choose day" sheet (design review X-16,
// 2026-10-11): it replaced Material's CalendarDatePicker, so what the stock
// widget did for free is pinned here: the locale's first weekday, only the
// weeks a month needs, the pickable range, paging, the spoken day names and
// keyboard use.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/kcal/food_date_picker.dart';

import '../../support/harness.dart';

final DateTime _today = DateTime(2026, 9, 28);

Finder _day(int month, int day) =>
    find.byKey(ValueKey('food-date-day-2026-$month-$day'));

Finder _key(String key) => find.byKey(ValueKey(key));

String _title(WidgetTester tester) =>
    tester.widget<Text>(_key('food-date-month-title')).data!;

/// The calendar with its own selection, as the sheet holds it.
Future<List<DateTime>> _pump(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  DateTime? selected,
  DateTime? firstDate,
  DateTime? lastDate,
}) async {
  pinPhoneViewport(tester);
  final picks = <DateTime>[];
  var current = selected ?? _today;
  await pumpLocalized(
    tester,
    StatefulBuilder(
      builder: (context, setState) => SingleChildScrollView(
        child: FoodMonthCalendar(
          selected: current,
          firstDate: firstDate ?? DateTime(2024, 9, 28),
          lastDate: lastDate ?? _today,
          today: _today,
          onSelected: (day) => setState(() {
            current = day;
            picks.add(day);
          }),
        ),
      ),
    ),
    locale: locale,
    settle: true,
  );
  return picks;
}

void main() {
  testWidgets('the locale sets the first weekday', (tester) async {
    // September 2026 starts on a Tuesday.
    await _pump(tester);
    final en = tester.getCenter(_day(9, 1)).dx;
    final sundayColumn = tester.getCenter(_day(9, 6)).dx;
    expect(en, greaterThan(sundayColumn), reason: 'en: Sunday comes first');

    await _pump(tester, locale: const Locale('de'));
    final mondayColumn = tester.getCenter(_day(9, 7)).dx;
    expect(
      tester.getCenter(_day(9, 1)).dx,
      greaterThan(mondayColumn),
      reason: 'de: Monday comes first, so the 1st sits in column two',
    );
    expect(
      tester.getCenter(_day(9, 6)).dx,
      greaterThan(tester.getCenter(_day(9, 5)).dx),
      reason: 'de: Sunday closes the week',
    );
  });

  testWidgets('only the weeks the month needs: no empty sixth row', (
    tester,
  ) async {
    // en, September 2026: two leading blanks + 30 days = five weeks.
    await _pump(tester);
    final five = tester.getSize(find.byType(FoodMonthCalendar)).height;
    // August 2026 starts on a Saturday: six weeks.
    await tester.tap(_key('food-date-month-previous'));
    await tester.pumpAndSettle();
    expect(_title(tester), 'August 2026');
    final six = tester.getSize(find.byType(FoodMonthCalendar)).height;
    expect(six - five, moreOrLessEquals(48, epsilon: 0.5));
  });

  testWidgets('days past lastDate are shown but do not pick; paging stops '
      'at the ends of the range', (tester) async {
    final picks = await _pump(
      tester,
      firstDate: DateTime(2026, 8, 20),
    );
    expect(
      tester.widget<IconButton>(_key('food-date-month-next')).onPressed,
      isNull,
      reason: 'lastDate is in this month',
    );
    await tester.tap(_day(9, 29));
    await tester.pumpAndSettle();
    expect(picks, isEmpty);

    await tester.tap(_day(9, 15));
    await tester.pumpAndSettle();
    expect(picks, [DateTime(2026, 9, 15)]);

    await tester.tap(_key('food-date-month-previous'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(_key('food-date-month-previous')).onPressed,
      isNull,
      reason: 'firstDate is in August',
    );
    await tester.tap(_day(8, 19));
    await tester.pumpAndSettle();
    expect(picks, hasLength(1), reason: 'the 19th is before firstDate');
    await tester.tap(_day(8, 20));
    await tester.pumpAndSettle();
    expect(picks.last, DateTime(2026, 8, 20));
  });

  testWidgets('a future range pages forward (meal plan)', (tester) async {
    await _pump(tester, lastDate: DateTime(2026, 10, 26));
    await tester.tap(_key('food-date-month-next'));
    await tester.pumpAndSettle();
    expect(_title(tester), 'October 2026');
    expect(
      tester.widget<IconButton>(_key('food-date-month-next')).onPressed,
      isNull,
    );
  });

  testWidgets('a sideways swipe pages back', (tester) async {
    await _pump(tester);
    await tester.fling(
      find.byType(FoodMonthCalendar),
      const Offset(300, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(_title(tester), 'August 2026');
  });

  testWidgets('every day is a button with its full date; today and the '
      'selection are said', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, selected: DateTime(2026, 9, 15));
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('15, Tuesday, September 15, 2026'),
      ),
      matchesSemantics(
        label: '15, Tuesday, September 15, 2026',
        isButton: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    expect(
      find.bySemanticsLabel('28, Monday, September 28, 2026, Today'),
      findsOneWidget,
    );
    // Past lastDate: still a button the reader finds, but disabled.
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('29, Tuesday, September 29, 2026'),
      ),
      isSemantics(
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    semantics.dispose();
  });

  testWidgets('the arrow keys move between days and Enter picks', (
    tester,
  ) async {
    final picks = await _pump(tester);
    Focus.of(tester.element(find.descendant(
      of: _day(9, 14),
      matching: find.byType(Text),
    ))).requestFocus();
    await tester.pump();

    bool focusedIn(Finder day) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      final target = tester.element(day);
      var inside = false;
      focused.visitAncestorElements((element) {
        if (element == target) inside = true;
        return !inside;
      });
      return inside;
    }

    expect(focusedIn(_day(9, 14)), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusedIn(_day(9, 15)), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedIn(_day(9, 22)), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picks, [DateTime(2026, 9, 22)]);
  });
}
