import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiftfit/main.dart';
import 'package:shiftfit/src/auth/auth_repository.dart';
import 'package:shiftfit/src/models/logged_meal.dart';
import 'package:shiftfit/src/models/meal_analysis_request.dart';
import 'package:shiftfit/src/models/meal_analysis_result.dart';
import 'package:shiftfit/src/models/meal_component.dart';
import 'package:shiftfit/src/services/meal_analyzer.dart';
import 'package:shiftfit/src/services/meal_camera_launcher.dart';
import 'package:shiftfit/src/services/open_food_facts_product_service.dart';

// Wrapper um testWidgets fuer das CI-Setup:
//
// 1. Pinnt das Test-Viewport auf iPhone 14 portrait (393x852 logical @
//    DPR 3). Default ist 800x600, das verschiebt Grid-Reihen und macht
//    Scroll-Drags non-deterministic (z.B. greift `drag(0, -700)` ein
//    anderes Item als auf dem Device).
// 2. Schluckt RenderFlex-Overflow-Exceptions — die kommen vom Render-
//    Pass im Test-Headless-Renderer, auf dem echten Geraet sitzt die
//    App in Scroll-Containern und overflowt dort nicht.
//
// `testWidgets` setzt intern NACH setUp einen eigenen FlutterError.onError
// und resettet `tester.view` nicht — beides muss daher hier im Test-Body
// gemacht werden, damit es wirkt.
void testWidgetsRobust(
  String description,
  WidgetTesterCallback callback, {
  String? skip,
}) {
  testWidgets(description, skip: skip != null, (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}

void main() {
  testWidgetsRobust('Auth screen supports register and login flow', (
    WidgetTester tester,
  ) async {
    final authRepository = InMemoryAuthRepository();
    addTearDown(authRepository.dispose);

    await tester.pumpWidget(ShiftFitApp(authRepository: authRepository));
    await tester.pump();

    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-hero')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-google-oauth')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-apple-oauth')), findsNothing);
    expect(find.text('Mit Google anmelden'), findsOneWidget);
    expect(find.text('Mit Apple anmelden'), findsNothing);
    expect(find.text('Einloggen'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('auth-name-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('auth-name-field')),
      'Moritz',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')),
      'moritz@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')),
      'fitpilot123',
    );
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

    await authRepository.signOut();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')),
      'moritz@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')),
      'fitpilot123',
    );
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
  });

  testWidgetsRobust('Auth screen supports OAuth buttons', (WidgetTester tester) async {
    final authRepository = InMemoryAuthRepository();
    addTearDown(authRepository.dispose);

    await tester.pumpWidget(ShiftFitApp(authRepository: authRepository));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auth-google-oauth')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
  });

  testWidgetsRobust('Bottom navigation switches between Food, Rezepte and Coach', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ShiftFitApp());

    // Food ist der Default-Tab (Index 0).
    expect(find.byKey(const ValueKey('tab-fixed-0')), findsOneWidget);
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
    expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-streak')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
  });

  testWidgetsRobust('Recipe detail can add a meal into kcal and macro tracker', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ShiftFitApp());

    await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
    await tester.pumpAndSettle();

    final recipeTile = find.byKey(
      const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
    );
    await tester.ensureVisible(recipeTile);
    await tester.tap(recipeTile);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('recipe-detail-hahnchen_mit_reis_and_brokkoli')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('recipe-add-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-add-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-meal-picker-lunch')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('recipe-add-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-meal-picker-sheet')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recipe-meal-picker-lunch')));
    await tester.pumpAndSettle();
    expect(find.text('590 kcal zu Mittagessen hinzugefügt.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recipe-detail-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('590 kcal'),
      ),
      findsOneWidget,
    );

    expect(find.text('Hähnchen mit Reis & Brokkoli'), findsWidgets);
    expect(find.textContaining('590'), findsWidgets);
  });

  testWidgetsRobust('Food tab supports deterministic itemized photo results and daily kcal adding', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(
        mealAnalyzer: _FakeMealAnalyzer(),
        mealCameraLauncher: _FakeMealCameraLauncher(),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('analyse-daily-kcal-total')), findsOneWidget);
    expect(find.text('0 kcal'), findsOneWidget);

    // KI-Scan öffnet die (gefakte) In-App-Kamera -> liefert das Foto -> das
    // Analyse-Sheet öffnet direkt (kein generisches Add-Sheet mehr).
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
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('855 kcal'),
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
    // Exakter Match auf das persistente "angepasst"-Label der Ergebniskarte
    // (meal_widgets), bewusst NICHT textContaining: die Bestätigungs-Snackbar
    // ("… angepasst. Tageswert aktualisiert.") enthält denselben Teilstring und
    // rendert mit dem neuen no-stacking-Toast sofort -> textContaining wäre
    // mehrdeutig. Das exakte Label ist timing-unabhängig.
    expect(find.text('550 g über Einzelposten angepasst'), findsOneWidget);
    expect(find.text('Zu heute hinzugefügt'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('815 kcal'),
      ),
      findsOneWidget,
    );
  });

  // PROD-3: Re-Portionierung einer bereits geloggten Mahlzeit skaliert kcal UND
  // Makros (frueher froren Protein/KH/Fett ein und der kcal-Delta traf zudem die
  // FALSCHE — erste — Mahlzeit des Tages). 300 g / 30 g Protein -> 400 g muss
  // Protein auf ~40 g hochskalieren (Makro-Balken zeigt 40/130g).
  testWidgetsRobust('Re-portioning a logged meal scales macros, not just kcal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(
        mealAnalyzer: _MacroMealAnalyzer(),
        mealCameraLauncher: _FakeMealCameraLauncher(),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Vor dem Loggen: Protein 0/130g.
    expect(find.text('0/130g'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analyse-result-card')), findsOneWidget);

    // Hinzufuegen -> 30 g Protein im Tageswert.
    await tester.ensureVisible(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.pumpAndSettle();
    expect(find.text('Zu heute hinzugefügt'), findsOneWidget);

    // Re-Portionierung: 300 g -> 400 g (Einzelposten-Sheet, ein synthetischer
    // Posten fuer die nicht-itemisierte Mahlzeit).
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

    // Der Makro-Balken der Food-Seite liegt hinter den Sheets im Widget-Tree
    // und ist daher direkt findbar. Protein skaliert von 30 auf ~40 g
    // (400/300 * 30 = 40). Vorher fror der Bug das Protein bei 30 ein, waehrend
    // nur die kcal stiegen — UND traf zudem die falsche Mahlzeit.
    expect(find.text('40/130g'), findsOneWidget);
    expect(find.text('30/130g'), findsNothing);
  });

  // PROD-4: Das Favoriten-Herz rendert im Analyse-Ergebnis und das Antippen
  // heftet die Mahlzeit an (eigene „Favoriten"-Sektion im Add-Sheet).
  testWidgetsRobust('Meal result shows a favorite heart that pins the meal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(
        mealAnalyzer: _MacroMealAnalyzer(),
        mealCameraLauncher: _FakeMealCameraLauncher(),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();

    // Das Herz rendert (onToggleFavorite ist verdrahtet).
    expect(find.byKey(const ValueKey('analyse-favorite-button')), findsOneWidget);
    expect(find.byIcon(Icons.favorite_outline_rounded), findsOneWidget);

    // Anheften -> Herz wird gefuellt.
    await tester.tap(find.byKey(const ValueKey('analyse-favorite-button')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_rounded), findsWidgets);

    // Loggen, dann beide Sheets schliessen und erneut oeffnen: der angeheftete
    // Favorit steht in der eigenen „Favoriten"-Sektion (nicht „Letzte
    // Mahlzeiten").
    await tester.ensureVisible(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.pumpAndSettle();
    // Nur das Analyse-Sheet ist offen (KI-Scan öffnet kein Add-Sheet mehr),
    // danach über die Suche das Add-Sheet zum Prüfen der Favoriten öffnen.
    await tester.tap(find.byKey(const ValueKey('analyse-sheet-close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();
    expect(find.text('FAVORITEN'), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-pinned-0')), findsOneWidget);
  });

  testWidgetsRobust('Food tab searches OpenFoodFacts products and adds selected item', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(productService: _FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker Salami',
    );
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('Dr. Oetker'), findsWidgets);
    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Die Ofenfrische Salami'), findsWidgets);
    expect(find.text('252 kcal'), findsWidgets);

    final addButton =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('252 kcal'),
      ),
      findsOneWidget,
    );
  });

  testWidgetsRobust('Food add lets the user pick the meal slot, not the clock', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(productService: _FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    // Der Slot-Selector ist im Add-Sheet vorhanden, alle vier Slots wählbar.
    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-select-breakfast')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-select-lunch')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-select-dinner')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-select-snack')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker Salami',
    );
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    // 1) Slot "Snack" wählen -> Eintrag landet in Snacks.
    await tester.tap(find.byKey(const ValueKey('slot-select-snack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    final addSnack = find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addSnack);
    await tester.tap(addSnack);
    await tester.pumpAndSettle();
    expect(find.text('252 kcal zu Snacks hinzugefügt.'), findsOneWidget);

    // Erste Snackbar auslaufen lassen, damit die nächste nicht in der Queue
    // wartet (sonst verdeckt sie die zweite Bestätigung).
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 2) Im selben Sheet "Frühstück" wählen -> nächster Eintrag landet dort.
    // Zwei verschiedene Slots beweisen: der Selector steuert den Slot, nicht
    // die Uhrzeit-Heuristik (deren Default ist immer nur EIN Slot).
    await tester.tap(find.byKey(const ValueKey('slot-select-breakfast')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    final addBreakfast =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addBreakfast);
    await tester.tap(addBreakfast);
    await tester.pumpAndSettle();
    expect(find.text('252 kcal zu Frühstück hinzugefügt.'), findsOneWidget);
  });

  testWidgetsRobust('Food history row can be swiped to delete and updates live', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(productService: _FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Einen Eintrag über die Suche hinzufügen.
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker Salami',
    );
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    final addButton =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    // Sheet schließen, um an die Verlauf-Karte zu kommen.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // Eintrag ist im Verlauf, Tages-kcal zeigt ihn.
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('252 kcal'),
      ),
      findsOneWidget,
    );

    // Von rechts nach links swipen -> Lösch-Aktion erscheint -> antippen.
    await tester.drag(
      find.byKey(const ValueKey('food-history-entry-0')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('food-history-delete-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('food-history-delete-0')));
    await tester.pumpAndSettle();

    // Eintrag ist sofort weg und die Tagessumme aktualisiert direkt auf 0.
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('0 kcal'),
      ),
      findsOneWidget,
    );
  });

  testWidgetsRobust('Food calendar keeps past days separate from today', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(productService: _FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('food-date-chip-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-chip-2')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('0 kcal'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('food-date-chip-2')));
    await tester.pumpAndSettle();
    expect(find.text('Vor 2 Tagen'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker Salami',
    );
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    final pastAddButton =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(pastAddButton);
    await tester.tap(pastAddButton);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('252 kcal'),
      ),
      findsOneWidget,
    );

    // AddMealSheet schliessen, sonst absorbiert die Modal-Barrier den
    // naechsten Chip-Tap.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // Heute ist der LETZTE Chip (Index = visiblePastDays = 4); chip-0
    // waere "Vor 4 Tagen". Test-Intention: zurueck zu Heute switchen.
    await tester.tap(find.byKey(const ValueKey('food-date-chip-4')));
    await tester.pumpAndSettle();
    expect(find.text('Heute'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('0 kcal'),
      ),
      findsOneWidget,
    );
  });

  testWidgetsRobust('Kcal product search shows suggestions while typing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(productService: _FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);
    expect(find.textContaining('Dr. Oetker'), findsWidgets);
  });

  testWidgetsRobust('Kcal live product search waits through transient failures', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(productService: _FlakyProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('OpenFoodFacts-Suche gerade nicht erreichbar.'), findsNothing);

    await tester.pump(const Duration(milliseconds: 3600));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);
    expect(find.textContaining('Dr. Oetker'), findsWidgets);
    expect(find.text('OpenFoodFacts-Suche gerade nicht erreichbar.'), findsNothing);
  });

  testWidgetsRobust('Kcal live product search retries temporary empty results', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShiftFitApp(productService: _EmptyThenSuccessProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Wagner Salami',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      find.text('Keine passenden Produkte gefunden. Versuche Marke + Produktname.'),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 3600));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);
    expect(find.textContaining('Dr. Oetker'), findsWidgets);
    expect(
      find.text('Keine passenden Produkte gefunden. Versuche Marke + Produktname.'),
      findsNothing,
    );
  });

}

