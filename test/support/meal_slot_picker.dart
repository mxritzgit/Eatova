import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Chooses a meal slot in the inline slot control (`<prefix><slot>` key).
Future<void> chooseMealSlot(WidgetTester tester, String slotKey) async {
  final choice = find.byKey(ValueKey(slotKey));
  await tester.ensureVisible(choice);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
}
