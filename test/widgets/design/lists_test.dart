import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/design/lists.dart';

import 'design_harness.dart';

void main() {
  // Numbers and dots are decoration: a screen reader hears the position in
  // words, once, with the step, and never a stray "2" or "•".
  testWidgets('ein Schritt liest sich als "Schritt 2 von 3", Nummern und '
      'Punkte bleiben stumm', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      designHarness(
        const Column(
          children: <Widget>[
            NumberedSteps(
              steps: <String>['1. Aufkochen.', '2) Schneiden.', 'Servieren.'],
            ),
            BulletList(items: <String>['- Hafer', '• Milch']),
          ],
        ),
      ),
    );

    expect(
      find.bySemanticsLabel('Schritt 2 von 3. Schneiden.'),
      findsOneWidget,
    );
    // The numbers the text carried gave way to the drawn ones, and so did
    // the list markers.
    expect(find.text('Schneiden.'), findsOneWidget);
    expect(find.text('Hafer'), findsOneWidget);
    expect(find.bySemanticsLabel('2'), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^[•-]')), findsNothing);
    handle.dispose();
  });
}
