// EnergyCheck.progress — how far the weekly check is from an estimate
// (docs/WEIGHT-TREND.md, stage 2), on the inputs and rules of
// EnergyCheck.evaluate: 14 logged days of 21, 4 weigh-in days over at least
// 14 days, seven days of pause after an answer.
//
// The scenarios use a strong signal (1,500 kcal on logged days, constant
// weight, against a modelled 2,650 + steps), so whenever the gates pass,
// evaluate proposes: "ready" and "a proposal" must then agree exactly.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/energy_check.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

final DateTime _today = DateTime(2026, 10, 3);

/// Male, 182 cm, light, −0.5 kg/week: goal 2100, a day counts from 1050 on.
UserProfile _profile({
  int? checkedOnOffset,
  bool manual = false,
  bool onboarded = true,
}) => const KcalCalculator().applyLiveGoals(
  UserProfile(
    weightKg: 84,
    heightCm: 182,
    ageYears: 31,
    sex: BiologicalSex.male,
    activityLevel: ActivityLevel.light,
    targetWeightKg: 70,
    weightGoal: WeightGoal.lose05kg,
    onboardingCompleted: onboarded,
    manualEnergy: manual,
    energyCheckedOn: checkedOnOffset == null
        ? null
        : addDays(_today, checkedOnOffset),
  ),
);

const int _loggedKcal = 1500;

/// Days as offsets from [_today] (−1 = yesterday, 0 = today).
class _Scenario {
  _Scenario({
    required this.logged,
    required this.weighIns,
    this.stepDays,
    this.checkedOnOffset,
    this.typos = const {},
  });

  /// Days with 1,500 kcal; every other day has 600 (under the 1,050 share).
  final Set<int> logged;
  final Set<int> weighIns;

  /// Days with a step value; null = no step source at all.
  final Set<int>? stepDays;
  final int? checkedOnOffset;

  /// Weigh-in days at 64 kg instead of 84: typos the check drops.
  final Set<int> typos;

  int _offset(DateTime day) => daysBetween(day, _today);

  int intake(DateTime day) => logged.contains(_offset(day)) ? _loggedKcal : 600;

  int? burned(DateTime day) {
    final steps = stepDays;
    if (steps == null) return null;
    return steps.contains(_offset(day)) ? 200 : null;
  }

  WeightLog get log => WeightLog.capped([
    for (final n in weighIns)
      WeightLogEntry(
        timestamp: addDays(_today, n).add(const Duration(hours: 7)),
        weightKg: typos.contains(n) ? 64 : 84,
      ),
  ]);

  EnergyCheckProgress? progress({int on = 0, UserProfile? profile}) =>
      const EnergyCheck().progress(
        profile: profile ?? _profile(checkedOnOffset: checkedOnOffset),
        today: addDays(_today, on),
        intakeKcal: intake,
        burnedKcal: burned,
        weightLog: log,
      );

  EnergyCheckProposal? evaluate({int on = 0, UserProfile? profile}) =>
      const EnergyCheck().evaluate(
        profile: profile ?? _profile(checkedOnOffset: checkedOnOffset),
        today: addDays(_today, on),
        intakeKcal: intake,
        burnedKcal: burned,
        weightLog: log,
      );

  /// This scenario continued: [moreLogged] and [moreWeighIns] added (with a
  /// step value where a step source exists).
  _Scenario plus({
    Set<int> moreLogged = const {},
    Set<int> moreWeighIns = const {},
  }) => _Scenario(
    logged: {...logged, ...moreLogged},
    weighIns: {...weighIns, ...moreWeighIns},
    stepDays: stepDays == null ? null : {...stepDays!, ...moreLogged},
    checkedOnOffset: checkedOnOffset,
    typos: typos,
  );
}

Set<int> _range(int from, int to) => {for (var n = from; n <= to; n++) n};

/// Yesterday and the 20 days before it.
final Set<int> _fullWindow = _range(-21, -1);

