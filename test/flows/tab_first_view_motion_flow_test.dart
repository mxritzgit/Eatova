// The first-view entrance of the tabs in the REAL shell (motion polish,
// 2026-10-01): the first time a tab is shown in a session its sections fade
// in and rise one after another; coming back to the tab shows it as it is.
// The shell keeps visited tabs mounted, so the entrance is bound to the
// mount, and its whole-tab LivelyEntrance steps aside for the stagger.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/widgets/common/lively.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import 'flow_test_helpers.dart'
    show FakeProductLookupService, pumpUntil, settleFrames, storeOf;

final DateTime _now = DateTime(2026, 9, 28, 12);

const UserProfile _profile = UserProfile(
  weightKg: 80,
  heightCm: 180,
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  onboardingCompleted: true,
  manualEnergy: true,
);

const int _tabFood = 1;
const int _tabTraining = 3;

Future<void> _pumpShell(WidgetTester tester) async {
  pinPhoneViewport(tester);
  final server = FixlaufServer()..profileRow = serverProfileRow(_profile);
  // Mock transport owns no sockets; not disposed (see pumpSignedIn).
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await pumpLocalized(
    tester,
    EatovaHomePage(
      productService: FakeProductLookupService(),
      sync: EatovaSync.forUser(client, kFixlaufUser),
      debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
      showWelcome: false,
    ),
    locale: const Locale('en'),
    scaffold: false,
    safeArea: false,
    reducedMotion: false,
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'boot completes',
  );
}

/// Opacities of the entrance sections below [screen], top to bottom.
List<double> _sections(WidgetTester tester, Finder screen) => [
  for (final element
      in find
          .descendant(of: screen, matching: find.byType(LivelyStaggerItem))
          .evaluate())
    tester
        .widget<FadeTransition>(
          find
              .descendant(
                of: find.byWidget(element.widget),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value,
];

void main() {
  testWidgets('ein Tab kommt beim ersten Zeigen gestaffelt herein, beim '
      'Zurueckkehren nicht', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpShell(tester);
      final food = find.byKey(const ValueKey('screen-kcal-tracker'));
      expect(food, findsNothing, reason: 'tabs mount on first display');

      storeOf(tester).setTab(_tabFood);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final entering = _sections(tester, food);
      expect(entering.length, greaterThanOrEqualTo(3));
      // Top first: the header is further along than the sections below.
      expect(entering.first, inExclusiveRange(0, 1));
      expect(entering.first, greaterThan(entering[2]));

      await settleFrames(tester);
      expect(_sections(tester, food), everyElement(1.0));

      // Away and back: the tab stays mounted and does not replay.
      storeOf(tester).setTab(_tabTraining);
      await settleFrames(tester);
      storeOf(tester).setTab(_tabFood);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(_sections(tester, food), everyElement(1.0));
    });
  });
}
