// WeightLog.trendKg — the smoothed current weight (docs/WEIGHT-TREND.md).
//
// A time-aware exponentially weighted moving average over the LAST weigh-in
// of each local day: 10 % per day, so a day Δ days after the previous one
// moves the trend by 1 − 0.9^Δ. A day more than 5 % off the trend is an
// outlier: it counts only once the next weigh-in day confirms it.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/weight_log.dart';

WeightLogEntry _at(int day, double kg, {int hour = 7}) =>
    WeightLogEntry(timestamp: DateTime(2026, 9, 1 + day, hour), weightKg: kg);

double? _trend(List<WeightLogEntry> entries) =>
    WeightLog.capped(entries).trendKg;

void main() {
  test('no weigh-ins, no trend', () {
    expect(const WeightLog().trendKg, isNull);
  });

  test('one weigh-in is the trend', () {
    expect(_trend([_at(0, 81.2)]), 81.2);
  });

  test('the last weigh-in of a local day counts: a correction replaces it', () {
    expect(_trend([_at(0, 80, hour: 7), _at(0, 81, hour: 21)]), 81);
  });

  test('the next day moves the trend by 10 %', () {
    expect(_trend([_at(0, 80), _at(1, 81)]), closeTo(80.1, 1e-9));
  });

  test('a gap counts as that many days: a week later 1 − 0.9^7', () {
    final alpha = 1 - math.pow(0.9, 7);
    expect(_trend([_at(0, 80), _at(7, 81)]), closeTo(80 + alpha, 1e-9));
  });

  test('order of the input does not matter', () {
    final ordered = [_at(0, 80), _at(3, 80.6), _at(5, 79.8)];
    // The plain constructor does not sort; the trend must not rely on it.
    expect(
      WeightLog(entries: ordered.reversed.toList()).trendKg,
      closeTo(_trend(ordered)!, 1e-9),
    );
  });

  test('days are local calendar days, not 24 h windows', () {
    // 23:30 and 00:30 are one hour apart but two days: the second one is a
    // new day and moves the trend by 10 %, it is not averaged in.
    final late = WeightLogEntry(
      timestamp: DateTime(2026, 9, 1, 23, 30),
      weightKg: 80,
    );
    final early = WeightLogEntry(
      timestamp: DateTime(2026, 9, 2, 0, 30),
      weightKg: 81,
    );
    expect(_trend([late, early]), closeTo(80.1, 1e-9));
  });

  group('outliers (more than 5 % off the trend)', () {
    test('a single outlier followed by a normal day is ignored', () {
      // 61.2 is a typo of 81.2: the next weigh-in does not confirm it.
      expect(
        _trend([_at(0, 81.2), _at(1, 61.2), _at(2, 81.0)]),
        closeTo(81.2 + (1 - math.pow(0.9, 2)) * (81.0 - 81.2), 1e-9),
      );
    });

    test('a typo corrected the same day leaves no trace', () {
      // Review case: 90 typed, 80 corrected minutes later. A day mean of 85
      // used to reseed and then drag the trend for weeks.
      final trend = _trend([
        _at(0, 80),
        _at(1, 90, hour: 7),
        _at(1, 80, hour: 8),
        _at(2, 81),
      ]);
      expect(trend, closeTo(80 + 0.1 * 0 + 0.1 * (81 - 80), 1e-9));
    });

    test('an outlier 5–10 % off does not get stuck', () {
      // 85.5 is 6.9 % above 80; the next day is back at 80.5.
      final trend = _trend([_at(0, 80), _at(1, 85.5), _at(2, 80.5)])!;
      expect(trend, closeTo(80 + (1 - math.pow(0.9, 2)) * 0.5, 1e-9));
    });

    test('a jump confirmed by the next weigh-in day is adopted', () {
      // A real correction (wrong onboarding weight, a long break): two days
      // agree, so the trend moves to the confirming day.
      expect(_trend([_at(0, 84), _at(1, 74.2), _at(2, 74.0)]), 74.0);
    });

    test('an unconfirmed outlier on the last day does not move the trend', () {
      expect(_trend([_at(0, 80), _at(1, 80.4), _at(2, 90)]), closeTo(80.04, 1e-9));
    });

    test('just under 5 % is still smoothed', () {
      // 83.9 is 4.875 % above 80.
      expect(_trend([_at(0, 80), _at(1, 83.9)]), closeTo(80.39, 1e-9));
    });
  });

  test('a day gap across the spring DST change still counts two days', () {
    // 28 → 30 March 2026 is 47 hours in Europe/Berlin; whole days count.
    final trend = _trend([
      WeightLogEntry(timestamp: DateTime(2026, 3, 28, 7), weightKg: 80),
      WeightLogEntry(timestamp: DateTime(2026, 3, 30, 7), weightKg: 81),
    ]);
    expect(trend, closeTo(80 + (1 - math.pow(0.9, 2)), 1e-9));
  });

  group('planWeightKg: the trend the plan may use', () {
    final now = DateTime(2026, 10, 3, 12);

    test('a fresh trend inside the profile range', () {
      final log = WeightLog.capped([_at(30, 81.6)]); // 2026-10-01
      expect(log.planWeightKg(now), 81.6);
    });

    test('none when the latest weigh-in is older than 28 days', () {
      // Weigh-ins stopped in August; a newer weight typed on the goals
      // screen must not be overridden by them.
      final log = WeightLog.capped([
        WeightLogEntry(timestamp: DateTime(2026, 9, 4, 7), weightKg: 84),
      ]);
      expect(log.trendKg, 84);
      expect(log.planWeightKg(now), isNull);
      expect(
        WeightLog.capped([
          WeightLogEntry(timestamp: DateTime(2026, 9, 6, 7), weightKg: 84),
        ]).planWeightKg(now),
        84,
      );
    });

    test('none when the rounded trend leaves the profile range 30–300', () {
      final log = WeightLog.capped([_at(30, 25)]);
      expect(log.trendKg, 25);
      expect(log.planWeightKg(now), isNull);
    });

    test('none without weigh-ins', () {
      expect(const WeightLog().planWeightKg(now), isNull);
    });
  });

  test('daily water swings of ±1 kg stay smoothed', () {
    final noisy = [
      for (var d = 0; d < 28; d++) _at(d, d.isEven ? 80.0 : 82.0),
    ];
    final trend = _trend(noisy)!;
    expect(trend, greaterThan(80.5));
    expect(trend, lessThan(81.5));
  });

  test('a steady loss is followed with a lag, never overshot', () {
    // −0.5 kg/week, weighed daily: the trend trails the scale but stays
    // between the start and the latest reading.
    final losing = [
      for (var d = 0; d < 42; d++) _at(d, 84 - d * 0.5 / 7),
    ];
    final trend = _trend(losing)!;
    final latest = losing.last.weightKg;
    expect(trend, greaterThan(latest));
    expect(trend - latest, lessThan(0.7));
  });
}
