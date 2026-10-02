// WeightLog.trendKg — the smoothed current weight (docs/WEIGHT-TREND.md).
//
// A time-aware exponentially weighted moving average over per-day means:
// 10 % per day, so a day Δ days after the previous one moves the trend by
// 1 − 0.9^Δ; a day more than 5 % off the trend reseeds it.

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

  test('several weigh-ins on one local day count as their mean', () {
    expect(
      _trend([_at(0, 80, hour: 7), _at(0, 81, hour: 21)]),
      closeTo(80.5, 1e-9),
    );
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

  group('reseed', () {
    test('a day more than 5 % off the trend replaces it', () {
      // 85 is 6.25 % above 80: a correction or a typo, not water.
      expect(_trend([_at(0, 80), _at(1, 85)]), 85);
    });

    test('just under 5 % is still smoothed', () {
      // 83.9 is 4.875 % above 80.
      expect(_trend([_at(0, 80), _at(1, 83.9)]), closeTo(80.39, 1e-9));
    });

    test('a typo is undone by the next real weigh-in', () {
      final trend = _trend([_at(0, 81.2), _at(1, 61.2), _at(2, 81.0)]);
      expect(trend, 81.0);
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
