// D7 x D4 — die beiden PopScopes duerfen sich nie begegnen (W3-01).
//
// Seit D4 bringt die OnboardingScreen ein eigenes `PopScope` mit
// (onboarding_screen.dart, `canPop: _index == 0`). `ModalRoute
// .onPopInvokedWithResult` ruft ALLE in der Route registrierten PopScopes auf —
// stuenden das der Schale (Tab-Rueckkehr, D7) und das des Onboardings
// gleichzeitig im Baum, ginge ein Systemzurueck einen Onboarding-Schritt
// zurueck UND wechselte gleichzeitig den Tab.
//
// Absicherung: das PopScope der Schale liegt HINTER dem Early-Return
// `if (_store.needsOnboarding) return OnboardingScreen(...)`. Dieser Test
// haelt die Reihenfolge fest, damit der naechste, der sie anfasst, es merkt.
//
// Der Aufbau spiegelt test/clobber_guard_test.dart: `needsOnboarding` verlangt
// einen echten EatovaSync, also faehrt der Test die Page ueber einen
// MockClient-Supabase hoch.

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

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

/// Leerer Fake-Server: jeder Read liefert `[]` (kein Profil -> kein
/// `onboarding_completed` -> Onboarding-Gate), jeder Write ein leeres Objekt.
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
  // autoRefreshToken: false — sonst bleibt GoTrues 10s-Ticker als pending
  // Timer in der FakeAsync-Zone haengen (s. clobber_guard_test.dart).
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

  // Reduzierte Bewegung: kollabiert die Welcome-Dauern auf Duration.zero,
  // sonst haengt der indeterminate Boot-Spinner (s. clobber_guard_test.dart).
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(MaterialApp(
    home: EatovaHomePage(
      sync: _sync(),
      debugCache: LocalCache(InMemoryKeyValueStore(), 'user-onboarding-pop'),
      showWelcome: false,
    ),
  ));

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

    // Der Store steht auf einem Nicht-Food-Tab. Waere das PopScope der Schale
    // waehrend des Onboardings mit im Baum, schaltete der Pop hier auf 0 —
    // der Nutzer saehe gleichzeitig einen Onboarding-Schritt zurueck und
    // landete hinter dem Onboarding auf Food.
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
