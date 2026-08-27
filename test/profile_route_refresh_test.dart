import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/services/health_service.dart';

import 'support/harness.dart';

// INT-B / ARCH-1+PERF-2 tests for eatova_home_page.dart:
//
//  * The setState override bumps _profileRefresh only while the pushed
//    ProfileScreen route is open (_profileRouteOpen). That route lives in its
//    own navigator subtree which HomePage's setState cannot reach, so
//    AnimatedBuilder + _profileRefresh is the bridge carrying a mid-route
//    state change (a health steps refresh) into the open screen. Test 1
//    proves the bridge is intact.
//  * Test 2 (scoping sanity): after closing the route a store notify no
//    longer bumps _profileRefresh, and a Food-tab mutation stays crash-free.
//
// sync == null on purpose: the page lands on home immediately (no onboarding
// gate) and the health paths run without Supabase.

/// HealthService with a switchable steps answer. authState = granted so the
/// ProfileScreen shows the 'profile-health-refresh' button. [nextSteps] picks
/// the value the next readSnapshot() returns.
class _StepsHealthService implements HealthService {
  _StepsHealthService(this.nextSteps);

  int nextSteps;
  HealthAuthState _state = HealthAuthState.granted;
  int snapshotReads = 0;

  @override
  HealthAuthState get authState => _state;

  @override
  void reset() => _state = HealthAuthState.unknown;

  @override
  Future<HealthAuthState> requestAuthorization() async {
    _state = HealthAuthState.granted;
    return _state;
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    snapshotReads++;
    return HealthSnapshot(stepsToday: nextSteps, fetchedAt: DateTime.now());
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => true;

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      const <WeightSample>[];

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;
}

void _pinViewport(WidgetTester tester) {
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
}

void main() {
  testWidgets(
      'Offene ProfileScreen reflektiert einen mid-route Health-Steps-Refresh '
      '(AnimatedBuilder/_profileRefresh-Bruecke intakt)', (tester) async {
    _pinViewport(tester);
    // Boot snapshot: 1000 steps. The post-frame _connectHealth grants
    // authorization and reads the snapshot, making the refresh button visible.
    final health = _StepsHealthService(1000);

    // _navItems() reads context.l10n; without the harness's delegates
    // AppLocalizations.of() throws while building the bottom nav.
    await pumpLocalized(
      tester,
      EatovaHomePage(
        initialUserName: 'Moritz',
        healthService: health,
      ),
      reducedMotion: false,
      scaffold: false,
      safeArea: false,
    );
    await tester.pumpAndSettle();

    // The shell lands on Today (tab 0); the TopBar avatar this test uses as
    // its entry point lives on the Food tab (index 1), so switch there first.
    // What is under test is still the _profileRefresh bridge, not the path.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Open the ProfileScreen (avatar -> _openProfile -> _profileRouteOpen).
    await tester.tap(find.byKey(const ValueKey('topbar-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);

    // Default steps goal is 8000; the tile shows the boot state 1000/8000.
    expect(find.text('1000/8000'), findsOneWidget);

    // Switch the health store mid-route and trigger _refreshHealthSteps from
    // the open screen. That is a HomePage setState UNDER the open route, so
    // only the _profileRefresh bridge carries the new value across.
    health.nextSteps = 12345;
    // The button sits far down the scrollable screen, off-screen at the
    // pinned viewport height — scroll it into view or tap() misses.
    final refreshBtn = find.byKey(const ValueKey('profile-health-refresh'));
    await tester.ensureVisible(refreshBtn);
    await tester.pumpAndSettle();
    await tester.tap(refreshBtn);
    await tester.pumpAndSettle();

    // Proof: the open ProfileScreen now shows the fresh steps value.
    expect(find.text('12345/8000'), findsOneWidget,
        reason: 'mid-route Health-Refresh muss auf der offenen ProfileScreen '
            'ankommen (_profileRouteOpen-gegated _profileRefresh-Bump)');
    expect(find.text('1000/8000'), findsNothing);
  });

  testWidgets(
      'Nach Schliessen der ProfileScreen bleibt eine Food-Tab-Mutation '
      'crash-frei (Scoping-Sanity: geschlossene Profil-Bruecke)', (tester) async {
    _pinViewport(tester);
    final health = _StepsHealthService(2000);

    // _navItems() reads context.l10n; without the harness's delegates
    // AppLocalizations.of() throws while building the bottom nav.
    await pumpLocalized(
      tester,
      EatovaHomePage(
        initialUserName: 'Moritz',
        healthService: health,
      ),
      reducedMotion: false,
      scaffold: false,
      safeArea: false,
    );
    await tester.pumpAndSettle();

    // To the Food tab first (index 1): both the avatar and the date chip
    // used below live there.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Open and close again -> _profileRouteOpen is false once more.
    await tester.tap(find.byKey(const ValueKey('topbar-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

    // A store mutation now notifies with no profile route open, so
    // _profileRefresh is not bumped; this must stay crash-free and re-render.
    await tester.tap(find.byKey(const ValueKey('food-date-chip-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
  });
}
