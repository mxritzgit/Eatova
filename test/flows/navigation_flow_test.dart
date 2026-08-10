// Tab-Navigation (aus test/widget_test.dart aufgeteilt): Bottom-Nav wechselt
// zwischen den vier Tabs Heute, Food, Rezepte und Coach; prueft die Kern-Pins
// der jeweiligen Screens.
//
// Design-Refactor 2026-08-09: aus drei Tabs sind vier geworden, und der
// Landepunkt beim Kaltstart ist jetzt „Heute" (Index 0) statt Food. Der
// bestehende Food-Block ist deshalb unveraendert geblieben — er steht nur
// hinter einem zusaetzlichen Tap auf `nav-Food`, und alle Indizes sind um eins
// nach hinten gerueckt.
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
  testWidgetsRobust(
      'Bottom navigation switches between Heute, Food, Rezepte and Coach', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EatovaApp());

    // Heute ist der Default-Tab (Index 0) — und beim Kaltstart der EINZIGE
    // gebaute Tab (D6-Lazy-Building).
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
    // Der Food-Tab ist noch gar nicht gebaut.
    expect(find.byKey(const ValueKey('screen-kcal-tracker'), skipOffstage: false),
        findsNothing);

    // Ab hier der unveraenderte Food-Block — nur eben nach einem Tap statt
    // direkt nach dem Boot.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    expect(_sichtbarerTab(tester), 1);
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
    expect(find.byKey(const ValueKey('kcal-page-fill')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-chip-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-chip-3')), findsOneWidget);
    // Die Kalorien-Karte ist am 2026-08-10 aus dem Food-Tab entfernt worden
    // („das haben wir ja im Heute-Tab schon"). Statt ihrer Existenz prueft der
    // Pin jetzt ihre ABWESENHEIT — und dass der Verlauf, der ihren Platz
    // eingenommen hat, da ist. Das Tagestotal steht im Heute-Tab
    // (`today-kcal-hero`, weiter oben in diesem Test schon gepinnt).
    expect(find.byKey(const ValueKey('analyse-daily-kcal-card')), findsNothing);
    expect(find.byKey(const ValueKey('analyse-daily-kcal-total')), findsNothing);
    expect(find.byKey(const ValueKey('kcal-meals-today-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-history')), findsOneWidget);
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
    expect(_sichtbarerTab(tester), 2);
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
    expect(_sichtbarerTab(tester), 3);
    expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-streak')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    // Der CoachOrb tickt weiter, solange sein Tab sichtbar ist — nach dem
    // Wechsel schaltet ihn der TickerMode stumm, danach settlet es wieder.
    await tester.pumpAndSettle();
    expect(_sichtbarerTab(tester), 1);
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-Heute')));
    await tester.pumpAndSettle();
    expect(_sichtbarerTab(tester), 0);
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);

    // D6: die besuchten Tabs sind noch da (nur unsichtbar) — genau das haelt
    // Coach-Entwurf, Rezept-Suchtext und Scrollpositionen am Leben. Fuer die
    // normalen Finder bleiben sie unsichtbar.
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
}

/// Index des sichtbaren Tabs, gelesen am [IndexedStack] der Home-Schale.
int? _sichtbarerTab(WidgetTester tester) => tester
    .widget<IndexedStack>(find.byKey(const ValueKey('home-tab-stack')))
    .index;
