// Tab-Rahmen der Schale — W3-01.
//
//  * D6: `buildSelectedScreen()` war ein `switch`, der genau EINEN Teilbaum
//    erzeugte, und beide Wrapper trugen ein `ValueKey` pro Tab — das Unmounten
//    war also aktiv erzwungen. Ein getippter Coach-Entwurf war nach einem
//    Blick in die Rezepte weg, `_bootstrap()` feuerte drei Netzaufrufe pro
//    Besuch, und das Rezept-Suchfeld verlor seinen Text.
//  * D7: Repo-weit null Treffer fuer `PopScope`/`WillPopScope` — die
//    Zurueck-Taste schloss aus dem Coach- oder Rezepte-Tab die App.
//
// Die Tests fahren die echte EatovaHomePage ohne Sync (Preview-Pfad): kein
// Boot-Gate, kein Onboarding, alle drei Tabs erreichbar.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

/// Tab-Wechsel ueber den Store statt ueber einen Tap auf die Bottom-Nav: der
/// Coach-Orb animiert endlos, ein `pumpAndSettle` wuerde nie settlen.
Future<void> _goToTab(WidgetTester tester, int tab) async {
  _storeOf(tester).setTab(tab);
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Headless-Schriftmetriken erzeugen Overflows, die auf dem Geraet nicht
  // auftreten (gleiche Begruendung wie in test/flows/flow_test_helpers.dart).
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(
    MaterialApp(theme: buildEatovaTheme(), home: EatovaHomePage()),
  );
  await tester.pump();
}

