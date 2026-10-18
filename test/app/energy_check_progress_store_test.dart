// The weekly check's progress in the store (docs/WEIGHT-TREND.md, stage 2):
// the same sources and gate as the proposal, and it follows weigh-ins and
// answers.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;

import '../outbox/outbox_test_helpers.dart';

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

DateTime _daysAgo(int n) => DateTime(_now.year, _now.month, _now.day - n, 12);

/// 21 days of 2100 kcal and weigh-ins on [weighInDaysAgo], losing 0.02 kg a
/// day: with all 21 the check proposes −150 (energy_check_store_test).
void _seed(FakeServer server, Iterable<int> weighInDaysAgo) {
  server.profileRow = serverProfileRow(_live);
  for (var n = 1; n <= 21; n++) {
    final at = _daysAgo(n);
    server.mealRows['meal-$n'] = <String, dynamic>{
      'id': '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      'logged_at': at.toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': localDayKey(at),
      'payload': mealResultToJson(mealResult('Essen', kcal: 2100)),
    };
  }
  for (final n in weighInDaysAgo) {
    server.weightRows['w$n'] = <String, dynamic>{
      'recorded_at': _daysAgo(n).toUtc().toIso8601String(),
      'weight_kg': 84 - 0.02 * (21 - n),
    };
  }
}

final List<int> _everyDay = [for (var n = 1; n <= 21; n++) n];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'on server data: ready exactly with a proposal, same counts',
    () => withClock(Clock.fixed(_now), () async {
      final a = setup();
      _seed(a.server, _everyDay);
      await boot(a.store);

      expect(a.store.energyCheckSourcesReady, isTrue);
      final progress = a.store.energyCheckProgress!;
      final proposal = a.store.energyCheckProposal!;
      expect(progress.ready, isTrue);
      expect(progress.loggedDays, proposal.loggedDays);
      expect(progress.weighInDays, proposal.weighInDays);
    }),
  );

  test(
    'a weigh-in moves the progress: tomorrow without a weigh-in to go',
    () => withClock(Clock.fixed(_now), () async {
      final a = setup();
      _seed(a.server, [20, 14, 1]);
      await boot(a.store);

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

  test(
    '"not now" pauses it: the progress names the day the pause ends',
    () => withClock(Clock.fixed(_now), () async {
      final a = setup();
      _seed(a.server, _everyDay);
      await boot(a.store);

      await a.store.dismissEnergyCheck();
      await settle();

      final progress = a.store.energyCheckProgress!;
      expect(progress.dataReady, isTrue);
      expect(progress.pausedUntil, DateTime(2026, 10, 10));
      expect(progress.daysUntil, 7);
      expect(a.store.energyCheckProposal, isNull);
    }),
  );

  test(
    'cached data alone: no progress, like no proposal',
    () => withClock(Clock.fixed(_now), () async {
      final kv = InMemoryKeyValueStore();
      final a = setup(kv: kv);
      _seed(a.server, _everyDay);
      await boot(a.store);
      expect(a.store.energyCheckProgress, isNotNull, reason: 'precondition');
      a.store.flushPendingWrites();
      await settle();

      final b = setup(kv: kv);
      b.server.offline = true;
      await boot(b.store);

      expect(b.store.loggedMeals, isNotEmpty, reason: 'cache hydrated');
      expect(b.store.energyCheckSourcesReady, isFalse);
      expect(b.store.energyCheckProgress, isNull);
      expect(b.store.energyCheckProposal, isNull);
    }),
  );
}
