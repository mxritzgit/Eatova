// The weekly energy check in the store (docs/WEIGHT-TREND.md, stage 2):
// today's proposal and progress from server-answered data, the two answers,
// and the week's result without a proposal (2026-10-19): once a week
// (EnergyCheck.resultWeekday) Today gets the check's own numbers.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/energy_check.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart'
    show MealsSync, mealResultToJson;

import 'outbox/outbox_test_helpers.dart';

/// Noon on 3 October; the window is 12 September .. 2 October.
final DateTime _now = DateTime(2026, 10, 3, 12);

/// Male, 182 cm, light, −0.5 kg/week: maintenance 2650, goal 2100 kcal.
final UserProfile _live = const KcalCalculator().applyLiveGoals(
  const UserProfile(
    weightKg: 84,
    heightCm: 182,
    ageYears: 31,
    sex: BiologicalSex.male,
    activityLevel: ActivityLevel.light,
    targetWeightKg: 70,
    weightGoal: WeightGoal.lose05kg,
    diet: DietPreference.none,
    onboardingCompleted: true,
  ),
);

DateTime _daysAgo(int n, {DateTime? now}) {
  final t = now ?? _now;
  return DateTime(t.year, t.month, t.day - n, 12);
}

Map<String, dynamic> _meal(String id, DateTime at, int kcal) =>
    <String, dynamic>{
      'id': id,
      'logged_at': at.toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': localDayKey(at),
      'payload': mealResultToJson(mealResult('Essen', kcal: kcal)),
    };

/// 21 days of [kcal] before [now] and weigh-ins on [weighInDaysAgo] (every
/// day by default) moving [kgPerDay]. The defaults have no step source, so
/// the model has no steps: observed 2254 against 2650 is −396, beyond the
/// ≈277 noise guard -> −150.
void _seedThreeWeeks(
  FakeServer server, {
  DateTime? now,
  int kcal = 2100,
  double kgPerDay = -0.02,
  Iterable<int>? weighInDaysAgo,
}) {
  server.profileRow = serverProfileRow(_live);
  for (var n = 1; n <= 21; n++) {
    server.mealRows['meal-$n'] = _meal(
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      _daysAgo(n, now: now),
      kcal,
    );
  }
  for (final n in weighInDaysAgo ?? [for (var n = 1; n <= 21; n++) n]) {
    server.weightRows['w$n'] = <String, dynamic>{
      'recorded_at': _daysAgo(n, now: now).toUtc().toIso8601String(),
      'weight_kg': 84 + kgPerDay * (21 - n),
    };
  }
}

