// Re-anchoring the profile weight on the weight trend (docs/WEIGHT-TREND.md).
//
// A weigh-in, a Health import and the boot load move `profile.weightKg` to the
// rounded `WeightLog.trendKg`. Live mode recomputes its goals in the same
// commit and names a changed kcal goal; manual mode only moves the weight.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox/outbox_test_helpers.dart';

/// Live mode, male, 182 cm, light, −0.5 kg/week: 2100 kcal at 84 kg,
/// 2050 kcal at 81 kg.
UserProfile _live({int weightKg = 84, bool manual = false, int? kcal}) {
  final base = UserProfile(
    weightKg: weightKg,
    heightCm: 182,
    ageYears: 31,
    sex: BiologicalSex.male,
    activityLevel: ActivityLevel.light,
    targetWeightKg: 76,
    weightGoal: WeightGoal.lose05kg,
    diet: DietPreference.none,
    onboardingCompleted: true,
    manualEnergy: manual,
  );
  final goals = const KcalCalculator().applyLiveGoals(base);
  return manual ? goals.copyWith(dailyKcalGoal: kcal ?? 1800) : goals;
}

int _kcalAt(int weightKg) =>
    const KcalCalculator().calculate(_live(weightKg: weightKg)).kcal;

/// Boot cases seed weigh-ins relative to this fixed "now": the trend only
/// counts while its last counted day is at most 28 days old.
final DateTime _now = DateTime(2026, 10, 3, 12);

