// Weekly volume card: the running week is shown first and every bar selects
// its week. Owner report 2026-10-03: after a workout logged with /log this
// week the card read "0.0 tonnes last week", and "Now" did nothing on tap.
// Second report the same day: 3 × 12 × 25 kg plus 3 × 3 × 120 kg is 1,980 kg,
// but the card said "2.0 tonnes"; the volume is now shown exactly in kg.

import 'package:eatova/src/models/training_insights.dart';
import 'package:eatova/src/screens/training/training_overview_widgets.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Six bars ending with the running week of Mon 2026-09-28, oldest first:
/// Aug 24, Aug 31, Sep 7, Sep 14, Sep 21, Now.
TrainingVolumeTrend _trend(List<double> kg, {DateTime? current}) {
  final now = current ?? DateTime(2026, 9, 28);
  return TrainingVolumeTrend([
    for (var i = 0; i < kg.length; i++)
      TrainingVolumeWeek(
        start: DateTime(now.year, now.month, now.day - 7 * (kg.length - 1 - i)),
        volumeKg: kg[i],
        isCurrent: i == kg.length - 1,
      ),
  ]);
}

const _steady = [6815.0, 7420.0, 7105.0, 7890.0, 8600.0, 4300.0];

Future<BuildContext> _pump(
  WidgetTester tester,
  TrainingVolumeTrend trend, {
  Locale locale = const Locale('en'),
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) => pumpLocalizedContext(
  tester,
  TrainingVolumeCard(trend: trend),
  locale: locale,
  surfaceSize: size,
  textScale: textScale,
  padding: const EdgeInsets.all(16),
  settle: true,
);

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

String _value(WidgetTester tester) => _text(tester, 'training-volume-value');

String _caption(WidgetTester tester) =>
    _text(tester, 'training-volume-caption');

String? _change(WidgetTester tester) {
  final change = find.byKey(const ValueKey('training-volume-change'));
  return change.evaluate().isEmpty ? null : tester.widget<Text>(change).data;
}

/// The figure above the selected bar.
Finder _barLabel() => find.byKey(const ValueKey('training-volume-bar-label'));

Color? _barColor(WidgetTester tester, int i) =>
    (tester
                .widget<Container>(
                  find.byKey(ValueKey('training-volume-bar-$i')),
                )
                .decoration
            as BoxDecoration?)
        ?.color;

Future<void> _select(WidgetTester tester, int i) async {
  await tester.tap(find.byKey(ValueKey('training-volume-week-$i')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the running week is the default, not the last full week', (
    tester,
  ) async {
    // The reported case: only this week's logged workout carries weight.
    await _pump(tester, _trend([0, 0, 0, 1200, 0, 1980]));
    expect(_value(tester), '1,980');
    expect(_caption(tester), 'kg this week');
    expect(find.text('kg last week'), findsNothing);
    // Last week is empty: there is nothing to compare against.
    expect(_change(tester), isNull);
  });

  testWidgets('the volume is exact to the kilogram, never rounded to tonnes', (
    tester,
  ) async {
    // 3 × 12 × 25 kg + 3 × 3 × 120 kg, the owner's workout of 2026-10-03.
    await _pump(tester, _trend([0, 0, 0, 0, 0, 3 * 12 * 25 + 3 * 3 * 120]));
    expect(_value(tester), '1,980');
    expect(tester.widget<Text>(_barLabel()).data, '1,980');
    // Weights allow two decimals; the volume keeps them when it has any.
    await _pump(tester, _trend([0, 0, 0, 0, 0, 3 * 3 * 22.5]));
    expect(_value(tester), '202.5');
    await _pump(tester, _trend([0, 0, 0, 0, 0, 3 * 3 * 112.25]));
    expect(_value(tester), '1,010.25');
    // Floating-point noise of the sum is no decimal.
    await _pump(tester, _trend([0, 0, 0, 0, 0, 0.1 * 3 + 1979.7]));
    expect(_value(tester), '1,980');
    await _pump(
      tester,
      _trend([0, 0, 0, 0, 0, 1980]),
      locale: const Locale('de'),
    );
    expect(_value(tester), '1.980');
    expect(_caption(tester), 'kg diese Woche');
  });

  testWidgets('a large figure above its bar shrinks into a narrow column', (
    tester,
  ) async {
    await _pump(
      tester,
      _trend([0, 0, 0, 0, 0, 123456.75]),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(_barLabel()).data, '123,456.75');
    final label = tester.getRect(_barLabel());
    final bar = tester.getRect(
      find.byKey(const ValueKey('training-volume-bar-5')),
    );
    expect(label.width, lessThanOrEqualTo(bar.width + 0.01));
  });

  testWidgets('a tap on a bar shows that week; Now returns to this week', (
    tester,
  ) async {
    final context = await _pump(tester, _trend(_steady));
    final t = context.t;
    expect(_value(tester), '4,300');
    expect(_caption(tester), 'kg this week');
    expect(_change(tester), '50% of last week so far');
    expect(_barColor(tester, 5), t.accentFill);
    expect(_barColor(tester, 4), t.chartViolet);

    await _select(tester, 4);
    expect(_value(tester), '8,600');
    expect(tester.widget<Text>(_barLabel()).data, '8,600');
    expect(_caption(tester), 'kg last week');
    expect(_change(tester), '↑ 9% vs. the week before');
    expect(_barColor(tester, 4), t.accentFill);
    expect(_barColor(tester, 5), t.chartViolet);

    await _select(tester, 2);
    expect(_value(tester), '7,105');
    expect(_caption(tester), 'kg in the week of Sep 7');
    expect(_change(tester), '↓ 4% vs. the week before');

    // The oldest bar has no charted week before it.
    await _select(tester, 0);
    expect(_value(tester), '6,815');
    expect(_caption(tester), 'kg in the week of Aug 24');
    expect(_change(tester), isNull);

    await _select(tester, 5);
    expect(_value(tester), '4,300');
    expect(_caption(tester), 'kg this week');
  });

  testWidgets('the gap between two bars still selects a week', (tester) async {
    await _pump(tester, _trend(_steady));
    final left = tester.getRect(
      find.byKey(const ValueKey('training-volume-bar-3')),
    );
    final right = tester.getRect(
      find.byKey(const ValueKey('training-volume-bar-4')),
    );
    // Just right of bar 3, inside the 10 px gap.
    await tester.tapAt(Offset(left.right + 2, right.bottom - 2));
    await tester.pumpAndSettle();
    expect(_value(tester), '7,890');
    // Every target is at least 44 px wide.
    for (var i = 0; i < 6; i++) {
      final size = tester.getSize(
        find.byKey(ValueKey('training-volume-week-$i')),
      );
      expect(size.width, greaterThanOrEqualTo(44), reason: 'week $i');
      expect(size.height, greaterThanOrEqualTo(44), reason: 'week $i');
    }
  });

  testWidgets('an empty running week shows no share of last week', (
    tester,
  ) async {
    await _pump(tester, _trend([6815, 7420, 7105, 7890, 8600, 0]));
    expect(_value(tester), '0');
    expect(_caption(tester), 'kg this week');
    expect(_change(tester), isNull);
  });

  testWidgets('a picked week stays picked while its bar is charted', (
    tester,
  ) async {
    await _pump(tester, _trend(_steady));
    await _select(tester, 4);
    expect(_value(tester), '8,600');
    // A new week starts: Sep 21 moves one bar to the left and is no longer
    // last week.
    await _pump(
      tester,
      _trend([7420, 7105, 7890, 8600, 4300, 0], current: DateTime(2026, 10, 5)),
    );
    expect(_value(tester), '8,600');
    expect(_caption(tester), 'kg in the week of Sep 21');
    // Aug 24 leaves the chart: the card falls back to the running week.
    await _pump(tester, _trend(_steady));
    await _select(tester, 0);
    await _pump(
      tester,
      _trend([
        7420,
        7105,
        7890,
        8600,
        4300,
        900,
      ], current: DateTime(2026, 10, 5)),
    );
    expect(_value(tester), '900');
    expect(_caption(tester), 'kg this week');
  });

  testWidgets('screen readers get one selectable button per week', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester, _trend(_steady));
      expect(
        tester.getSemantics(
          find.bySemanticsLabel('This week so far: 4,300 kg'),
        ),
        isSemantics(isButton: true, isSelected: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Week of Sep 21: 8,600 kg')),
        isSemantics(isButton: true, isSelected: false, hasTapAction: true),
      );
      tester.semantics.performAction(
        find.semantics.byLabel('Week of Sep 21: 8,600 kg'),
        SemanticsAction.tap,
      );
      await tester.pumpAndSettle();
      expect(_value(tester), '8,600');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Week of Sep 21: 8,600 kg')),
        isSemantics(isSelected: true),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('German captions and share line', (tester) async {
    await _pump(tester, _trend(_steady), locale: const Locale('de'));
    expect(_value(tester), '4.300');
    expect(_caption(tester), 'kg diese Woche');
    expect(_change(tester), 'bisher 50 % der Vorwoche');
    await _select(tester, 4);
    expect(_caption(tester), 'kg letzte Woche');
    await _select(tester, 1);
    expect(_value(tester), '7.420');
    expect(_caption(tester), 'kg in der Woche ab 31. Aug.');
    expect(_change(tester), '↑ 9 % gegenüber der Vorwoche');
  });
}
