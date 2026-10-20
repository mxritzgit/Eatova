// Apple Health's permission sheet no longer appears over the onboarding
// (review 2026-10-19). The shell asked HealthKit right after its first frame,
// while the onboarding was showing; now it asks once the onboarding is known
// complete, and after an onboarding only through Today's intro card. An
// account onboarded before keeps connecting on its own.
//
// Setup as test/home_page_onboarding_pop_test.dart: `needsOnboarding` needs a
// real EatovaSync, so the page boots over a MockClient Supabase.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'support/harness.dart';

const _user = 'user-health-intro';

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

/// Every read returns `[]` (no profile row), every write an empty object.
http.Client _emptyServer() => MockClient(
  (req) async => http.Response(
    jsonEncode(
      req.method == 'GET'
          ? const <dynamic>[]
          : <dynamic>[<String, dynamic>{}],
    ),
    200,
    headers: const {'Content-Type': 'application/json'},
    request: req,
  ),
);

EatovaSync _sync() => EatovaSync.forUser(
  SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: _emptyServer(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  ),
  _user,
);

/// HealthKit as the shell sees it on iOS: unknown until asked.
class _AppleHealth implements HealthService {
  int requests = 0;

  @override
  HealthAuthState authState = HealthAuthState.unknown;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async {
    requests++;
    return authState = HealthAuthState.unverified;
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async => null;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;
}

Future<void> _drain(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required LocalCache cache,
  required HealthService health,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await pumpLocalized(
    tester,
    EatovaHomePage(
      sync: _sync(),
      debugCache: cache,
      healthService: health,
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
  testWidgets('no HealthKit sheet over the onboarding; Today asks first', (
    tester,
  ) async {
    final health = _AppleHealth();
    await _pumpShell(
      tester,
      cache: LocalCache(InMemoryKeyValueStore(), _user),
      health: health,
    );
    expect(_storeOf(tester).needsOnboarding, isTrue, reason: 'precondition');
    await _drain(tester);
    expect(health.requests, 0);

    await tester.runAsync(
      () => _storeOf(tester).completeOnboarding(
        const UserProfile(weightKg: 82, heightCm: 180, onboardingCompleted: true),
      ),
    );
    await _drain(tester);

    expect(health.requests, 0, reason: 'the card asks, not the shell');
    final card = find.byKey(const ValueKey('today-health-prompt'));
    expect(card, findsOneWidget);

    // A resume is no unprompted ask either.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _drain(tester);
    expect(health.requests, 0);

    final connect = find.byKey(const ValueKey('today-health-prompt-connect'));
    await tester.ensureVisible(connect);
    await tester.tap(connect);
    await _drain(tester);

    expect(health.requests, 1);
    expect(card, findsNothing);
  });

  testWidgets('an account onboarded before connects without a card', (
    tester,
  ) async {
    final health = _AppleHealth();
    final cache = LocalCache(InMemoryKeyValueStore(), _user);
    await tester.runAsync(
      () => cache.writeProfile(
        const UserProfile(weightKg: 82, heightCm: 180, onboardingCompleted: true),
      ),
    );

    await _pumpShell(tester, cache: cache, health: health);
    await _drain(tester);

    expect(_storeOf(tester).needsOnboarding, isFalse, reason: 'precondition');
    expect(health.requests, 1);
    expect(find.byKey(const ValueKey('today-health-prompt')), findsNothing);
  });
}
