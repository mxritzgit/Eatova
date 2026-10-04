// Visual evidence for the Recipes surfaces recipes_redesign does not reach
// (light mode pass, 2026-10-04), in the same design scenario:
//
//   recipes-all-00        the "All" section: photo rows
//   recipes-filter-00     the filter sheet
//   recipes-own-empty-00  "My recipes" without any: the empty state
//
// Shots are written only with DARK_REDESIGN_CAPTURE or
// DESIGN_CAPTURE_BRIGHTNESS; the normal pass checks that each surface shows.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/flow_test_helpers.dart' show settleFrames;
import '../support/design_capture.dart';
import '../support/recipes_design_fixtures.dart';

final _now = DateTime(2026, 9, 28, 18, 30);

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('the All section and the filter sheet', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await pumpDesignRecipes(tester);
      await tester.tap(find.byKey(const ValueKey('recipes-tab-all')));
      await settleFrames(tester);
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'recipes-all-00');

      await tester.tap(find.byKey(const ValueKey('recipes-filter-button')));
      await settleFrames(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      await captureDesignShot(tester, 'recipes-filter-00');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('My recipes without any', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await pumpDesignRecipes(tester, ownRecipes: false);
      await tester.tap(find.byKey(const ValueKey('recipes-tab-own')));
      await settleFrames(tester);
      expect(find.text('Your cookbook starts here'), findsOneWidget);
      await captureDesignShot(tester, 'recipes-own-empty-00');
      expect(tester.takeException(), isNull);
    });
  });
}
