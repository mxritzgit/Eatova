// One rule for a "complete day" (2026-10-19): the weekly check, the trends
// averages, Today's day strip and the evening reminder share it.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/complete_day.dart';
import 'package:eatova/src/services/energy_check.dart';

void main() {
  test('ab der Haelfte des Ziels ist ein Tag vollstaendig', () {
    expect(completeDayShare, 0.5);
    expect(isCompleteDay(intakeKcal: 1000, goalKcal: 2000), isTrue);
    expect(isCompleteDay(intakeKcal: 999, goalKcal: 2000), isFalse);
    expect(isCompleteDay(intakeKcal: 0, goalKcal: 2000), isFalse);
    expect(isCompleteDay(intakeKcal: 3000, goalKcal: 2000), isTrue);
    // An odd goal: 1051 is half of 2101 rounded down, so not yet.
    expect(isCompleteDay(intakeKcal: 1050, goalKcal: 2101), isFalse);
    expect(isCompleteDay(intakeKcal: 1051, goalKcal: 2101), isTrue);
  });

  test('ohne Ziel setzt die Regel keine Schwelle', () {
    expect(isCompleteDay(intakeKcal: 0, goalKcal: 0), isTrue);
    expect(isCompleteDay(intakeKcal: 120, goalKcal: -1), isTrue);
  });

  test('der Wochen-Check liest dieselbe Schwelle', () {
    expect(EnergyCheck.loggedDayShare, completeDayShare);
  });
}
