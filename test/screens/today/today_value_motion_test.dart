// The calorie card's values move to their new state (motion polish,
// 2026-10-01): the arc sweeps and the numbers count from the value on screen
// instead of jumping, and end exactly on the new day numbers. Reduced motion
// shows the end state at once.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_hero.dart';
import 'package:eatova/src/screens/today/today_progress.dart';

import '../../support/harness.dart';
import '../../support/today_summary.dart';

const UserProfile _profile = UserProfile(dailyKcalGoal: 2000);

Widget _card(int eaten) => SizedBox(
  width: 360,
  child: TodayCalorieCard(
    summary: todaySummary(profile: _profile, consumedKcal: eaten),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  int eaten, {
  bool reducedMotion = false,
}) => pumpLocalized(
  tester,
  _card(eaten),
  locale: const Locale('en'),
  reducedMotion: reducedMotion,
);

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// The on-screen text of [key], also while it is a rich text in flight.
String _text(WidgetTester tester, String key) {
  final text = tester.widget<Text>(find.byKey(ValueKey<String>(key)));
  return text.data ?? text.textSpan!.toPlainText();
}

int _number(WidgetTester tester, String key) =>
    int.parse(_text(tester, key).replaceAll(RegExp(r'[^0-9]'), ''));

double _arc(WidgetTester tester) =>
    (tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(TodayCalorieArc),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as TodayArcPainter)
        .progress;

void main() {
  testWidgets('beim ersten Zeigen fuellt sich der Bogen und "uebrig" zaehlt '
      'vom Budget herunter', (tester) async {
    await _pump(tester, 500);
    // First frame: nothing eaten yet on screen, the whole budget left.
    expect(_arc(tester), 0);
    expect(_number(tester, 'today-kcal-remaining'), 2000);
    expect(_number(tester, 'today-kcal-percent'), 0);

    await _frames(tester, 10);
    expect(_arc(tester), inExclusiveRange(0, 0.25));
    expect(
      _number(tester, 'today-kcal-remaining'),
      inExclusiveRange(1500, 2000),
    );

    await tester.pumpAndSettle();
    expect(_arc(tester), 0.25);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('today-kcal-remaining')))
          .data,
      '1,500',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('today-kcal-percent')))
          .data,
      '25% eaten',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('today-stat-eaten'))).data,
      '500',
    );
  });

  testWidgets('ein neuer Wert laeuft vom angezeigten aus und endet exakt', (
    tester,
  ) async {
    await _pump(tester, 500);
    await tester.pumpAndSettle();

    await _pump(tester, 1100);
    // One frame in: still at the old numbers, not restarted from zero.
    expect(_arc(tester), 0.25);
    expect(_number(tester, 'today-kcal-remaining'), 1500);

    await _frames(tester, 8);
    expect(_arc(tester), inExclusiveRange(0.25, 0.55));
    expect(
      _number(tester, 'today-kcal-remaining'),
      inExclusiveRange(900, 1500),
    );
    expect(_number(tester, 'today-kcal-percent'), inExclusiveRange(25, 55));
    expect(_number(tester, 'today-stat-eaten'), inExclusiveRange(500, 1100));
    // Screen readers hear the target, not a running figure.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('today-kcal-remaining')))
          .semanticsLabel,
      '900',
    );

    await tester.pumpAndSettle();
    expect(_arc(tester), 0.55);
    expect(_text(tester, 'today-kcal-remaining'), '900');
    expect(_text(tester, 'today-kcal-percent'), '55% eaten');
    expect(_text(tester, 'today-stat-eaten'), '1,100');
  });

  testWidgets('reduzierte Bewegung zeigt jeden Endstand sofort', (
    tester,
  ) async {
    await _pump(tester, 500, reducedMotion: true);
    expect(_arc(tester), 0.25);
    expect(_text(tester, 'today-kcal-remaining'), '1,500');

    await _pump(tester, 1100, reducedMotion: true);
    await tester.pump();
    expect(_arc(tester), 0.55);
    expect(_text(tester, 'today-kcal-remaining'), '900');
    expect(_text(tester, 'today-kcal-percent'), '55% eaten');
  });
}
