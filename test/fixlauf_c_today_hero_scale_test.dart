// Regression for system text scaling: detail text must never be shrunk.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/screens/today/today_hero.dart';
import 'support/harness.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('hero remains readable at $scale / $brightness', (
        tester,
      ) async {
        await pumpLocalized(
          tester,
          const SingleChildScrollView(
            child: TodayCalorieHero(
              consumedKcal: 12345,
              burnedKcal: 1234,
              kcalGoal: 2000,
              streak: 365,
            ),
          ),
          surfaceSize: const Size(320, 852),
          padding: const EdgeInsets.all(20),
          brightness: brightness,
          textScale: scale,
          settle: true,
        );
        expect(tester.takeException(), isNull);
        for (final key in [
          'today-stat-eaten',
          'today-stat-burned',
          'today-stat-streak',
        ]) {
          final text = find.byKey(ValueKey(key));
          expect(
            find.ancestor(of: text, matching: find.byType(FittedBox)),
            findsNothing,
          );
          final style = tester.widget<Text>(text).style!;
          expect(
            MediaQuery.textScalerOf(
              tester.element(text),
            ).scale(style.fontSize!),
            style.fontSize! * scale,
          );
        }
        final number = find.byKey(const ValueKey('today-kcal-remaining'));
        final fitted = find.ancestor(
          of: number,
          matching: find.byType(FittedBox),
        );
        expect(tester.widget<FittedBox>(fitted).fit, BoxFit.scaleDown);
        final ring = tester.getRect(
          find.byKey(const ValueKey('today-kcal-ring')),
        );
        final activity = tester.getRect(
          find.byKey(const ValueKey('today-stat-burned')),
        );
        expect(ring.top, greaterThan(activity.bottom));
        expect(find.text('100%'), findsOneWidget);
        expect(tester.getSize(find.text('100%')).width, lessThan(ring.width));
      });
    }
  }
}