class _FakeMealAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const MealAnalysisResult(
      mealName: 'Teller mit Steak, Kartoffeln und Brokkoli',
      caloriesKcal: 855,
      estimatedGrams: 600,
      kcalPer100G: 142.5,
      protein: '64 g',
      carbs: '42 g',
      fat: '38 g',
      confidence: 'Mittel',
      portionNotes:
          'Die KI hat sichtbare Bestandteile getrennt geschätzt. Bitte Gramm pro Bestandteil bestätigen.',
      sourceLabel: 'Foto-KI',
      items: [
        MealComponent(
          name: 'Kartoffeln',
          grams: 200,
          caloriesKcal: 160,
          kcalPer100G: 80,
        ),
        MealComponent(
          name: 'Steak',
          grams: 300,
          caloriesKcal: 660,
          kcalPer100G: 220,
        ),
        MealComponent(
          name: 'Brokkoli',
          grams: 100,
          caloriesKcal: 35,
          kcalPer100G: 35,
        ),
      ],
    );
  }
}

// 300 g / 30 g Protein, OHNE Einzelposten -> die Re-Portionierung erzeugt im
// Anpassen-Sheet einen einzelnen synthetischen Posten. 100 kcal/100 g, damit
// 300 g = 300 kcal und 400 g = 400 kcal sauber aufgehen.
class _MacroMealAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const MealAnalysisResult(
      mealName: 'Protein-Bowl',
      caloriesKcal: 300,
      estimatedGrams: 300,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '50 g',
      fat: '20 g',
      confidence: 'Mittel',
      portionNotes: 'Test-Mahlzeit ohne Einzelposten.',
      sourceLabel: 'Foto-KI',
    );
  }
}

