import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/shared/eatova_wordmark.dart';

void main() {
  testWidgets('EatovaWordmark rendert eat + Fokusring + va ohne Overflow',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: EatovaWordmark(fontSize: 26))),
      ),
    );

    expect(find.text('eat'), findsOneWidget);
    expect(find.text('va'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(EatovaWordmark),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
