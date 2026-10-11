// Visual evidence for the Recipes tab of the dark redesign (Task 4).
//
// Mounts the real home page at the design's reference geometry in the design
// scenario: Mon 2026-09-28 18:30, a 2,123 kcal goal, breakfast, lunch and
// snacks logged (1,221 kcal), dinner open, so the shared pick is the turkey
// steak (610 kcal, 58 g protein) that fits the 902 kcal left. Three own
// recipes without photos stand in for the design's placeholder cards on the
// "High protein, under 500 kcal" shelf.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/recipes-00.png and recipes-01.png (scroll 383, the
// design's `recipes-01`). Without it the suite still pins the scenario.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/design_capture.dart';
import '../support/recipes_design_fixtures.dart';
import '../support/text_layout.dart';

final _now = DateTime(2026, 9, 28, 18, 30);

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('recipes-00 / recipes-01: the design scenario', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final store = await pumpDesignRecipes(tester);
      expect(store.selectedTab, 2);

      // The hero is the shared pick of the design scenario.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('recipe-hero')),
          matching: find.text('Turkey Steak with Quinoa & Roasted Vegetables'),
        ),
        findsOneWidget,
      );
      expect(find.text('PICKED FOR TONIGHT'), findsOneWidget);
      expect(find.byKey(const ValueKey('recipe-hero-fits')), findsOneWidget);
      expect(find.text('Add to dinner'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('recipe-hero-ai-label')),
        findsOneWidget,
      );
      // The design's first shelf cards are the three own recipes.
      for (final recipe in designOwnRecipes) {
        expect(
          find.byKey(ValueKey('recipe-shelf-lean-${recipe.slug}')),
          findsOneWidget,
        );
      }

      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'recipes-00');

      final list = find.byKey(const ValueKey('screen-recipes'));
      final offset = await scrollDesignTabBy(
        tester,
        383,
        scrollable: find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first,
      );
      expect(offset, 383, reason: 'design shot recipes-01 sits at 383');
      expect(
        find.byKey(const ValueKey('recipes-your-recipes')),
        findsOneWidget,
      );
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'recipes-01');
      expect(tester.takeException(), isNull);
    });
  });

  // At 200 % text the 20 px shelf titles grew to 40 px and broke
  // "recommendation|s" even on a 390 px phone.
  testWidgets('recipes: titles stay whole at 320 px and 2x text', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await pumpDesignRecipes(tester, textScale: 2);
      tester.view.physicalSize =
          Size(320, kDesignViewport.height) * kDesignPixelRatio;
      await tester.pumpAndSettle();
      final page = find.byKey(const ValueKey('screen-recipes'));
      for (final (link, title) in const [
        ('recipe-lean-see-all', 'High protein, under 500 kcal'),
        ('recipes-more-see-all', 'More recommendations'),
      ]) {
        // The list builds lazily: scroll until the shelf exists.
        await tester.scrollUntilVisible(
          find.byKey(ValueKey(link)),
          300,
          scrollable: find
              .descendant(of: page, matching: find.byType(Scrollable))
              .first,
        );
        await tester.pumpAndSettle();
        expectWholeWordsIn(tester, page, title);
      }
      // The list rows: beside the 78 px photo the title broke
      // "Asparagu|s"; from 1.5x text the photo sits above it.
      const salmon = 'Salmon with Sweet Potato & Asparagus';
      await tester.scrollUntilVisible(
        find.text(salmon),
        300,
        scrollable: find
            .descendant(of: page, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      expectWholeWordsIn(tester, page, salmon);
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'recipes-320-x2');
      expect(tester.takeException(), isNull);
    });
  });
}