Future<({HomeStore store, FakeServer server, SnackCapture snacks})> _booted({
  void Function(FakeServer server)? tweak,
  InMemoryKeyValueStore? kv,
  DateTime? now,
  int kcal = 2100,
  double kgPerDay = -0.02,
  Iterable<int>? weighInDaysAgo,
}) async {
  final a = setup(kv: kv);
  _seedThreeWeeks(
    a.server,
    now: now,
    kcal: kcal,
    kgPerDay: kgPerDay,
    weighInDaysAgo: weighInDaysAgo,
  );
  tweak?.call(a.server);
  await boot(a.store);
  await settle();
  return (store: a.store, server: a.server, snacks: a.snacks);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('three weeks of server data propose −150 kcal, progress ready', () => withClock(
    Clock.fixed(_now),
    () async {
      final a = await _booted();
      expect(a.store.energyCheckStepsReady, isTrue);
      expect(a.store.energyCheckSourcesReady, isTrue);
      final p = a.store.energyCheckProposal!;
      expect(p.stepKcal, -150);
      expect(p.currentGoalKcal, 2100);
      expect(p.newGoalKcal, 1950);
      expect(p.loggedDays, 21);
      expect(p.weighInDays, 21);
      // Ready exactly with a proposal, on the same counts.
      final progress = a.store.energyCheckProgress!;
      expect(progress.ready, isTrue);
      expect(progress.loggedDays, p.loggedDays);
      expect(progress.weighInDays, p.weighInDays);
    },
  ));

  test(
    'a weigh-in moves the progress: tomorrow without a weigh-in to go',
    () => withClock(Clock.fixed(_now), () async {
      final a = await _booted(weighInDaysAgo: [20, 14, 1]);

      final before = a.store.energyCheckProgress!;
      expect(before.weighInDays, 3);
      expect(before.ready, isFalse);
      expect(before.daysUntil, 1);
      expect(before.weighInsToGo, 1);
      expect(a.store.energyCheckProposal, isNull);

      await a.store.logWeight(83.6);
      await settle();

      final after = a.store.energyCheckProgress!;
      expect(after.weighInsToGo, 0);
      expect(after.daysUntil, 1, reason: "today's window ends yesterday");
      expect(after.weighInDays, 3);
    }),
  );

  test('adjust: offset, answered day and live goal, synced, with a notice',
      () => withClock(Clock.fixed(_now), () async {
    final a = await _booted();
    a.snacks.messages.clear();

    await a.store.acceptEnergyCheck(a.store.energyCheckProposal!);
    await settle();

    final profile = a.store.profile;
    expect(profile.energyAdjustmentKcal, -150);
    expect(profile.energyCheckedOn, DateTime(2026, 10, 3));
    expect(profile.dailyKcalGoal, 1950);
    expect(a.server.profileRow!['energy_adjustment_kcal'], -150);
    expect(a.server.profileRow!['energy_checked_on'], '2026-10-03');
    expect(a.server.profileRow!['daily_kcal_goal'], 1950);
    expect(a.snacks.messages, contains('Tagesziel angepasst: 1950 kcal.'));
    expect(a.store.energyCheckProposal, isNull, reason: 'answered today');
  }));

  test('the step is relative: another device moved the offset meanwhile',
      () => withClock(Clock.fixed(_now), () async {
    final a = await _booted();
    final proposal = a.store.energyCheckProposal!;
    // The card was built; then a change from elsewhere moves the offset.
    await a.store.applySettings(
      newProfile: const KcalCalculator().applyLiveGoals(
        a.store.profile.copyWith(energyAdjustmentKcal: -50),
      ),
      notificationsEnabled: false,
    );

    await a.store.acceptEnergyCheck(proposal);
    await settle();

    expect(a.store.profile.energyAdjustmentKcal, -200);
  }));

  test('not now: records the day only, the goal stays, the pause shows', () => withClock(
    Clock.fixed(_now),
    () async {
      final a = await _booted();
      a.snacks.messages.clear();

      await a.store.dismissEnergyCheck();
      await settle();

      final profile = a.store.profile;
      expect(profile.energyAdjustmentKcal, 0);
      expect(profile.energyCheckedOn, DateTime(2026, 10, 3));
      expect(profile.dailyKcalGoal, 2100);
      expect(a.server.profileRow!['energy_checked_on'], '2026-10-03');
      expect(a.snacks.messages, isEmpty);
      expect(a.store.energyCheckProposal, isNull);
      // The progress names the day the pause ends.
      final progress = a.store.energyCheckProgress!;
      expect(progress.dataReady, isTrue);
      expect(progress.pausedUntil, DateTime(2026, 10, 10));
      expect(progress.daysUntil, 7);
    },
  ));

  test('offline, the sync hint stays and the confirmation steps back',
      () => withClock(Clock.fixed(_now), () async {
    final a = await _booted();
    a.server.offline = true;
    a.snacks.messages.clear();

    await a.store.acceptEnergyCheck(a.store.energyCheckProposal!);
    await settle();

    expect(a.store.profile.dailyKcalGoal, 1950);
    expect(a.snacks.messages, isNotEmpty, reason: 'the sync hint');
    expect(
      a.snacks.messages.where((m) => m.startsWith('Tagesziel angepasst')),
      isEmpty,
    );
  }));

  group('no proposal without complete server data', () {
    test('cached data alone: no proposal and no progress', () => withClock(Clock.fixed(_now), () async {
      final kv = InMemoryKeyValueStore();
      final a = await _booted(kv: kv);
      expect(a.store.energyCheckProposal, isNotNull, reason: 'precondition');
      a.store.flushPendingWrites();
      await settle();

      final b = setup(kv: kv);
      b.server.offline = true;
      await boot(b.store);
      await settle();

      expect(b.store.loggedMeals, isNotEmpty, reason: 'cache hydrated');
      expect(b.store.energyCheckSourcesReady, isFalse);
      expect(b.store.energyCheckProgress, isNull);
      expect(b.store.energyCheckProposal, isNull);
    }));

    test('the meal load failed while profile and weights answered',
        () => withClock(Clock.fixed(_now), () async {
      // The cache holds the same three weeks, so the numbers WOULD propose;
      // only the unanswered meal load must keep the check quiet.
      final kv = InMemoryKeyValueStore();
      await LocalCache(kv, 'user-outbox').writeLoggedMeals([
        for (var n = 1; n <= 21; n++)
          LoggedMeal(
            id: '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
            result: mealResult('Essen', kcal: 2100),
            loggedAt: _daysAgo(n),
          ),
      ]);
      final a = await _booted(
        kv: kv,
        tweak: (server) => server.rejectMealReads = true,
      );
      expect(a.store.loggedMeals, hasLength(21), reason: 'cached meals');
      expect(a.store.weightLog.entries, hasLength(21), reason: 'precondition');
      expect(a.store.energyCheckProposal, isNull);
    }));

    test('the meal window hit its row cap', () => withClock(
      Clock.fixed(_now),
      () async {
        final a = await _booted(
          tweak: (server) {
            // 1000 rows inside the 35-day window: older days may be cut. At
            // 1 kcal each they leave the numbers proposing (≈ −350 kcal).
            for (var i = 0; i < MealsSync.loggedMealsMaxRows; i++) {
              server.mealRows['cap-$i'] = _meal(
                '10000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
                _daysAgo(1 + i % 21),
                1,
              );
            }
          },
        );
        expect(a.store.energyCheckProposal, isNull);
      },
    ));
  });

  group('the week\'s result without a proposal', () {
    /// Monday 5 October 2026, noon.
    final monday = DateTime(2026, 10, 5, 12);

    test('Montag ohne Vorschlag: das Ergebnis mit den Zahlen des Checks', () {
      return withClock(Clock.fixed(monday), () async {
        expect(monday.weekday, EnergyCheck.resultWeekday);
        // 2700 kcal at a steady weight: observed 2700 against 2650 modelled.
        final store =
            (await _booted(now: monday, kcal: 2700, kgPerDay: 0)).store;
        expect(store.energyCheckProposal, isNull);
        final result = store.energyCheckResult!;
        expect(result.proposal, isNull);
        expect(result.withinNoise, isTrue);
        expect(result.observedKcal, closeTo(2700, 0.5));
        expect(result.modelledKcal, 2650);
        expect(result.currentGoalKcal, 2100);
        expect(result.weeklyRateKg, closeTo(0, 1e-9));
        expect(
          result.planWeeklyRateKg,
          const KcalCalculator().calculate(_live).effectiveWeeklyRateKg,
        );
        expect(result.loggedDays, 21);
        expect(result.weighInDays, 21);
      });
    });

    test('an einem anderen Tag bleibt es bei der Zeile', () {
      final tuesday = DateTime(2026, 10, 6, 12);
      return withClock(Clock.fixed(tuesday), () async {
        final store =
            (await _booted(now: tuesday, kcal: 2700, kgPerDay: 0)).store;
        expect(store.energyCheckResult, isNull);
        expect(store.energyCheckProgress!.ready, isTrue);
      });
    });

    test('Verstanden blendet es bis zum naechsten Montag aus, auch nach '
        'einem Neustart', () async {
      final kv = InMemoryKeyValueStore();
      await withClock(Clock.fixed(monday), () async {
        final store =
            (await _booted(kv: kv, now: monday, kcal: 2700, kgPerDay: 0)).store;
        expect(store.energyCheckResult, isNotNull, reason: 'precondition');
        await store.acknowledgeEnergyCheckResult();
        expect(store.energyCheckResult, isNull);

        final restarted =
            (await _booted(kv: kv, now: monday, kcal: 2700, kgPerDay: 0)).store;
        expect(restarted.energyCheckResult, isNull);
      });
      final nextMonday = DateTime(2026, 10, 12, 12);
      await withClock(Clock.fixed(nextMonday), () async {
        final store = (await _booted(
          kv: kv,
          now: nextMonday,
          kcal: 2700,
          kgPerDay: 0,
        )).store;
        expect(store.energyCheckResult, isNotNull);
      });
    });

    test('ein Vorschlag geht dem Ergebnis vor', () {
      return withClock(Clock.fixed(monday), () async {
        final store = (await _booted(now: monday)).store;
        expect(store.energyCheckProposal!.stepKcal, -150);
        expect(store.energyCheckResult, isNull);
      });
    });
  });
}
