// TrendReport (2026-10-18): the pure maths behind the trends page. Every
// average leaves today out (B6), a week bar averages its measured completed
// days, steps count a measured 0, weight takes each day's last weigh-in, and
// the local overlay replaces whole server days (TRN-9).

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/energy_check.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/trend_report.dart';
import 'package:eatova/src/services/trend_service.dart';

/// A Sunday evening, far from DST edges.
final DateTime _today = DateTime(2026, 10, 18, 20);

DateTime _day(int back) => DateTime(2026, 10, 18 - back);

TrendDayTotals _totals(int back, int kcal, {double protein = 100}) =>
    TrendDayTotals(
      day: _day(back),
      kcal: kcal,
      proteinG: protein,
      carbsG: 200,
      fatG: 60,
    );

TrendReport _build(
  TrendRange range, {
  List<TrendDayTotals> totals = const <TrendDayTotals>[],
  TrendGoals goals = const TrendGoals(kcal: 2000),
  Map<String, int> steps = const <String, int>{},
  int? stepsToday,
  List<WeightLogEntry> weighIns = const <WeightLogEntry>[],
  List<DateTime> workouts = const <DateTime>[],
}) => TrendReport.build(
  range: range,
  today: _today,
  totals: totals,
  goals: goals,
  stepsByDay: steps,
  stepsToday: stepsToday,
  weighIns: weighIns,
  workoutsFinishedAt: workouts,
);