// Ersetzt die echte In-App-Kamera (camera-Package, nicht test-bar): liefert
// sofort ein kanned Foto im uebergebenen Slot zurueck, damit der KI-Scan-Flow
// (Kamera -> Analyse-Sheet) ohne Hardware getestet werden kann.
class _FakeMealCameraLauncher implements MealCameraLauncher {
  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) async {
    return MealCameraCapture(
      request: const MealAnalysisRequest(imageId: 'test-photo'),
      previewBytes: null,
      slot: initialSlot,
    );
  }
}

class _FakeProductLookupService implements ProductLookupService {
  static final MealAnalysisResult salamiPizza = MealAnalysisResult.fromOpenFoodFacts(
    const <String, dynamic>{
      'code': '4001724012345',
      'product_name': 'Die Ofenfrische Salami',
      'brands': 'Dr. Oetker',
      'quantity': '390 g',
      'serving_quantity': 100,
      'nutriments': <String, dynamic>{
        'energy-kcal_100g': 252,
        'proteins_100g': 10,
        'carbohydrates_100g': 31,
        'fat_100g': 9,
      },
    },
    '4001724012345',
  );

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async => salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return productSuggestions;
  }

  static List<ProductSearchResult> get productSuggestions =>
      <ProductSearchResult>[
        ProductSearchResult(
          code: '4001724012345',
          title: 'Die Ofenfrische Salami · Dr. Oetker',
          subtitle: 'Dr. Oetker · 390 g · 252 kcal / 100 g',
          kcalPer100G: 252,
          result: salamiPizza,
        ),
      ];
}

class _FlakyProductLookupService implements ProductLookupService {
  int searchAttempts = 0;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      _FakeProductLookupService.salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    searchAttempts++;
    if (searchAttempts <= 2) {
      throw Exception('temporary OpenFoodFacts failure');
    }
    return _FakeProductLookupService.productSuggestions;
  }
}

class _EmptyThenSuccessProductLookupService implements ProductLookupService {
  int searchAttempts = 0;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      _FakeProductLookupService.salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    searchAttempts++;
    if (searchAttempts <= 2) {
      return const <ProductSearchResult>[];
    }
    return _FakeProductLookupService.productSuggestions;
  }
}
