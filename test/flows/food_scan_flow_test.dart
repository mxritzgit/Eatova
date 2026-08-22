// AI scan flows: itemized photo analysis, re-portioning including macro
// scaling, and the favorite heart on the result card.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Food tab supports deterministic itemized photo results and daily kcal adding', (
    WidgetTester tester,
  ) async {
    // Pin the device language — the assertions below check German ARB strings.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(
        mealAnalyzer: FakeMealAnalyzer(),
        mealCameraLauncher: FakeMealCameraLauncher(),
      ),
    );

    // Starting point: today is empty. The daily total lives in the today tab.
    await expectTagestotalAufHeute(tester, '0');

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // The AI scan opens the (faked) in-app camera and the analysis sheet opens
    // directly — no generic add sheet in between.
    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analyse-result-card')), findsOneWidget);
    expect(find.text('Kartoffeln'), findsOneWidget);
    expect(find.text('Steak'), findsOneWidget);
    expect(find.text('Brokkoli'), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-item-breakdown')), findsOneWidget);
    expect(find.text('855 kcal'), findsWidgets);

    await tester.ensureVisible(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.pumpAndSettle();
    expect(find.text('Zu heute hinzugefügt'), findsOneWidget);
    // Behind the open sheet the food tab's header tile carries the new daily
    // value. It renders the number only, with the unit as a separate label.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('screen-kcal-tracker')),
        matching: find.text('855'),
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const ValueKey('analyse-adjust-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-adjust-button')));
    await tester.pumpAndSettle();
    expect(find.text('Bestandteile anpassen'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('analyse-item-weight-input-0')),
      '150',
    );
    await tester.pumpAndSettle();
    expect(find.text('550 g ≈ 815 kcal'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('analyse-save-weight-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('analyse-save-weight-button')));
    await tester.pumpAndSettle();
    expect(find.text('815 kcal'), findsWidgets);
    // Exact match, NOT textContaining: the confirmation snackbar carries the
    // same substring and renders immediately.
    expect(find.text('550 g über Einzelposten angepasst'), findsOneWidget);
    expect(find.text('Zu heute hinzugefügt'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('screen-kcal-tracker')),
        matching: find.text('815'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('analyse-sheet-close')));
    await tester.pumpAndSettle();
    await expectTagestotalAufHeute(tester, '815');
  });

  // PROD-3: re-portioning scales kcal AND macros (macros used to freeze and
  // the kcal delta hit the WRONG meal). 300 g / 30 g protein -> 400 g must
  // scale protein to ~40 g.
  testWidgetsRobust('Re-portioning a logged meal scales macros, not just kcal', (
    WidgetTester tester,
  ) async {
    // Pin the device language — the assertions below check German ARB strings.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(
        mealAnalyzer: MacroMealAnalyzer(),
        mealCameraLauncher: FakeMealCameraLauncher(),
      ),
    );

    // Before logging: protein 0 / 130g (cold start lands on the today tab).
    expect(find.text('0 / 130g'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analyse-result-card')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.pumpAndSettle();
    expect(find.text('Zu heute hinzugefügt'), findsOneWidget);

    // Re-portioning via the item sheet: one synthetic item for this meal.
    await tester.ensureVisible(find.byKey(const ValueKey('analyse-adjust-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-adjust-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('analyse-item-weight-input-0')),
      '400',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('analyse-save-weight-button')),
    );
    await tester.tap(find.byKey(const ValueKey('analyse-save-weight-button')));
    await tester.pumpAndSettle();

    // Close the sheets and check the today tab: protein scales from 30 to
    // ~40 g (400/300 * 30). The bug froze it at 30 while only kcal rose.
    await tester.tap(find.byKey(const ValueKey('analyse-sheet-close')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-Heute')));
    await tester.pumpAndSettle();

    expect(find.text('40 / 130g'), findsOneWidget);
    expect(find.text('30 / 130g'), findsNothing);
  });

  // PROD-4: the favorite heart renders on the analysis result and tapping it
  // pins the meal into its own favorites section in the add sheet.
  testWidgetsRobust('Meal result shows a favorite heart that pins the meal', (
    WidgetTester tester,
  ) async {
    // Pin the device language — the assertions below check German ARB strings.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(
        mealAnalyzer: MacroMealAnalyzer(),
        mealCameraLauncher: FakeMealCameraLauncher(),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();

    // The heart renders (onToggleFavorite is wired).
    expect(find.byKey(const ValueKey('analyse-favorite-button')), findsOneWidget);
    expect(find.byIcon(Icons.favorite_outline_rounded), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('analyse-favorite-button')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_rounded), findsWidgets);

    // Log, then reopen: the pinned favorite sits in the favorites section, not
    // in recent meals.
    await tester.ensureVisible(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.pumpAndSettle();
    // The add sheet is reached via search to check the favorites.
    await tester.tap(find.byKey(const ValueKey('analyse-sheet-close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();
    expect(find.text('FAVORITEN'), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-pinned-0')), findsOneWidget);
  });
}