void main() {
  group('TrendRange', () {
    test('vier Zeitraeume, Wochenbalken ab 90 Tagen', () {
      expect([for (final r in TrendRange.values) r.days], [7, 30, 90, 182]);
      expect(TrendRange.week.weekly, isFalse);
      expect(TrendRange.month.weekly, isFalse);
      expect(TrendRange.quarter.weekly, isTrue);
      expect(TrendRange.halfYear.weekly, isTrue);
      expect(TrendRange.ofDays(182), TrendRange.halfYear);
      expect(TrendRange.ofDays(12), TrendRange.month);
    });
  });

  group('Kalorien und Makros', () {
    test(
      'der laufende Tag zaehlt in keinem Schnitt, steht aber im Fenster',
      () {
        final report = _build(
          TrendRange.week,
          totals: [
            // Complete by the half-goal rule, so only B6 keeps it out.
            _totals(0, 1500, protein: 10),
            _totals(1, 2000, protein: 150),
            _totals(2, 2400, protein: 90),
          ],
          goals: const TrendGoals(kcal: 2000, proteinG: 120),
        );
        expect(report.window, hasLength(7));
        expect(report.window.last!.kcal, 1500);
        expect(report.firstDay, _day(6));
        expect(report.avgKcal, 2200);
        expect(report.loggedDays, 2);
        expect(report.completedDays, 6);
        expect(report.hits, (hit: 1, tracked: 2));
        expect(report.macros!.proteinG, 120);
        expect(report.proteinGoalDays, 1);
      },
    );

    // A day below the goal with unknown protein may have reached it; a day
    // at the goal reached it whatever the unknown entries held.
    test('Tage mit unbekanntem Protein zaehlen nicht als verfehlt', () {
      TrendDayTotals day(int back, double protein, int missing) =>
          TrendDayTotals(
            day: _day(back),
            kcal: 2000,
            proteinG: protein,
            carbsG: 200,
            fatG: 60,
            proteinMissing: missing,
          );
      final report = _build(
        TrendRange.week,
        totals: [day(1, 130, 1), day(2, 60, 2), day(3, 60, 0)],
        goals: const TrendGoals(kcal: 2000, proteinG: 120),
      );
      expect(report.proteinGoalDays, 1);
      expect(report.proteinUnknownDays, 1);
    });

    test('ohne Proteinziel gibt es keine Zieltage', () {
      final report = _build(
        TrendRange.week,
        totals: [_totals(1, 2000, protein: 500)],
      );
      expect(report.proteinGoalDays, 0);
    });

    test('Tagesbalken bis 30 Tage, mit Ziel plus Schrittbonus je Tag', () {
      final report = _build(
        TrendRange.month,
        totals: [_totals(3, 1800)],
        goals: TrendGoals(
          kcal: 2000,
          burnedKcalFor: (day) => day == _day(3) ? 150 : 0,
        ),
      );
      expect(report.kcalBars, hasLength(30));
      final bar = report.kcalBars[26];
      expect(bar.start, _day(3));
      expect(bar.days, 1);
      expect(bar.value, 1800);
      expect(bar.goal, 2150);
      expect(report.kcalBars.last.start, _day(0));
    });
  });

  // 2026-10-19: one rule for a complete day, the weekly check's: a logged
  // day below half the base goal leaves every average and is counted.
  group('Vollstaendige Tage', () {
    test('ein halber Tag faellt aus allen Schnitten und wird gezaehlt', () {
      final report = _build(
        TrendRange.week,
        totals: [
          _totals(0, 300, protein: 10),
          _totals(1, 2000, protein: 150),
          _totals(2, 2400, protein: 90),
          _totals(3, 999, protein: 200),
          _totals(4, 400, protein: 130),
        ],
        goals: const TrendGoals(kcal: 2000, proteinG: 120),
      );
      // Over every logged day it was (2000 + 2400 + 999 + 400) / 4.
      expect(report.avgKcal, 2200);
      expect(report.loggedDays, 4);
      expect(report.fullDays, 2);
      expect(report.partialDays, 2);
      expect(report.hits, (hit: 1, tracked: 2));
      expect(report.macros!.proteinG, 120);
      expect(report.proteinGoalDays, 1);
      // The chart keeps them, faded; today is never marked.
      expect(
        [for (final bar in report.kcalBars) bar.partial],
        [false, false, true, true, false, false, false],
      );
      expect(report.kcalBars[2].value, 400);
    });

    test('genau die Haelfte des Ziels ist vollstaendig', () {
      final report = _build(TrendRange.week, totals: [_totals(1, 1000)]);
      expect(report.fullDays, 1);
      expect(report.partialDays, 0);
      expect(report.avgKcal, 1000);
    });

    test('ohne Ziel zaehlt jeder erfasste Tag', () {
      final report = _build(
        TrendRange.week,
        totals: [_totals(1, 100), _totals(2, 300)],
        goals: const TrendGoals(kcal: 0),
      );
      expect(report.fullDays, 2);
      expect(report.avgKcal, 200);
    });

    test('eine Woche mittelt nur ihre vollstaendigen Tage', () {
      final report = _build(
        TrendRange.halfYear,
        totals: [_totals(1, 2000), _totals(2, 400), _totals(8, 300)],
      );
      expect(report.kcalBars.last.value, 2000);
      // A week of half-logged days only has no average to show.
      expect(report.kcalBars[24].value, isNull);
      expect(report.kcalBars.any((bar) => bar.partial), isFalse);
    });
  });

  group('Wochenbalken', () {
    test('sechs Monate: 26 volle Wochen, die letzte endet heute', () {
      final report = _build(TrendRange.halfYear);
      expect(report.kcalBars, hasLength(26));
      expect(report.kcalBars.every((bar) => bar.days == 7), isTrue);
      expect(report.kcalBars.first.start, report.firstDay);
      expect(report.kcalBars.last.start, _day(6));
    });

    test('90 Tage: die aelteste Woche ist kuerzer', () {
      final report = _build(TrendRange.quarter);
      expect(report.kcalBars, hasLength(13));
      expect(report.kcalBars.first.days, 6);
      expect(report.kcalBars.skip(1).every((bar) => bar.days == 7), isTrue);
    });

    test('eine Woche mittelt ihre erfassten abgeschlossenen Tage', () {
      final report = _build(
        TrendRange.halfYear,
        totals: [
          // Today, though complete by the half-goal rule, stays out of its
          // week's average.
          _totals(0, 1800),
          _totals(1, 2000),
          _totals(2, 2400),
          // Day 7 belongs to the week before.
          _totals(7, 1000),
        ],
        goals: TrendGoals(
          kcal: 2000,
          burnedKcalFor: (day) => day == _day(1) ? 700 : 0,
        ),
      );
      final last = report.kcalBars.last;
      expect(last.value, 2200);
      // The goal averages all seven days of the week: 2000 + 700 / 7.
      expect(last.goal, 2100);
      expect(report.kcalBars[24].value, 1000);
      expect(report.kcalBars[23].value, isNull);
    });

    test('eine Woche nur mit heute bleibt leer', () {
      final report = _build(TrendRange.halfYear, totals: [_totals(0, 1800)]);
      expect(report.kcalBars.last.value, isNull);
    });
  });

  group('Schritte', () {
    test('Schnitt ohne heute, gemessene 0 zaehlt, Bestwert und Zieltage', () {
      final report = _build(
        TrendRange.week,
        steps: {
          localDayKey(_day(1)): 12000,
          localDayKey(_day(2)): 0,
          localDayKey(_day(3)): 9000,
          // Outside the window.
          localDayKey(_day(9)): 30000,
        },
        stepsToday: 40000,
        goals: const TrendGoals(kcal: 2000, stepsPerDay: 8000),
      );
      expect(report.avgSteps, 7000);
      expect(report.stepDays, 3);
      expect(report.bestStepDay, (day: _day(1), steps: 12000));
      expect(report.stepGoalDays, 2);
      // The chart shows today's live value.
      expect(report.stepBars.last.value, 40000);
      expect(report.stepBars.last.goal, 8000);
    });

    test('ohne Werte kein Schnitt und kein Bestwert', () {
      final report = _build(TrendRange.month, stepsToday: 500);
      expect(report.avgSteps, isNull);
      expect(report.stepDays, 0);
      expect(report.bestStepDay, isNull);
      expect(report.stepGoalDays, 0);
    });
  });

  group('Gewicht', () {
    WeightLogEntry at(int back, int hour, double kg) => WeightLogEntry(
      timestamp: _day(back).add(Duration(hours: hour)),
      weightKg: kg,
    );

    test('je Tag zaehlt die letzte Wiegung, nur im Zeitraum', () {
      final report = _build(
        TrendRange.month,
        weighIns: [
          at(40, 7, 90),
          at(20, 7, 81),
          at(20, 21, 80.6),
          at(6, 7, 80),
          at(0, 7, 79.4),
        ],
      );
      final weight = report.weight!;
      expect(weight.points, hasLength(3));
      expect(weight.first, (day: _day(20), kg: 80.6));
      expect(weight.last, (day: _day(0), kg: 79.4));
      expect(weight.changeKg, closeTo(-1.2, 1e-9));
    });

    test('die Rate ist die des Wochen-Checks, nicht erste zu letzter', () {
      // Down 1.4 kg over two weeks, then one high reading: first to last
      // says +0.04 kg/week, the regression the Monday card uses about −0.15.
      final weighIns = [
        for (final (back, kg) in [
          (20, 80.0),
          (16, 79.5),
          (12, 79.1),
          (8, 78.8),
          (4, 78.6),
          (1, 80.1),
        ])
          at(back, 7, kg),
      ];
      final weight = _build(TrendRange.month, weighIns: weighIns).weight!;
      expect(weight.changeKg, greaterThan(0));
      expect(weight.kgPerWeek, closeTo(-0.154, 0.001));
      expect(
        weight.kgPerWeek,
        EnergyCheck.weightRate(
          WeightLog(entries: weighIns),
          today: _day(0),
        ).kgPerWeek,
        reason: 'the same window holds the same weigh-ins: one rate',
      );
    });

    test(
      'unter einer Woche Abstand keine Rate, eine Wiegung keine Aenderung',
      () {
        final two = _build(
          TrendRange.week,
          weighIns: [at(5, 7, 80), at(1, 7, 79.5)],
        ).weight!;
        expect(two.changeKg, closeTo(-0.5, 1e-9));
        expect(two.kgPerWeek, isNull);
        final one = _build(TrendRange.week, weighIns: [at(1, 7, 79)]).weight!;
        expect(one.changeKg, isNull);
        expect(_build(TrendRange.week).weight, isNull);
      },
    );
  });

  group('Training', () {
    test('zaehlt im Zeitraum inklusive heute, nach lokalem Tag', () {
      final report = _build(
        TrendRange.week,
        workouts: [
          _day(0).add(const Duration(hours: 9)).toUtc(),
          _day(6).add(const Duration(hours: 18)).toUtc(),
          _day(7).add(const Duration(hours: 18)).toUtc(),
        ],
      );
      expect(report.workouts, 2);
      expect(report.workoutsPerWeek, 2);
      expect(_build(TrendRange.month).workouts, 0);
    });
  });

  group('overlayTrendTotals', () {
    test(
      'lokale Tage ersetzen Server-Tage, ein leerer lokaler Tag loescht',
      () {
        final merged = overlayTrendTotals(
          [_totals(1, 1000), _totals(2, 2000), _totals(30, 1500)],
          {
            localDayKey(_day(1)): _totals(1, 1600),
            localDayKey(_day(2)): null,
            localDayKey(_day(0)): _totals(0, 400),
          },
        );
        expect(
          [for (final day in merged) (day.day, day.kcal)],
          [(_day(30), 1500), (_day(1), 1600), (_day(0), 400)],
        );
      },
    );
  });
}
