import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Follow the library's visible tabs, including after its lazy header recycles.
Future<void> selectRecipeSection(WidgetTester tester, String section) async {
  final tab = find.byKey(ValueKey('recipes-tab-$section'));
  if (tab.evaluate().isNotEmpty &&
      tester.widget<Semantics>(tab).properties.selected == true) {
    return;
  }
  final list = find
      .descendant(
        of: find.byKey(const ValueKey('screen-recipes')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(tab, -250, scrollable: list);
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}
