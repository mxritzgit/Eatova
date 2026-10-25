import 'support/food_navigation.dart';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'flows/flow_test_helpers.dart'
    show FakeProductLookupService, pumpUntil, settleFrames;
import 'support/fixlauf_a_helpers.dart'
    show FixlaufServer, completedProfile, kFixlaufUser, serverProfileRow;
import 'support/harness.dart';
import 'support/subscription_fakes.dart';

// INT-B / ARCH-1+PERF-2 tests for eatova_home_page.dart:
//
//  * The setState override bumps _profileRefresh only while the pushed
//    ProfileScreen route is open (_profileRouteOpen). That route lives in its
//    own navigator subtree which HomePage's setState cannot reach, so
//    AnimatedBuilder + _profileRefresh is the bridge carrying a mid-route
//    state change (a health steps refresh) into the open screen. Test 1
//    proves the bridge is intact.
//  * The account's plan notifies outside the store, so the open profile and
//    settings listen to the SubscriptionController too (Premium, 2026-10-25).
//
// sync == null on purpose: the page lands on home immediately (no onboarding
// gate) and the health paths run without Supabase. Only the plan test boots
// over a fake server, since a plan needs an account.

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
    return HealthSnapshot(stepsToday: nextSteps, fetchedAt: clock.now());
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => true;

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

    // Visit Food, then open the account from Today; the refresh bridge must
    // remain live independently of which tabs were previously mounted.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Open the ProfileScreen (avatar -> _openProfile -> _profileRouteOpen).
    await tapHomeHeaderAction(tester, 'today-profile');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);

    // Default steps goal is 8000; the goals card's steps row shows the boot
    // state 1000/8000.
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
      'ein Doppeltipp auf den Avatar oeffnet das Profil nur einmal — sonst '
      'bliebe nach dem Schliessen ein Profil ohne Bruecke offen', (tester) async {
    _pinViewport(tester);
    final health = _StepsHealthService(1000);
    await pumpLocalized(
      tester,
      EatovaHomePage(initialUserName: 'Moritz', healthService: health),
      reducedMotion: false,
      scaffold: false,
      safeArea: false,
    );
    await tester.pumpAndSettle();

    // A second tap can land on the avatar while the first push still
    // animates; both reach the shell's handler.
    final today = tester.widget<TodayScreen>(find.byType(TodayScreen));
    today.onOpenProfile!();
    today.onOpenProfile!();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('screen-profile'), skipOffstage: false),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('profile-close')));
    await tester.pumpAndSettle();

    // Otherwise the lower copy stayed open while the closed one had already
    // switched off the refresh bridge: a weight logged there never showed.
    expect(
      find.byKey(const ValueKey('screen-profile'), skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets(
      'Ziele und Einstellungen oeffnen bei einem Doppeltipp nur je eine Seite',
      (tester) async {
    _pinViewport(tester);
    await pumpLocalized(
      tester,
      EatovaHomePage(
        initialUserName: 'Moritz',
        healthService: _StepsHealthService(1000),
      ),
      reducedMotion: false,
      scaffold: false,
      safeArea: false,
    );
    await tester.pumpAndSettle();
    tester.widget<TodayScreen>(find.byType(TodayScreen)).onOpenProfile!();
    await tester.pumpAndSettle();

    // A hidden second goals form kept the profile of its opening: saving it
    // after the first one could write the old values back.
    final profile = tester.widget<ProfileScreen>(find.byType(ProfileScreen));
    profile.onEditProfile();
    profile.onEditProfile();
    await tester.pumpAndSettle();
    expect(find.byType(GoalsScreen, skipOffstage: false), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    expect(find.byType(GoalsScreen, skipOffstage: false), findsNothing);

    profile.onOpenSettings();
    profile.onOpenSettings();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen, skipOffstage: false), findsOneWidget);
  });

  testWidgets('offenes Profil und offene Einstellungen folgen dem Plan', (
    tester,
  ) async {
    _pinViewport(tester);
    await withClock(Clock.fixed(kPlanDay), () async {
      final log = FakeSubscriptionLog(plan: planOf(PlanTier.free));
      final binding = SubscriptionBinding();
      final server = FixlaufServer()
        ..profileRow = serverProfileRow(completedProfile);
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: server.client(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await pumpLocalized(
        tester,
        SubscriptionScope(
          binding: binding,
          child: EatovaHomePage(
            productService: FakeProductLookupService(),
            sync: EatovaSync.forUser(client, kFixlaufUser, subscription: log),
            debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
            showWelcome: false,
          ),
        ),
        scaffold: false,
        safeArea: false,
      );
      await pumpUntil(
        tester,
        () => find.byKey(const ValueKey('today-profile')).evaluate().isNotEmpty,
        'die Shell nach dem Boot-Load',
      );
      Future<void> serverSays(PlanTier tier) async {
        log.plan = planOf(tier);
        await binding.controller!.refresh(force: true);
        await settleFrames(tester);
      }

      await tester.tap(find.byKey(const ValueKey('today-profile')));
      await settleFrames(tester);
      expect(
        find.byKey(const ValueKey('profile-subscription-free')),
        findsOneWidget,
      );
      await serverSays(PlanTier.premium);
      expect(
        find.byKey(const ValueKey('profile-subscription-premium')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
      await settleFrames(tester);
      final row = find.byKey(const ValueKey('settings-subscription'));
      expect(find.descendant(of: row, matching: find.text('Premium')),
          findsOneWidget);
      await serverSays(PlanTier.free);
      expect(find.descendant(of: row, matching: find.text('Free')),
          findsOneWidget);
    });
  });
}
