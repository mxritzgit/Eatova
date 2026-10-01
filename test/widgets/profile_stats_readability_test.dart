import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import '../support/harness.dart';

/// The two stat rows the profile draws: the streak pair inside the identity
/// hero (unframed, large) and the lifetime counts below it (framed tiles).
/// Both carry an icon and count up to their number.
final _varianten = <({String name, ProfileStatRow row, double gap})>[
  (
    name: 'hero',
    gap: 12,
    row: const ProfileStatRow(
      left: ProfileStatTile(
        key: ValueKey('first-tile'),
        label: 'AKTUELLE SERIE',
        value: '365',
        count: 365,
        unit: 'Tage',
        icon: Icons.local_fire_department_rounded,
        framed: false,
        large: true,
      ),
      right: ProfileStatTile(
        key: ValueKey('second-tile'),
        label: 'REKORD',
        value: '12345',
        count: 12345,
        unit: 'insgesamt',
        icon: Icons.emoji_events_rounded,
        framed: false,
        large: true,
      ),
    ),
  ),
  (
    name: 'lifetime',
    gap: 10,
    row: const ProfileStatRow(
      gap: 10,
      left: ProfileStatTile(
        key: ValueKey('first-tile'),
        label: 'MAHLZEITEN',
        value: '365',
        count: 365,
        unit: 'Tage',
        icon: Icons.restaurant_rounded,
      ),
      right: ProfileStatTile(
        key: ValueKey('second-tile'),
        label: 'WIEGUNGEN',
        value: '12345',
        count: 12345,
        unit: 'insgesamt',
        icon: Icons.monitor_weight_outlined,
      ),
    ),
  ),
];

void main() {
  for (final v in _varianten) {
    testWidgets(
      'profile statistics keep enlarged text readable on small phones '
      '(${v.name})',
      (tester) async {
        await pumpLocalized(
          tester,
          v.row,
          surfaceSize: const Size(320, 800),
          textScale: 2,
          padding: const EdgeInsets.all(20),
          scrollable: true,
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        final first = tester.getRect(find.byKey(const ValueKey('first-tile')));
        final second = tester.getRect(
          find.byKey(const ValueKey('second-tile')),
        );
        expect(second.top, greaterThanOrEqualTo(first.bottom + v.gap));
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

    testWidgets(
      'profile statistics stay side by side at standard phone width '
      '(${v.name})',
      (tester) async {
        await pumpLocalized(
          tester,
          v.row,
          surfaceSize: const Size(390, 800),
          padding: const EdgeInsets.all(20),
          scrollable: true,
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('365'), findsOneWidget);
        expect(find.text('12345'), findsOneWidget);
        final first = tester.getRect(find.byKey(const ValueKey('first-tile')));
        final second = tester.getRect(
          find.byKey(const ValueKey('second-tile')),
        );
        expect(first.top, second.top);
        expect(first.height, second.height);
        expect(second.left, greaterThan(first.right));
      },
    );
  }
}
