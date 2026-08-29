// Tab navigation: the bottom nav switches between the four tabs and each
// screen's core pins hold. Cold start lands on Heute (index 0).
//
// Since D6 the tabs live in a lazy [IndexedStack]: a visited tab stays MOUNTED
// but invisible. Default finders (`skipOffstage: true`) do not see it, so
// existing `findsNothing` assertions remain valid; checking the mounted,
// invisible tree needs `skipOffstage: false`. The visible tab is the stack's
// index (`home-tab-stack`).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/models/fitness_recipe.dart';

import 'flow_test_helpers.dart';

/// Pinned "now": the recommendation carousel on the Rezepte tab rotates with
/// the calendar day (`rotatedRecommendations`), so which cards are on screen
/// depends on the day the suite runs. Without a fixed clock the title
/// assertions below held on 2 of 30 days. Plain midday, far from midnight and
/// any DST edge, so the date strip on Heute/Food stays stable too.
final DateTime _jetzt = DateTime(2026, 8, 20, 12, 30);

void main() {
  testWidgetsRobust(
      'Bottom navigation switches between Heute, Food, Rezepte and Coach', (
    WidgetTester tester,
  ) async {
    // Pin the device locale: `EatovaApp` resolves via `resolveEatovaLocale`,
    // so without this the outcome depends on the test host. The recipe catalog
    // is bilingual and the title assertions below expect German.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    await withClock(Clock.fixed(_jetzt), () async {
      await tester.pumpWidget(const EatovaApp());

      // Heute is the default tab (index 0) and on cold start the ONLY built one
      // (D6 lazy building).
      expect(find.byKey(const ValueKey('tab-fixed-0')), findsOneWidget);
      expect(_sichtbarerTab(tester), 0);
      expect(find.byKey(const ValueKey('tab-fixed-1'), skipOffstage: false),
          findsNothing);
      expect(find.byKey(const ValueKey('tab-fixed-2'), skipOffstage: false),
          findsNothing);
      expect(find.byKey(const ValueKey('tab-fixed-3'), skipOffstage: false),
          findsNothing);
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-date-strip')), findsOneWidget);
      // The Food tab is not built yet.
      expect(
        find.byKey(const ValueKey('screen-kcal-tracker'), skipOffstage: false),
        findsNothing,
      );

      // Food block, reached via a tap rather than directly after boot.
      await tester.tap(find.byKey(const ValueKey('nav-Food')));
      await tester.pumpAndSettle();
      expect(_sichtbarerTab(tester), 1);
      expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
      expect(find.byKey(const ValueKey('kcal-page-fill')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-date-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-date-chip-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-date-chip-3')), findsOneWidget);
      // The calorie card was removed from the Food tab; the pin now asserts its
      // ABSENCE and that the history took its place. The daily total lives in
      // the Heute tab (`today-kcal-hero`, pinned above).
      expect(
          find.byKey(const ValueKey('analyse-daily-kcal-card')), findsNothing);
      expect(
          find.byKey(const ValueKey('analyse-daily-kcal-total')), findsNothing);
      expect(
          find.byKey(const ValueKey('kcal-meals-today-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-history')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-search')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-action-barcode')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-action-ai')), findsOneWidget);
      // "Schnell" was removed (AI scan and barcode have their own flows).
      expect(find.byKey(const ValueKey('food-action-quick')), findsNothing);
      expect(find.byKey(const ValueKey('analyse-camera-button')), findsNothing);
      expect(
          find.byKey(const ValueKey('kcal-product-search-card')), findsNothing);
      expect(find.text('Demo-Fotoanalyse'), findsNothing);
      expect(find.text('Demo-Barcode laden'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
      await tester.pumpAndSettle();
      expect(_sichtbarerTab(tester), 2);
      expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('recipes-search-input')), findsOneWidget);

      // The carousel shows the pinned day's window of the catalog. Expected
      // titles come from the same rotation the screen uses, so a reordered
      // catalog moves the expectation along instead of turning the flow red —
      // but the assertion still names the two concrete cards of THIS day, not
      // "some recipe". Scoped to `recipe-recommended`, otherwise a same-named
      // tile in the list below could stand in for a missing card.
      // The app passes no `diet`, so the pool is the whole German catalog.
      final karussell = find.byKey(const ValueKey('recipe-recommended'));
      expect(karussell, findsOneWidget);
      final empfohlen = rotatedRecommendations(recipeCatalogDe, _jetzt);
      // Without this the loop below can have ZERO iterations: an empty
      // rotation would satisfy every assertion and the flow would stay green
      // while the carousel showed nothing.
      expect(
        empfohlen,
        hasLength(recipeRecommendationCount),
        reason: 'ohne Empfehlungen prueft die Schleife unten nichts',
      );
      // Two of the four cards fit the 393 px viewport (280 px each).
      for (final rezept in empfohlen.take(2)) {
        expect(
          find.descendant(of: karussell, matching: find.text(rezept.title)),
          findsOneWidget,
          reason: 'die Empfehlungskarte „${rezept.title}" fehlt',
        );
      }

      // The main list below is NOT rotated: it always holds the whole catalog.
      final putenTile = find.byKey(
        const ValueKey('recipe-tile-putenballchen_mit_reis_and_gemuse'),
      );
      await tester.dragUntilVisible(
        putenTile,
        find.byKey(const ValueKey('screen-recipes')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(putenTile, findsOneWidget);
      expect(find.text('Putenbällchen mit Reis & Gemüse'), findsWidgets);

      // Coach tab: the CoachOrb animates endlessly, so pumpAndSettle would
      // never settle — pump a bounded number of frames instead.
      await tester.tap(find.byKey(const ValueKey('nav-Coach')));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_sichtbarerTab(tester), 3);
      expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-streak')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-Food')));
      // The CoachOrb ticks while its tab is visible; after the switch
      // TickerMode mutes it and the tree settles again.
      await tester.pumpAndSettle();
      expect(_sichtbarerTab(tester), 1);
      expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-Heute')));
      await tester.pumpAndSettle();
      expect(_sichtbarerTab(tester), 0);
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);

      // D6: visited tabs are still mounted but invisible — that is what keeps
      // the coach draft, recipe search text and scroll positions alive.
      expect(find.byKey(const ValueKey('tab-fixed-1'), skipOffstage: false),
          findsOneWidget);
      expect(find.byKey(const ValueKey('tab-fixed-2'), skipOffstage: false),
          findsOneWidget);
      expect(find.byKey(const ValueKey('tab-fixed-3'), skipOffstage: false),
          findsOneWidget);
      expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsNothing);
      expect(find.byKey(const ValueKey('screen-recipes')), findsNothing);
      expect(find.byKey(const ValueKey('screen-coach')), findsNothing);
    });
  });
}

/// Index of the visible tab, read from the home shell's [IndexedStack].
int? _sichtbarerTab(WidgetTester tester) => tester
    .widget<IndexedStack>(find.byKey(const ValueKey('home-tab-stack')))
    .index;
