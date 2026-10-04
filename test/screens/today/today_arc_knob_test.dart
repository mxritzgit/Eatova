// The calorie arc's knob per display mode (light pass, 2026-10-04). Dark keeps
// the design's near-white dot; light used to paint `ink` there, a near-black
// dot on the white hero, and now paints a white knob with an accent ring.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/today/today_progress.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import '../../support/harness.dart';

Finder get _arcPaint => find.descendant(
  of: find.byType(TodayCalorieArc),
  matching: find.byType(CustomPaint),
);

TodayArcPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_arcPaint).painter! as TodayArcPainter;

Future<void> _pump(
  WidgetTester tester,
  Brightness brightness, {
  double progress = 0.58,
}) => pumpLocalized(
  tester,
  Center(child: TodayCalorieArc(progress: progress)),
  brightness: brightness,
);

void main() {
  testWidgets('hell: weisser Knopf mit Akzentring statt schwarzem Punkt', (
    tester,
  ) async {
    await _pump(tester, Brightness.light);
    const t = AppTokens.light;
    final painter = _painter(tester);
    expect(painter.knob, isNot(t.ink), reason: 'der alte schwarze Punkt');
    expect(painter.knob, t.knob);
    expect(painter.knobRing, t.knobRing);
    // Halo, knob, then the ring stroked around it.
    expect(
      _arcPaint,
      paints
        ..circle(radius: 15)
        ..circle(radius: 7, color: t.knob, style: PaintingStyle.fill)
        ..circle(
          radius: 7,
          color: t.knobRing,
          style: PaintingStyle.stroke,
          strokeWidth: 3,
        ),
    );
  });

  testWidgets('hell: der Ring traegt den Knopf auch bei 0 % auf der Spur', (
    tester,
  ) async {
    await _pump(tester, Brightness.light, progress: 0);
    expect(_arcPaint, paintsExactlyCountTimes(#drawCircle, 3));
  });

  testWidgets('dunkel: unveraendert der helle Punkt ohne Ring', (
    tester,
  ) async {
    await _pump(tester, Brightness.dark);
    const t = AppTokens.dark;
    final painter = _painter(tester);
    expect(painter.knob, t.ink);
    expect(
      _arcPaint,
      paints
        ..circle(radius: 15)
        ..circle(radius: 7, color: t.ink, style: PaintingStyle.fill),
    );
    // Halo and knob only: no ring is stroked.
    expect(_arcPaint, paintsExactlyCountTimes(#drawCircle, 2));
  });
}
