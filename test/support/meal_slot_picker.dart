import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the real meal context menu and chooses a destination.
Future<void> chooseMealSlot(WidgetTester tester, String slotKey) async {
  final prefix = slotKey.substring(0, slotKey.lastIndexOf('-') + 1);
  final trigger = find.byKey(ValueKey('${prefix}open'));
  await tester.ensureVisible(trigger);
  await tester.pumpAndSettle();
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  final choice = find.byKey(ValueKey(slotKey));
  await tester.ensureVisible(choice);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
}
