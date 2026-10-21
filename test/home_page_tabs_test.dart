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
// recipes 2, Training 3, coach 4.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';

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
    testWidgets('Coach-State und Entwurfs-Controller ueberleben einen '
        'Ausflug in andere Tabs', (tester) async {
      // Without a CoachChatService the field is disabled, so `enterText` would
      // do nothing. Measure the draft's carrier instead: if the State and the
      // TextEditingController survive the switch, so does the typed text.
      await _pumpHome(tester);
      await _goToTab(tester, 4);
      final coachState = tester.state(find.byType(CoachChatScreen));
      final feld = find.byKey(const ValueKey('coach-input'));
      final controller = tester.widget<TextField>(feld).controller;
      expect(controller, isNotNull);

      await _goToTab(tester, 2);
      await _goToTab(tester, 0);
      await _goToTab(tester, 4);

      expect(
        identical(tester.state(find.byType(CoachChatScreen)), coachState),
        isTrue,
        reason: 'ein neuer State heisst: _bootstrap() laeuft erneut, mit '
            'Spinner, und der getippte Entwurf ist weg',
      );
      expect(identical(tester.widget<TextField>(feld).controller, controller),
          isTrue);
    });

    // The recipe search draft surviving a tab trip is pinned in
    // page_chrome_test.dart ('Today opens the correct account routes and keeps
    // tab drafts') and navigation_interactions_test.dart with the real app.
  });

  group('D7 — Zurueck-Taste', () {
    // Back always targets tab 0.
    testWidgets('aus Coach, Rezepte und Food fuehrt Zurueck auf Heute statt '
        'aus der App', (tester) async {
      await _pumpHome(tester);
      for (final tab in const [4, 2, 1]) {
        await _goToTab(tester, tab);
        expect(_storeOf(tester).selectedTab, tab);

        final handled = await WidgetsBinding.instance.handlePopRoute();
        await tester.pump();

        expect(handled, isTrue,
            reason: 'Tab $tab: sonst schliesst das System die App');
        expect(_storeOf(tester).selectedTab, 0, reason: 'Tab $tab');
      }
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
    testWidgets('der Coach-Tab nennt die KI genau einmal', (tester) async {
      await _pumpHome(tester);
      await _goToTab(tester, 4);

      expect(find.byKey(const ValueKey('coach-ai-note')), findsOneWidget,
          reason: 'der antippbare Hinweis im Leerzustand fuehrt ins (i)-Sheet');
      // Counts the statement itself: the old frame key `coach-ai-disclosure`
      // exists nowhere in lib/ any more, so a key check could not fail.
      expect(
        find.textContaining(deL10n.coachDisclaimer, findRichText: true),
        findsOneWidget,
        reason: 'sonst steht die Aussage doppelt untereinander',
      );
    });
  });
}
