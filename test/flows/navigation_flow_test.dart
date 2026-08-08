// Tab-Navigation (aus test/widget_test.dart aufgeteilt): Bottom-Nav wechselt
// zwischen den drei Tabs Food, Rezepte und Coach; prueft die Kern-Pins der
// jeweiligen Screens.
//
// Seit D6 (2026-08-08) liegen die Tabs in einem lazy [IndexedStack]: ein einmal
// besuchter Tab bleibt GEMOUNTET (nur unsichtbar). Die Standard-Finder
// (`skipOffstage: true`) sehen ihn nicht — bestehende `findsNothing`-Aussagen
// bleiben also gueltig; wer den gemounteten, unsichtbaren Baum pruefen will,
// braucht `skipOffstage: false`. Welcher Tab sichtbar ist, sagt der Index des
// Stacks (`home-tab-stack`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Bottom navigation switches between Food, Rezepte and Coach', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EatovaApp());

    // Food ist der Default-Tab (Index 0) — und beim Kaltstart der EINZIGE
    // gebaute Tab (D6-Lazy-Building).
    expect(find.byKey(const ValueKey('tab-fixed-0')), findsOneWidget);
    expect(_sichtbarerTab(tester), 0);
    expect(find.byKey(const ValueKey('tab-fixed-1'), skipOffstage: false),
        findsNothing);
    expect(find.byKey(const ValueKey('tab-fixed-2'), skipOffstage: false),
        findsNothing);
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
    expect(find.byKey(const ValueKey('kcal-page-fill')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-chip-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-chip-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-daily-kcal-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-daily-kcal-total')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-action-barcode')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-action-ai')), findsOneWidget);
    // "Schnell" wurde entfernt (KI-Scan/Barcode haben eigene Flows).
    expect(find.byKey(const ValueKey('food-action-quick')), findsNothing);
    expect(find.byKey(const ValueKey('analyse-camera-button')), findsNothing);
    expect(find.byKey(const ValueKey('kcal-product-search-card')), findsNothing);
    expect(find.text('Demo-Fotoanalyse'), findsNothing);
    expect(find.text('Demo-Barcode laden'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
    await tester.pumpAndSettle();
    expect(_sichtbarerTab(tester), 1);
    expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipes-search-input')), findsOneWidget);
    expect(find.text('Hähnchen mit Reis & Brokkoli'), findsWidgets);
    expect(find.text('Lachs mit Süßkartoffel & Spargel'), findsWidgets);

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

    // Coach-Tab: der CoachOrb im Hero animiert endlos (Spin/Breathe) —
    // pumpAndSettle wuerde nie settlen, daher begrenzte Frames pumpen.
    await tester.tap(find.byKey(const ValueKey('nav-Coach')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(_sichtbarerTab(tester), 2);
    expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-streak')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    // Der CoachOrb tickt weiter, solange sein Tab sichtbar ist — nach dem
    // Wechsel schaltet ihn der TickerMode stumm, danach settlet es wieder.
    await tester.pumpAndSettle();
    expect(_sichtbarerTab(tester), 0);
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

    // D6: die besuchten Tabs sind noch da (nur unsichtbar) — genau das haelt
    // Coach-Entwurf, Rezept-Suchtext und Scrollpositionen am Leben. Fuer die
    // normalen Finder bleiben sie unsichtbar.
    expect(find.byKey(const ValueKey('tab-fixed-1'), skipOffstage: false),
        findsOneWidget);
    expect(find.byKey(const ValueKey('tab-fixed-2'), skipOffstage: false),
        findsOneWidget);
    expect(find.byKey(const ValueKey('screen-recipes')), findsNothing);
    expect(find.byKey(const ValueKey('screen-coach')), findsNothing);
  });
}

/// Index des sichtbaren Tabs, gelesen am [IndexedStack] der Home-Schale.
int? _sichtbarerTab(WidgetTester tester) => tester
    .widget<IndexedStack>(find.byKey(const ValueKey('home-tab-stack')))
    .index;
