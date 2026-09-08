import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import '../support/harness.dart';

const _stats = ProfileStatRow(
  left: ProfileStatTile(
    key: ValueKey('streak-tile'),
    label: 'AKTUELLE SERIE',
    value: '365',
    unit: 'Tage',
  ),
  right: ProfileStatTile(
    key: ValueKey('meals-tile'),
    label: 'MAHLZEITEN',
    value: '12345',
    unit: 'insgesamt',
  ),
);

void main() {
  testWidgets(
    'profile statistics keep enlarged text readable on small phones',
    (tester) async {
      await pumpLocalized(
        tester,
        _stats,
        surfaceSize: const Size(320, 800),
        textScale: 2,
        padding: const EdgeInsets.all(20),
        scrollable: true,
      );

      expect(tester.takeException(), isNull);
      final first = tester.getRect(find.byKey(const ValueKey('streak-tile')));
      final second = tester.getRect(find.byKey(const ValueKey('meals-tile')));
      expect(second.top, greaterThanOrEqualTo(first.bottom + 12));
      expect(second.left, first.left);
      for (final text in ['365', 'Tage', '12345', 'insgesamt']) {
        final box = tester.renderObject<RenderBox>(find.text(text));
        // An ancestor FittedBox used to undo the requested 2x font scale.
        expect(
          box.getTransformTo(null).getMaxScaleOnAxis(),
          closeTo(1, 0.001),
          reason: '$text must render without a shrinking transform',
        );
      }
      expect(
        tester.getTopLeft(find.text('insgesamt')).dy,
        greaterThan(tester.getTopLeft(find.text('12345')).dy),
      );
    },
  );

  testWidgets('profile statistics stay side by side at standard phone width', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      _stats,
      surfaceSize: const Size(390, 800),
      padding: const EdgeInsets.all(20),
      scrollable: true,
    );

    expect(tester.takeException(), isNull);
    final first = tester.getRect(find.byKey(const ValueKey('streak-tile')));
    final second = tester.getRect(find.byKey(const ValueKey('meals-tile')));
    expect(first.top, second.top);
    expect(first.height, second.height);
    expect(second.left, greaterThan(first.right));
  });
}
