// D7 x D4 — the two PopScopes must never meet (W3-01).
//
// `ModalRoute.onPopInvokedWithResult` calls ALL PopScopes registered in the
// route, so with the shell's (tab return, D7) and the onboarding's in the tree
// at once, a system back would step back in onboarding AND switch the tab.
//
// Safeguard: the shell's PopScope sits BEHIND the early return
// `if (_store.needsOnboarding) return OnboardingScreen(...)`. This test pins
// that order.
//
// Setup mirrors test/clobber_guard_test.dart: `needsOnboarding` needs a real
// EatovaSync, so the page boots over a MockClient Supabase.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'support/harness.dart';

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

/// Empty fake server: every read returns `[]` (no profile -> no
/// `onboarding_completed` -> onboarding gate), every write an empty object.
http.Client _emptyServer() => MockClient((req) async {
      final isWrite = req.method == 'POST' ||
          req.method == 'PATCH' ||
          req.method == 'PUT';
      return http.Response(
        jsonEncode(isWrite ? [<String, dynamic>{}] : const <dynamic>[]),
        isWrite ? 200 : 200,
        headers: const {'Content-Type': 'application/json'},
        request: req,
      );
    });

EatovaSync _sync() {
  // autoRefreshToken: false, or GoTrue's 10s ticker stays a pending timer in
  // the FakeAsync zone (see clobber_guard_test.dart).
  final supa = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: _emptyServer(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  return EatovaSync.forUser(supa, 'user-onboarding-pop');
}

Future<void> _drain(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _pumpOnboarding(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Reduced motion collapses the welcome durations to Duration.zero; the
  // indeterminate boot spinner would otherwise hang.
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  // Onboarding and shell read colors via `context.t`, and AppTokens.of throws
  // on purpose when the ThemeExtension is missing — hence the themed harness.
  await pumpLocalized(
    tester,
    EatovaHomePage(
      sync: _sync(),
      debugCache: LocalCache(InMemoryKeyValueStore(), 'user-onboarding-pop'),
      showWelcome: false,
    ),
    brightness: Brightness.light,
    scaffold: false,
    safeArea: false,
  );

  final welcome = find.byKey(const ValueKey('screen-welcome'));
  for (var i = 0; i < 80 && welcome.evaluate().isNotEmpty; i++) {
    await _drain(tester, rounds: 1);
  }
  await _drain(tester, rounds: 6);
}

void main() {
  testWidgets(
      'waehrend des Onboardings loest ein Systemzurueck KEINEN Tab-Wechsel aus',
      (tester) async {
    await _pumpOnboarding(tester);
    expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);

    // The store sits on a non-food tab. With the shell's PopScope in the tree
    // during onboarding, the pop would switch it to 0.
    final store = _storeOf(tester);
    store.setTab(2);
    await _drain(tester, rounds: 4);
    expect(store.selectedTab, 2);

    await WidgetsBinding.instance.handlePopRoute();
    await _drain(tester, rounds: 4);

    expect(store.selectedTab, 2,
        reason: 'das PopScope der Schale liegt hinter dem '
            'needsOnboarding-Early-Return und darf hier gar nicht existieren');
    expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 45)));
}
