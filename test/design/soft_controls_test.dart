// Review follow-ups of the old-sheets redesign (2026-10-03): disabled chips
// say so, chips meet the 44 px floor, the source pill tells whether its
// details are open, and the day strip stops where a sheet's calendar stops.

import 'package:eatova/src/screens/today/today_day_strip.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  testWidgets('a chip without onTap is announced disabled and dimmed', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpLocalized(
        tester,
        const Row(
          children: [
            FilterChipPill(
              key: ValueKey('off'),
              label: 'Off',
              selected: false,
            ),
          ],
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Off')),
        isSemantics(isButton: true, isEnabled: false, hasEnabledState: true),
      );
      expect(
        find.ancestor(
          of: find.text('Off'),
          matching: find.byType(Opacity),
        ),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the source pill says whether its details are open', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      for (final open in [false, true]) {
        await pumpLocalized(
          tester,
          Row(
            children: [
              SourcePill(
                key: const ValueKey('source'),
                label: 'tiktok.com',
                onTap: () {},
                expanded: open,
              ),
            ],
          ),
        );
        expect(
          tester.getSemantics(find.byKey(const ValueKey('source'))),
          isSemantics(isButton: true, isExpanded: open, hasExpandedState: true),
        );
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the day strip stops at its first date', (tester) async {
    final today = DateTime(2026, 10, 3);
    final first = DateTime(2026, 9, 30);
    final picked = <DateTime>[];
    final semantics = tester.ensureSemantics();
    try {
      await pumpLocalized(
        tester,
        TodayDayStrip(
          selectedDate: today,
          today: today,
          firstDate: first,
          onSelected: picked.add,
        ),
        locale: const Locale('en'),
      );
      Finder day(DateTime d) =>
          find.byKey(ValueKey<String>('today-day-${localDayKey(d)}'));

      // Sep 27 to Oct 3 are shown; days before Sep 30 cannot be picked.
      await tester.tap(day(DateTime(2026, 9, 28)), warnIfMissed: false);
      await tester.tap(day(DateTime(2026, 9, 30)));
      expect(picked, [DateTime(2026, 9, 30)]);

      // No earlier week: the swipe and the screen-reader action stay put.
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('today-date-strip')))
            .getSemanticsData()
            .customSemanticsActionIds,
        isEmpty,
      );
      await tester.drag(
        find.byKey(const ValueKey('today-date-strip')),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();
      expect(day(DateTime(2026, 9, 27)), findsOneWidget);
      expect(day(DateTime(2026, 9, 20)), findsNothing);
    } finally {
      semantics.dispose();
    }
  });
}
