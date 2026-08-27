// Tab frame of the shell — W3-01.
//
//  * D6: unmounting was actively forced (a `switch` plus a per-tab `ValueKey`),
//    so a typed coach draft was gone after a trip to the recipes and
//    `_bootstrap()` fired three network calls per visit.
//  * D7: no `PopScope` anywhere, so back closed the app from the coach or
//    recipes tab.
//
// The tests boot the real EatovaHomePage without sync (preview path): no boot
// gate, no onboarding, all tabs reachable. Tab indices: Heute 0, Food 1,
// recipes 2, coach 3.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/screens/today/today_screen.dart';

import 'support/harness.dart';

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

/// Tab switch via the store instead of a tap on the bottom nav: the coach orb
/// animates forever, so `pumpAndSettle` would never settle.
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

  // Headless font metrics produce overflows that never happen on a device
  // (same reasoning as test/flows/flow_test_helpers.dart).
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await pumpLocalized(
    tester,
    EatovaHomePage(),
    // The shell brings its own Scaffold and safe-area handling.
    scaffold: false,
    safeArea: false,
  );
  await tester.pump();
}

void main() {
  group('D6 — Tab-Wechsel behaelt den Zustand', () {
    testWidgets('nie besuchte Tabs werden gar nicht erst gebaut',
        (tester) async {
      await _pumpHome(tester);

      // skipOffstage: false, or the finder would miss a BUILT but invisible
      // IndexedStack tab and the test would be blind.
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(find.byType(MealAnalysisScreen, skipOffstage: false), findsNothing,
          reason: 'Food ist seit dem Refactor Tab 1, nicht mehr der Landepunkt');
      expect(find.byType(RecipesScreen, skipOffstage: false), findsNothing,
          reason: 'ein eager IndexedStack baute jeden Tab beim Kaltstart');
      expect(find.byType(CoachChatScreen, skipOffstage: false), findsNothing,
          reason: 'CoachChatScreen.initState feuert drei Netzaufrufe');
    });

    testWidgets('der Coach-Teilbaum ueberlebt einen Ausflug in die Rezepte',
        (tester) async {
      await _pumpHome(tester);

      await _goToTab(tester, 3);
      final coachState = tester.state(find.byType(CoachChatScreen));

      await _goToTab(tester, 2);
      await _goToTab(tester, 3);

      expect(
        identical(tester.state(find.byType(CoachChatScreen)), coachState),
        isTrue,
        reason: 'ein neuer State heisst: _bootstrap() laeuft erneut, mit '
            'Spinner, und der getippte Entwurf ist weg',
      );
    });

    testWidgets('der Entwurfs-Controller des Composers ueberlebt den Wechsel',
        (tester) async {
      // Without a CoachChatService the field is disabled, so `enterText` would
      // do nothing. Measure the draft's carrier instead: if the
      // TextEditingController instance survives the switch, so does its text.
      await _pumpHome(tester);
      await _goToTab(tester, 3);

      final feld = find.byKey(const ValueKey('coach-input'));
      final controller = tester.widget<TextField>(feld).controller;
      expect(controller, isNotNull);

      await _goToTab(tester, 0);
      await _goToTab(tester, 3);

      expect(identical(tester.widget<TextField>(feld).controller, controller),
          isTrue);
    });

    testWidgets('der Text im Rezept-Suchfeld bleibt stehen', (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 2);

      await tester.enterText(
        find.byKey(const ValueKey('recipes-search-input')),
        'Lachs',
      );
      // Unfocus: a focused EditableText keeps itself alive in the lazy
      // ListView via AutomaticKeepAliveClientMixin, so the test would be green
      // without proving anything.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await _goToTab(tester, 0);
      await _goToTab(tester, 2);

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
      // Food is tab 1 and unbuilt at cold start — switch there, then measure.
      await _goToTab(tester, 1);
      // MealAnalysisScreen is stateless, so element identity is the mount
      // signal: a remount throws the old element away.
      final foodElement = tester.element(find.byType(MealAnalysisScreen));

      await _goToTab(tester, 2);
      await _goToTab(tester, 1);

      expect(
        identical(tester.element(find.byType(MealAnalysisScreen)), foodElement),
        isTrue,
      );
    });
  });

  group('D7 — Zurueck-Taste', () {
    // Back always targets tab 0.
    testWidgets('aus dem Coach-Tab fuehrt Zurueck auf Heute statt aus der App',
        (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 3);
      expect(_storeOf(tester).selectedTab, 3);

      final handled = await WidgetsBinding.instance.handlePopRoute();
      await tester.pump();

      expect(handled, isTrue, reason: 'sonst schliesst das System die App');
      expect(_storeOf(tester).selectedTab, 0);
    });

    testWidgets('aus dem Rezepte-Tab ebenso', (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 2);

      expect(await WidgetsBinding.instance.handlePopRoute(), isTrue);
      await tester.pump();
      expect(_storeOf(tester).selectedTab, 0);
    });

    testWidgets('aus dem Food-Tab ebenso', (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 1);

      expect(await WidgetsBinding.instance.handlePopRoute(), isTrue);
      await tester.pump();
      expect(_storeOf(tester).selectedTab, 0);
    });

    testWidgets('auf Heute schliesst Zurueck die App normal (kein Klemmen)',
        (tester) async {
      await _pumpHome(tester);
      expect(_storeOf(tester).selectedTab, 0);

      expect(await WidgetsBinding.instance.handlePopRoute(), isFalse,
          reason: 'der Heute-Tab ist die Wurzel — hier gehoert die App zu');
      expect(_storeOf(tester).selectedTab, 0);
    });

    testWidgets('eine gepushte Route poppt zuerst, der Tab bleibt stehen',
        (tester) async {
      // Recipes tab, not coach: the CoachOrb animates forever and
      // pumpAndSettle would never settle there.
      await _pumpHome(tester);
      await _goToTab(tester, 2);

      // Open a route above home and close it with back.
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
      expect(_storeOf(tester).selectedTab, 2,
          reason: 'das PopScope der Schale gehoert der Home-Route, nicht der '
              'gepushten Route darueber');
    });
  });

  group('C8 — KI-Offenlegung im Coach-Tab', () {
    // The disclosure lives entirely in the coach screens, not in the tab
    // frame; a second line here would repeat it. The content is checked by
    // `test/coach_ai_disclosure_test.dart`, this group only asserts presence.
    testWidgets('der Coach-Tab nennt die KI', (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 3);

      expect(find.byKey(const ValueKey('coach-ai-note')), findsOneWidget,
          reason: 'der antippbare Hinweis im Leerzustand fuehrt ins (i)-Sheet');
    });

    testWidgets('der Tab-Rahmen traegt keine zweite Offenlegung',
        (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 3);

      expect(find.byKey(const ValueKey('coach-ai-disclosure')), findsNothing,
          reason: 'sonst steht die Aussage doppelt untereinander');
    });
  });
}