void main() {
  group('D6 — Tab-Wechsel behaelt den Zustand', () {
    testWidgets('nie besuchte Tabs werden gar nicht erst gebaut',
        (tester) async {
      await _pumpHome(tester);

      // skipOffstage: false — sonst uebersieht der Finder auch einen
      // GEBAUTEN, nur unsichtbaren IndexedStack-Tab und der Test waere blind.
      expect(find.byType(MealAnalysisScreen), findsOneWidget);
      expect(find.byType(RecipesScreen, skipOffstage: false), findsNothing,
          reason: 'ein eager IndexedStack baute jeden Tab beim Kaltstart');
      expect(find.byType(CoachChatScreen, skipOffstage: false), findsNothing,
          reason: 'CoachChatScreen.initState feuert drei Netzaufrufe');
    });

    testWidgets('der Coach-Teilbaum ueberlebt einen Ausflug in die Rezepte',
        (tester) async {
      await _pumpHome(tester);

      await _goToTab(tester, 2);
      final coachState = tester.state(find.byType(CoachChatScreen));

      await _goToTab(tester, 1);
      await _goToTab(tester, 2);

      expect(
        identical(tester.state(find.byType(CoachChatScreen)), coachState),
        isTrue,
        reason: 'ein neuer State heisst: _bootstrap() laeuft erneut, mit '
            'Spinner, und der getippte Entwurf ist weg',
      );
    });

    testWidgets('der Entwurfs-Controller des Composers ueberlebt den Wechsel',
        (tester) async {
      // Ohne CoachChatService ist das Eingabefeld disabled — `enterText` liefe
      // ins Leere. Gemessen wird deshalb der Traeger des Entwurfs: der
      // TextEditingController lebt in _CoachChatScreenState. Bleibt DIE Instanz
      // ueber den Tab-Wechsel dieselbe, ueberlebt auch ihr Text.
      await _pumpHome(tester);
      await _goToTab(tester, 2);

      final feld = find.byKey(const ValueKey('coach-input'));
      final controller = tester.widget<TextField>(feld).controller;
      expect(controller, isNotNull);

      await _goToTab(tester, 0);
      await _goToTab(tester, 2);

      expect(identical(tester.widget<TextField>(feld).controller, controller),
          isTrue);
    });

    testWidgets('der Text im Rezept-Suchfeld bleibt stehen', (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 1);

      await tester.enterText(
        find.byKey(const ValueKey('recipes-search-input')),
        'Lachs',
      );
      // Entfokussieren: ein fokussiertes EditableText haelt sich per
      // AutomaticKeepAliveClientMixin selbst in der lazy ListView am Leben —
      // der Test wuerde sonst gruen sein, ohne etwas zu beweisen.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await _goToTab(tester, 0);
      await _goToTab(tester, 1);

      expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('recipes-search-input')))
            .controller
            ?.text,
        'Lachs',
      );
    });

    testWidgets('der Food-Tab bleibt beim Wechsel gemountet', (tester) async {
      await _pumpHome(tester);
      // MealAnalysisScreen ist stateless — Element-Identitaet ist hier das
      // Mount-Signal: ein Remount wirft das alte Element weg.
      final foodElement = tester.element(find.byType(MealAnalysisScreen));

      await _goToTab(tester, 1);
      await _goToTab(tester, 0);

      expect(
        identical(tester.element(find.byType(MealAnalysisScreen)), foodElement),
        isTrue,
      );
    });
  });

  group('D7 — Zurueck-Taste', () {
    testWidgets('aus dem Coach-Tab fuehrt Zurueck auf Food statt aus der App',
        (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 2);
      expect(_storeOf(tester).selectedTab, 2);

      final handled = await WidgetsBinding.instance.handlePopRoute();
      await tester.pump();

      expect(handled, isTrue, reason: 'sonst schliesst das System die App');
      expect(_storeOf(tester).selectedTab, 0);
    });

    testWidgets('aus dem Rezepte-Tab ebenso', (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 1);

      expect(await WidgetsBinding.instance.handlePopRoute(), isTrue);
      await tester.pump();
      expect(_storeOf(tester).selectedTab, 0);
    });

    testWidgets('auf Food schliesst Zurueck die App normal (kein Klemmen)',
        (tester) async {
      await _pumpHome(tester);
      expect(_storeOf(tester).selectedTab, 0);

      expect(await WidgetsBinding.instance.handlePopRoute(), isFalse,
          reason: 'der Food-Tab ist die Wurzel — hier gehoert die App zu');
      expect(_storeOf(tester).selectedTab, 0);
    });

    testWidgets('eine gepushte Route poppt zuerst, der Tab bleibt stehen',
        (tester) async {
      // Rezepte-Tab statt Coach: der CoachOrb animiert endlos, ein
      // pumpAndSettle waehrend Tab 2 sichtbar ist wuerde nie settlen.
      await _pumpHome(tester);
      await _goToTab(tester, 1);

      // Route oeffnen (liegt UEBER dem Home) und mit Zurueck schliessen.
      Navigator.of(tester.element(find.byType(EatovaHomePage))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(key: ValueKey('test-pushed-route')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-pushed-route')), findsOneWidget);

      expect(await WidgetsBinding.instance.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-pushed-route')), findsNothing);
      expect(_storeOf(tester).selectedTab, 1,
          reason: 'das PopScope der Schale gehoert der Home-Route, nicht der '
              'gepushten Route darueber');
    });
  });

  group('C8 — KI-Offenlegung im Coach-Tab', () {
    // Die Offenlegung liegt vollstaendig in den Coach-Screens (Composer-
    // Platzhalter, antippbarer Hinweis im Leerzustand, (i)-Sheet mit der
    // Liste der mitgehenden Daten) — nicht mehr im Tab-Rahmen. Eine zweite
    // Zeile hier waere dieselbe Aussage doppelt, im Leerzustand direkt
    // uebereinander. Die Inhalte pruefen `test/coach_ai_disclosure_test.dart`
    // und `test/coach_*`; hier bleibt nur die Aussage, DASS der Tab sie traegt.
    testWidgets('der Coach-Tab nennt die KI', (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 2);

      expect(find.byKey(const ValueKey('coach-ai-note')), findsOneWidget,
          reason: 'der antippbare Hinweis im Leerzustand fuehrt ins (i)-Sheet');
    });

    testWidgets('der Tab-Rahmen traegt keine zweite Offenlegung',
        (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 2);

      expect(find.byKey(const ValueKey('coach-ai-disclosure')), findsNothing,
          reason: 'sonst steht die Aussage doppelt untereinander');
    });
  });
}
