import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/design/meters.dart';

import 'design_harness.dart';

void main() {
  group('Sparkline', () {
    testWidgets('haelt leere, einelementige und konstante Reihen aus',
        (tester) async {
      const series = <List<double>>[
        <double>[],
        <double>[80],
        <double>[80, 80, 80],
        <double>[78.6, 79.2, 78.9, 81.4],
      ];

      for (final values in series) {
        await tester.pumpWidget(designHarness(Sparkline(values: values)));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Reihe $values hat geworfen',
        );
      }
    });

    testWidgets('nimmt die uebergebene Hoehe', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const Sparkline(values: <double>[1, 2, 3], height: 100),
        ),
      );

      expect(tester.getSize(find.byType(Sparkline)).height, 100);
    });
  });
  // No text-scale or legibility sweep: the sparkline paints a line and draws
  // no Text, so both helpers would pass on any change.
}