/// Independent oracle for the data gates of the window of day [on], written
/// from the rules: no typos, so every weigh-in day counts; with a step value
/// in the window, only days with one count.
bool _oracleReady(int on, _Scenario s, [Set<int> extraWeighIns = const {}]) {
  bool inWindow(int n) => n >= on - 21 && n <= on - 1;
  final steps = s.stepDays;
  final withSteps = steps != null && steps.any(inWindow);
  final days = s.logged
      .where((n) => inWindow(n) && (!withSteps || steps.contains(n)))
      .length;
  final weighed = {...s.weighIns, ...extraWeighIns}.where(inWindow).toList()
    ..sort();
  return days >= 14 &&
      weighed.length >= 4 &&
      weighed.last - weighed.first >= 14;
}

/// All subsets of [items] with at most [size] elements.
Iterable<Set<int>> _subsets(List<int> items, int size, [int start = 0]) sync* {
  yield <int>{};
  if (size <= 0) return;
  for (var i = start; i < items.length; i++) {
    for (final rest in _subsets(items, size - 1, i + 1)) {
      yield {items[i], ...rest};
    }
  }
}

void main() {
  test('nothing yet: 15 days, 14 logged days and 4 weigh-ins to go', () {
    final p = _Scenario(logged: {}, weighIns: {}).progress()!;
    expect(p.loggedDays, 0);
    expect(p.weighInDays, 0);
    expect(p.weighInSpanDays, 0);
    expect(p.missingLoggedDays, 14);
    expect(p.missingWeighInDays, 4);
    expect(p.spanReached, isFalse);
    expect(p.ready, isFalse);
    // Today and the 14 days after it: weigh today and on day 14.
    expect(p.daysUntil, 15);
    expect(p.earliestDay, DateTime(2026, 10, 18));
    expect(p.loggedDaysToGo, 14);
    expect(p.weighInsToGo, 4);
  });

  test('a full window is ready today, and evaluate estimates', () {
    final s = _Scenario(logged: _fullWindow, weighIns: _fullWindow);
    final p = s.progress()!;
    expect(p.ready, isTrue);
    expect(p.daysUntil, 0);
    expect(p.earliestDay, _today);
    expect(p.loggedDaysToGo, 0);
    expect(p.weighInsToGo, 0);
    final proposal = s.evaluate()!;
    expect(proposal.loggedDays, p.loggedDays);
    expect(proposal.weighInDays, p.weighInDays);
  });

  test('does not apply in manual mode or before the onboarding', () {
    final s = _Scenario(logged: _fullWindow, weighIns: _fullWindow);
    expect(s.progress(profile: _profile(manual: true)), isNull);
    expect(s.progress(profile: _profile(onboarded: false)), isNull);
  });

  group('the thresholds, against evaluate', () {
    // Still all in tomorrow's window.
    final weighIns = {-20, -14, -7, -1};

    test('13 logged days: not ready, one more day tomorrow; 14: ready', () {
      final thirteen = _Scenario(logged: _range(-13, -1), weighIns: weighIns);
      final p = thirteen.progress()!;
      expect(p.loggedDays, 13);
      expect(p.missingLoggedDays, 1);
      expect(p.ready, isFalse);
      expect(thirteen.evaluate(), isNull);
      expect(p.daysUntil, 1);
      expect(p.loggedDaysToGo, 1, reason: 'today');
      expect(p.weighInsToGo, 0);

      // Today already counts: tomorrow's window holds it.
      final loggedToday = thirteen.plus(moreLogged: {0}).progress()!;
      expect(loggedToday.daysUntil, 1);
      expect(loggedToday.loggedDaysToGo, 0);

      final fourteen = _Scenario(logged: _range(-14, -1), weighIns: weighIns);
      expect(fourteen.progress()!.ready, isTrue);
      expect(fourteen.evaluate(), isNotNull);
    });

    test('3 weigh-in days: weigh today for tomorrow; 4: ready', () {
      final three = _Scenario(logged: _fullWindow, weighIns: {-20, -14, -1});
      final p = three.progress()!;
      expect(p.weighInDays, 3);
      expect(p.missingWeighInDays, 1);
      expect(p.spanReached, isTrue);
      expect(p.ready, isFalse);
      expect(three.evaluate(), isNull);
      expect(p.daysUntil, 1);
      expect(p.weighInsToGo, 1);
      expect(p.loggedDaysToGo, 0);

      final four = _Scenario(logged: _fullWindow, weighIns: weighIns);
      expect(four.progress()!.ready, isTrue);
      expect(four.evaluate(), isNotNull);
    });

    test('a 13-day span: not ready, one late weigh-in; 14 days: ready', () {
      final short = _Scenario(
        logged: _fullWindow,
        weighIns: {-14, -10, -6, -1},
      );
      final p = short.progress()!;
      expect(p.weighInDays, 4);
      expect(p.weighInSpanDays, 13);
      expect(p.spanReached, isFalse);
      expect(p.ready, isFalse);
      expect(short.evaluate(), isNull);
      // Weighing today stretches the span to 14 for tomorrow.
      expect(p.daysUntil, 1);
      expect(p.weighInsToGo, 1);

      final wide = _Scenario(logged: _fullWindow, weighIns: {-15, -10, -6, -1});
      expect(wide.progress()!.weighInSpanDays, 14);
      expect(wide.progress()!.ready, isTrue);
      expect(wide.evaluate(), isNotNull);
    });

    test('a span reachable only later names that day', () {
      // Four weigh-ins within the last five days: the span needs a weigh-in
      // 14 days after the first one, on day 9, so the check comes on day 10.
      // Its window keeps 11 of the logged days; 3 of the next 10 must follow.
      final p = _Scenario(
        logged: _fullWindow,
        weighIns: {-5, -3, -2, -1},
      ).progress()!;
      expect(p.daysUntil, 10);
      expect(p.weighInsToGo, 1);
      expect(p.loggedDaysToGo, 3);
    });

    test('a weigh-in that drops out of the window is replaced', () {
      // Tomorrow's window loses day −21: weighing today and tomorrow brings
      // the count back to 4 and the span to 14 on the day after.
      final p = _Scenario(
        logged: _fullWindow,
        weighIns: {-21, -14, -1},
      ).progress()!;
      expect(p.daysUntil, 2);
      expect(p.weighInsToGo, 2);
    });

    test(
      'the pause after an answer: 6 days ago waits, 7 days ago is ready',
      () {
        final paused = _Scenario(
          logged: _fullWindow,
          weighIns: _fullWindow,
          checkedOnOffset: -6,
        );
        final p = paused.progress()!;
        expect(p.dataReady, isTrue);
        expect(p.pausedUntil, DateTime(2026, 10, 4));
        expect(p.ready, isFalse);
        expect(paused.evaluate(), isNull);
        expect(p.daysUntil, 1);
        expect(p.loggedDaysToGo, 0);
        expect(p.weighInsToGo, 0);

        final over = _Scenario(
          logged: _fullWindow,
          weighIns: _fullWindow,
          checkedOnOffset: -7,
        );
        expect(over.progress()!.pausedUntil, isNull);
        expect(over.progress()!.ready, isTrue);
        expect(over.evaluate(), isNotNull);
      },
    );

    test('with a step source, days without a step value do not count', () {
      // A new phone eight days ago: those days never count, so only a
      // window of 14 new days gets there.
      final s = _Scenario(
        logged: _fullWindow,
        weighIns: weighIns,
        stepDays: _range(-21, -9),
      );
      final p = s.progress()!;
      expect(p.loggedDays, 13);
      expect(p.ready, isFalse);
      expect(s.evaluate(), isNull);
      expect(p.daysUntil, 14);
      expect(p.loggedDaysToGo, 14);
      expect(p.weighInsToGo, 2);
    });

    test('a weigh-in typo is not counted, as in evaluate', () {
      final s = _Scenario(
        logged: _fullWindow,
        weighIns: {-21, -14, -7, -1},
        typos: {-7},
      );
      final p = s.progress()!;
      expect(p.weighInDays, 3);
      expect(p.ready, isFalse);
      expect(s.evaluate(), isNull);
    });
  });

  group('random windows', () {
    // Deterministic: the same 400 windows on every run.
    final random = math.Random(20261018);
    _Scenario next({bool allowTypos = true}) {
      Set<int> pick(double share) => {
        for (var n = -22; n <= 0; n++)
          if (random.nextDouble() < share) n,
      };
      final steps = random.nextInt(3) == 0 ? pick(0.85) : null;
      final weighIns = pick(random.nextDouble() * 0.4);
      return _Scenario(
        logged: pick(0.3 + random.nextDouble() * 0.7),
        weighIns: weighIns,
        stepDays: steps,
        checkedOnOffset: random.nextInt(3) == 0 ? -random.nextInt(10) : null,
        typos: allowTypos && weighIns.isNotEmpty && random.nextInt(5) == 0
            ? {weighIns.first}
            : const {},
      );
    }

    test('ready exactly when evaluate proposes, with the same counts', () {
      var ready = 0;
      for (var i = 0; i < 400; i++) {
        final s = next();
        final p = s.progress()!;
        final proposal = s.evaluate();
        expect(proposal != null, p.ready, reason: 'window $i');
        if (proposal != null) {
          ready++;
          expect(proposal.loggedDays, p.loggedDays);
          expect(proposal.weighInDays, p.weighInDays);
        }
        expect(p.daysUntil == 0, p.ready, reason: 'window $i');
        expect(p.daysUntil, inInclusiveRange(0, 15), reason: 'window $i');
      }
      // Both outcomes occur often enough to mean something.
      expect(ready, inInclusiveRange(40, 360));
    });

    test('the earliest day is reachable as planned and none is earlier', () {
      var checked = 0;
      for (var i = 0; i < 200; i++) {
        final s = next(allowTypos: false);
        final p = s.progress()!;
        if (p.ready) continue;
        checked++;
        final k = p.daysUntil;
        final pause = p.pausedUntil == null
            ? 1
            : math.max(1, daysBetween(p.pausedUntil!, _today));
        final weighedToday = s.weighIns.contains(0);

        // Days still open from today to the day before [on].
        List<int> openDays(int on) => [
          for (var n = math.max(0, on - 21); n <= on - 1; n++) n,
        ];
        List<int> free(int on) =>
            openDays(on).where((n) => !(n == 0 && weighedToday)).toList();
        bool hasWeighIns(int on) =>
            s.weighIns.any((n) => n >= on - 21 && n <= on - 1);

        // Reachable: log every open day, weigh in on the planned days.
        final logAll = openDays(k).toSet();
        final days = free(k);
        final planned = <int>{
          if (!hasWeighIns(k) && p.weighInsToGo > 0) days.first,
        };
        for (final n in days.reversed) {
          if (planned.length >= p.weighInsToGo) break;
          planned.add(n);
        }
        expect(planned, hasLength(p.weighInsToGo), reason: 'window $i');
        final continued = s.plus(moreLogged: logAll, moreWeighIns: planned);
        expect(
          _oracleReady(k, continued),
          isTrue,
          reason: 'window $i reaches day $k',
        );
        expect(continued.progress(on: k)!.ready, isTrue, reason: 'window $i');
        expect(continued.evaluate(on: k), isNotNull, reason: 'window $i');

        // Logged days that still count on day k, today included.
        final steps = s.stepDays;
        final kept = s.logged
            .where(
              (n) =>
                  n >= k - 21 && n <= 0 && (steps == null || steps.contains(n)),
            )
            .length;
        expect(p.loggedDaysToGo, math.max(0, 14 - kept), reason: 'window $i');

        // Fewer new weigh-ins do not reach day k.
        if (p.weighInsToGo > 0) {
          final loggedAll = s.plus(moreLogged: logAll);
          for (final fewer in _subsets(days, p.weighInsToGo - 1)) {
            expect(
              _oracleReady(k, loggedAll, fewer),
              isFalse,
              reason: 'window $i: day $k with fewer weigh-ins $fewer',
            );
          }
        }

        // No earlier day after the pause, however the open days are used:
        // four new weigh-ins are always enough if any number is.
        for (var on = pause; on < k; on++) {
          final loggedAll = s.plus(moreLogged: openDays(on).toSet());
          for (final extra in _subsets(free(on), 4)) {
            expect(
              _oracleReady(on, loggedAll, extra),
              isFalse,
              reason: 'window $i: day $on with $extra beats day $k',
            );
          }
        }
      }
      expect(checked, greaterThan(50));
    });
  });
}
