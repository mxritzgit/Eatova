// Visual evidence for the Recipes surfaces recipes_redesign does not reach
// (light mode pass, 2026-10-04), in the same design scenario:
//
//   recipes-all-00        the "All" section: photo rows
//   recipes-filter-00     the filter sheet
//   recipes-own-empty-00  "My recipes" without any: the empty state
//   recipes-no-result-00  a search without a match, with its way out
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
      // One card says it, with the import/create pair inside — not a
      // second "Your recipes" card above it.
      expect(find.byKey(const ValueKey('recipes-own-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('recipes-your-recipes')), findsNothing);
      expect(find.byKey(const ValueKey('recipe-create-button')), findsOneWidget);
      await captureDesignShot(tester, 'recipes-own-empty-00');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a search without a match', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await pumpDesignRecipes(tester);
      await tester.tap(find.byKey(const ValueKey('recipes-tab-all')));
      await settleFrames(tester);
      await tester.enterText(
        find.byKey(const ValueKey('recipes-search-input')),
        'zzzz',
      );
      await settleFrames(tester);
      expect(find.byKey(const ValueKey('recipes-no-result')), findsOneWidget);
      await captureDesignShot(tester, 'recipes-no-result-00');
      // The way out clears the search and brings the list back.
      await tester.tap(find.byKey(const ValueKey('recipes-no-result-reset')));
      await settleFrames(tester);
      expect(find.byKey(const ValueKey('recipes-no-result')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