Map<String, dynamic> _weightRow(DateTime at, double kg) => <String, dynamic>{
  'recorded_at': at.toUtc().toIso8601String(),
  'weight_kg': kg,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the scenario moves the live goal: 2100 kcal at 84, 2050 at 81', () {
    expect(_kcalAt(84), 2100);
    expect(_kcalAt(81), 2050);
  });

  test('a weigh-in moves weight and live goals together, with a notice', () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    final upsertsBefore = a.server.operations('profileUpsert').length;

    await a.store.logWeight(81.2);
    await settle();

    expect(a.store.profile.weightKg, 81);
    expect(a.store.profile.dailyKcalGoal, 2050);
    expect(a.server.profileRow!['weight_kg'], 81);
    expect(a.server.profileRow!['daily_kcal_goal'], 2050);
    expect(a.server.operations('profileUpsert').length - upsertsBefore, 1);
    expect(
      a.snacks.messages,
      contains('Neues Tagesziel: 2050 kcal – an deinen Gewichtstrend angepasst.'),
    );
  });

  test('offline, the weigh-in and the profile update are ONE local commit', () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    a.server.offline = true;

    await a.store.logWeight(81.2);
    await settle();

    final kinds = a.store.pendingOutbox.map((op) => op.kind).toList();
    expect(kinds, [SyncOpKind.weightInsert, SyncOpKind.profileUpsert]);
    expect(
      a.store.pendingOutbox.last.profile!.weightKg,
      81,
      reason: 'the queued profile carries the re-anchored weight',
    );
  });

  test('a weigh-in that keeps the rounded trend writes no profile', () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live(weightKg: 81));
    await boot(a.store);
    final before = a.store.profile;
    final upsertsBefore = a.server.operations('profileUpsert').length;
    a.snacks.messages.clear();

    await a.store.logWeight(81.3);
    await settle();

    expect(identical(a.store.profile, before), isTrue);
    expect(a.server.operations('profileUpsert').length, upsertsBefore);
    expect(a.snacks.messages, isEmpty);
  });

  test('manual mode: the weight follows, the goals stay, no notice', () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live(manual: true, kcal: 1800))
      ..['manual_energy'] = true;
    await boot(a.store);
    expect(a.store.profile.manualEnergy, isTrue, reason: 'precondition');
    a.snacks.messages.clear();

    await a.store.logWeight(81.2);
    await settle();

    expect(a.store.profile.weightKg, 81);
    expect(a.store.profile.dailyKcalGoal, 1800);
    expect(a.snacks.messages, isEmpty);
  });

  test('the Health import re-anchors the same way', () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);

    await a.store.importHealthWeight(81.2);
    await settle();

    expect(a.store.profile.weightKg, 81);
    expect(a.store.profile.dailyKcalGoal, 2050);
  });

  test('the boot catches up with weigh-ins the profile has not seen', () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    for (final (daysAgo, kg) in [(14, 81.6), (7, 81.2), (1, 81.0)]) {
      final at = _now.subtract(Duration(days: daysAgo));
      a.server.weightRows['w$daysAgo'] = _weightRow(at, kg);
    }

    await boot(a.store);
    await settle();

    expect(a.store.weightLog.trendKg!.round(), 81, reason: 'precondition');
    expect(a.store.profile.weightKg, 81);
    expect(a.store.profile.dailyKcalGoal, 2050);
    expect(a.server.profileRow!['weight_kg'], 81);
    expect(
      a.snacks.messages,
      contains('Neues Tagesziel: 2050 kcal – an deinen Gewichtstrend angepasst.'),
    );
  }));

  test('after the boot catch-up, the next weigh-in still re-anchors', () => withClock(Clock.fixed(_now), () async {
    // Review finding: the catch-up commit made a parallel cache write (meal
    // plans) conflict; the re-hydration then closed the gate for the session
    // although it re-installed the very same rows.
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    for (final daysAgo in [3, 2, 1]) {
      final at = _now.subtract(Duration(days: daysAgo));
      a.server.weightRows['w$daysAgo'] = _weightRow(at, 80.52);
    }
    // The meal-plan read is on the wire while the catch-up commit lands.
    a.server
      ..serveMealPlans = true
      ..holdMealPlanReads();
    await boot(a.store);
    await settle();
    expect(a.store.profile.weightKg, 81, reason: 'precondition: caught up');
    a.server.releaseMealPlanReads();
    await settle();

    // 80.52 + 0.1 * (80.0 - 80.52) = 80.468 -> 80.
    await a.store.logWeight(80.0);
    await settle();

    expect(a.store.profile.weightKg, 80);
  }));

  test('no re-anchor when the profile answered but the weight log did not', () => withClock(Clock.fixed(_now), () async {
    // The log in memory is then the CACHED one; acting on it could push a
    // stale trend over another device's newer weigh-ins.
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, 'user-outbox');
    await cache.writeProfile(_live());
    await cache.writeWeightLog(
      WeightLog.capped([
        for (final daysAgo in [3, 2, 1])
          WeightLogEntry(
            timestamp: _now.subtract(Duration(days: daysAgo)),
            weightKg: 81.0,
          ),
      ]),
    );
    final a = setup(injizierterCache: cache);
    a.server.profileRow = serverProfileRow(_live());
    a.server.rejectWeightLogReads = true;

    await boot(a.store);
    await settle();

    expect(a.store.weightLog.planWeightKg(_now), 81.0, reason: 'precondition');
    expect(a.store.profile.weightKg, 84);
  }));

  test('no re-anchor before the server answered in this session', () async {
    // Review finding: the weigh-in used to write a full profile row from the
    // cached profile, which another device may have changed meanwhile.
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);
    expect(b.store.profile.weightKg, 84, reason: 'precondition: cached');

    await b.store.logWeight(81.2);
    await settle();

    expect(b.store.profile.weightKg, 84);
    expect(b.store.pendingOutbox.map((op) => op.kind), [
      SyncOpKind.weightInsert,
    ]);
  });

  test('stale weigh-ins do not re-anchor at boot', () => withClock(Clock.fixed(_now), () async {
    // The latest weigh-in is five weeks old; a weight typed on the goals
    // screen since then must not be overridden.
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    for (final (daysAgo, kg) in [(42, 80.6), (35, 80.4)]) {
      final at = _now.subtract(Duration(days: daysAgo));
      a.server.weightRows['w$daysAgo'] = _weightRow(at, kg);
    }

    await boot(a.store);
    await settle();

    expect(a.store.weightLog.trendKg, isNotNull, reason: 'precondition');
    expect(a.store.profile.weightKg, 84);
    expect(a.snacks.messages.where((m) => m.startsWith('Neues Tagesziel')),
        isEmpty);
  }));

  test('before onboarding completes, a weigh-in leaves the profile', () async {
    final store = HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Test',
      emitSnack: SnackCapture().call,
    );
    addTearDown(store.dispose);
    store.profile = const UserProfile(weightKg: 84);
    expect(store.profile.onboardingCompleted, isFalse, reason: 'precondition');

    await store.logWeight(81.2);

    expect(store.profile.weightKg, 84);
  });

  test('offline, the sync hint stays and the goal notice steps back', () async {
    // Review finding: the goal notice replaced the once-per-session "saved
    // here, syncs later" hint, which then never came back.
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    a.server.offline = true;
    a.snacks.messages.clear();

    await a.store.logWeight(81.2);
    await settle();

    expect(a.store.profile.weightKg, 81, reason: 're-anchored all the same');
    expect(a.snacks.messages, isNotEmpty, reason: 'the sync hint');
    expect(a.snacks.messages.where((m) => m.startsWith('Neues Tagesziel')),
        isEmpty);
  });

  test('a goals save in flight is not overwritten by the re-anchor', () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);

    // Both start before either commits: the weigh-in must compute from the
    // profile the goals save publishes, not from the one it saw at the call.
    final save = a.store.applySettings(
      newProfile: a.store.profile.copyWith(
        activityLevel: ActivityLevel.moderate,
      ),
      notificationsEnabled: false,
    );
    final weighIn = a.store.logWeight(81.2);
    await Future.wait([save, weighIn]);
    await settle();

    expect(a.store.profile.activityLevel, ActivityLevel.moderate);
    expect(a.store.profile.weightKg, 81);
    expect(a.server.profileRow!['activity_level'], 'moderate');
    expect(a.server.profileRow!['weight_kg'], 81);
  });
}
