// Visual evidence for the 2026-10-03 follow-up to the design polish: the
// recipe slot picker with the shared slot tile and the toggle in its states.
// The analysis and weight-adjust sheets are captured in
// meal_sheets_capture_test.dart.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/leftovers-*.png; without it the suite still checks that
// every surface renders without an exception or overflow.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';
import '../support/recipes_design_fixtures.dart';

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('recipe slot picker', (tester) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 28, 18, 30)), () async {
      await pumpDesignRecipes(tester);
      final card = find.byKey(
        ValueKey('recipe-shelf-lean-${designOwnRecipes.first.slug}'),
      );
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('recipe-add-button'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsOneWidget,
      );
      for (final slot in MealSlot.values) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('recipe-meal-picker-${slot.name}')),
            matching: find.byWidgetPredicate(
              (w) => w is SlotIconTile && w.slot == slot,
            ),
          ),
          findsOneWidget,
          reason: slot.name,
        );
      }
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'leftovers-recipe-picker');
    });
  });

  testWidgets('toggle states', (tester) async {
    pinDesignViewport(tester);
    await tester.pumpWidget(
      designCaptureBoundary(
        localizedApp(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 80, 20, 0),
            child: SettingsGroup(
              label: 'Toggles',
              children: <Widget>[
                for (final (title, value, enabled) in [
                  ('On', true, true),
                  ('Off', false, true),
                  ('Off, locked', false, false),
                  ('On, locked', true, false),
                ])
                  SettingsRow(
                    title: title,
                    chevron: false,
                    trailing: AppToggle(
                      value: value,
                      enabled: enabled,
                      onChanged: (_) {},
                    ),
                  ),
              ],
            ),
          ),
          locale: const Locale('en'),
          safeArea: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'leftovers-toggles');
  });
}
