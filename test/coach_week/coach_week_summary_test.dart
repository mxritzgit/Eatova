// The Coach's seven-day block (C2, 2026-10-18), pure: what the model reads
// about the last seven completed days and the weight trend.
//
// The block must never let the model draw conclusions from missing data: an
// unlogged day is a gap, not 0 kcal; a day below half the goal is probably
// incomplete and stays out of the averages; a weight rate needs the weekly
// check's minimum of weigh-ins and is that check's own number.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/coach_week_summary.dart';
import 'package:eatova/src/services/energy_check.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_day.dart';

/// Sunday 18 October 2026, noon. The week is Sunday 11 .. Saturday 17.
final DateTime _today = DateTime(2026, 10, 18, 12);

DateTime _daysAgo(int n, {int hour = 12}) =>
    DateTime(_today.year, _today.month, _today.day - n, hour);

const int _goal = 2100;
const int _protein = 140;

CoachWeekDay _day(int kcal, {double protein = 140, int bonus = 0}) =>
    (kcal: kcal, proteinG: protein, budgetKcal: _goal + bonus);

/// Days ago -> totals; missing keys are unlogged days.
String _summary(
  Map<int, CoachWeekDay> byDaysAgo, {
  WeightLog weightLog = const WeightLog(),
  Iterable<DateTime>? trainings,
}) => coachWeekSummary(
  today: _today,
  loggedDay: (day) {
    for (final MapEntry(key: n, value: totals) in byDaysAgo.entries) {
      if (localDayKey(_daysAgo(n)) == localDayKey(day)) return totals;
    }
    return null;
  },
  goalKcal: _goal,
  proteinGoalG: _protein,
  weightLog: weightLog,
  trainingsFinishedAt: trainings,
);

WeightLog _weighIns(Map<int, double> kgByDaysAgo) => WeightLog.capped([
  for (final MapEntry(key: n, value: kg) in kgByDaysAgo.entries)
    WeightLogEntry(timestamp: _daysAgo(n, hour: 7), weightKg: kg),
]);

const _keineWiegung = 'Gewichtstrend: keine Wiegung in den letzten 21 Tagen.';

void main() {
  group('coachWeekSummary: Tage', () {
    test('volle Woche: Kopf, kcal je Tag, Schnitt gegen das Ziel, Protein', () {
      final out = _summary({
        for (var n = 1; n <= 7; n++)
          n: _day(1900 + n * 20, protein: n.isEven ? 150 : 120),
      });
      expect(
        out,
        'Letzte 7 Tage ohne heute (11.10.–17.10.): 7 von 7 Tagen erfasst. '
        'kcal je Tag (– = nichts erfasst): So 2040, Mo 2020, Di 2000, '
        'Mi 1980, Do 1960, Fr 1940, Sa 1920. '
        'Ø der 7 erfassten Tage: 1980 kcal (Ziel 2100 kcal), Protein 133 g '
        '(Ziel 140 g, an 3 von 7 Tagen erreicht). $_keineWiegung',
      );
    });

    test('lueckenhafte Woche: Luecken sind keine 0 kcal, ein Teiltag zaehlt '
        'als erfasst, aber nicht in den Schnitt', () {
      final out = _summary({
        6: _day(2300, protein: 150),
        3: _day(600, protein: 20), // below 50 % of 2100: incomplete
        1: _day(1900, protein: 100),
      });
      expect(
        out,
        startsWith(
          'Letzte 7 Tage ohne heute (11.10.–17.10.): 3 von 7 Tagen erfasst, '
          'davon 1 unter 50 % des Ziels (vermutlich unvollständig). '
          'kcal je Tag (– = nichts erfasst): So –, Mo 2300, Di –, Mi –, '
          'Do 600, Fr –, Sa 1900. ',
        ),
      );
      // (2300 + 1900) / 2: neither the gaps nor the 600-kcal day pull it down.
      expect(
        out,
        contains(
          'Ø der 2 vollständigen Tage: 2100 kcal (Ziel 2100 kcal), '
          'Protein 125 g (Ziel 140 g, an 1 von 2 Tagen erreicht).',
        ),
      );
    });

    test('keine Daten: nur die Zahl und der Hinweis aufs Gewicht', () {
      expect(
        _summary({}),
        'Letzte 7 Tage ohne heute (11.10.–17.10.): 0 von 7 Tagen erfasst. '
        '$_keineWiegung',
      );
    });

    test('nur Teiltage: kein Durchschnitt statt eines falschen', () {
      final out = _summary({2: _day(400), 4: _day(900)});
      expect(out, contains('2 von 7 Tagen erfasst, davon 2 unter 50 %'));
      expect(
        out,
        contains('Kein Tag vollständig erfasst, daher kein Durchschnitt.'),
      );
      expect(out, isNot(contains('Ø')));
    });

    test('ein einziger Tag: kein Schnitt-Wording, Protein erreicht/nicht', () {
      expect(
        _summary({1: _day(2000, protein: 141)}),
        contains(
          'Der eine erfasste Tag: 2000 kcal (Ziel 2100 kcal), Protein 141 g '
          '(Ziel 140 g, erreicht).',
        ),
      );
      expect(
        _summary({1: _day(2000, protein: 90)}),
        contains('Protein 90 g (Ziel 140 g, nicht erreicht).'),
      );
    });

    test('Aktivitaetsbonus: das Ziel ist das Tagesbudget wie in Heute', () {
      final out = _summary({
        1: _day(2400, bonus: 300),
        2: _day(2200, bonus: 100),
      });
      expect(
        out,
        contains(
          'Ø der 2 erfassten Tage: 2300 kcal '
          '(Ziel Ø 2300 kcal inkl. Aktivitätsbonus)',
        ),
      );
    });

    test(
      'heute ist ausgeschlossen: gefragt werden genau die sieben Tage davor',
      () {
        final asked = <String>[];
        coachWeekSummary(
          today: _today,
          loggedDay: (day) {
            asked.add(localDayKey(day));
            return null;
          },
          goalKcal: _goal,
          proteinGoalG: _protein,
          weightLog: const WeightLog(),
        );
        expect(asked, [
          '2026-10-11',
          '2026-10-12',
          '2026-10-13',
          '2026-10-14',
          '2026-10-15',
          '2026-10-16',
          '2026-10-17',
        ]);
      },
    );

    test(
      'ueber die Zeitumstellung (25.10.) bleiben es sieben Kalendertage',
      () {
        final asked = <String>[];
        final out = coachWeekSummary(
          // Shortly after midnight, the day after the switch.
          today: DateTime(2026, 10, 26, 0, 30),
          loggedDay: (day) {
            asked.add(localDayKey(day));
            return null;
          },
          goalKcal: _goal,
          proteinGoalG: _protein,
          weightLog: const WeightLog(),
        );
        expect(asked, [
          '2026-10-19',
          '2026-10-20',
          '2026-10-21',
          '2026-10-22',
          '2026-10-23',
          '2026-10-24',
          '2026-10-25',
        ]);
        expect(out, startsWith('Letzte 7 Tage ohne heute (19.10.–25.10.)'));
      },
    );
  });

  group('coachWeekSummary: Gewicht', () {
    test('viele Wiegungen: Rate auf dem App-Raster plus Rauschband', () {
      // Daily, -0.05 kg/day = -0.35 kg/week, no scatter: the band is the
      // 0.5 kg noise floor over 21 days, 2 x 0.5 / sqrt(770) x 7 = 0.25.
      final log = _weighIns({for (var n = 1; n <= 21; n++) n: 90 + 0.05 * n});
      expect(
        _summary({}, weightLog: log),
        endsWith(
          'Gewichtstrend über 21 Tage: −0,35 kg/Woche '
          '(±0,25 kg/Woche; 21 Wiegetage).',
        ),
      );
    });

    test('flach: "Gewicht stabil" wie die App, mit Band', () {
      final log = _weighIns({for (var n = 1; n <= 21; n++) n: 80.0});
      expect(
        _summary({}, weightLog: log),
        endsWith(
          'Gewichtstrend über 21 Tage: Gewicht stabil '
          '(±0,25 kg/Woche; 21 Wiegetage).',
        ),
      );
    });

    test('wenige Wiegungen: keine erfundene Rate', () {
      expect(
        _summary({}, weightLog: _weighIns({2: 80, 9: 79.5, 16: 79.2})),
        endsWith(
          'Gewichtstrend: noch nicht bestimmbar (3 Wiegetage in 21 Tagen, '
          'nötig sind 4 über mindestens 14 Tage).',
        ),
      );
      expect(
        _summary({}, weightLog: _weighIns({3: 80})),
        contains('(1 Wiegetag in 21 Tagen,'),
      );
      // Enough days, but only ten days apart.
      expect(
        _summary(
          {},
          weightLog: _weighIns({1: 80, 3: 80, 5: 79.8, 8: 79.7, 11: 79.6}),
        ),
        contains('noch nicht bestimmbar (5 Wiegetage'),
      );
    });

    test('heutige Wiegung und Ausreisser zaehlen nicht mit', () {
      final log = WeightLog.capped([
        ..._weighIns({for (var n = 1; n <= 21; n++) n: 80.0}).entries,
        // Today: outside the window that ends yesterday.
        WeightLogEntry(timestamp: _daysAgo(0, hour: 7), weightKg: 95),
      ]);
      expect(_summary({}, weightLog: log), contains('21 Wiegetage'));
      // A typo (8 kg instead of 80) more than 5 % off the median.
      final typo = WeightLog.capped([
        ..._weighIns({for (var n = 2; n <= 21; n++) n: 80.0}).entries,
        WeightLogEntry(timestamp: _daysAgo(1, hour: 7), weightKg: 8),
      ]);
      expect(_summary({}, weightLog: typo), contains('Gewicht stabil'));
      expect(_summary({}, weightLog: typo), contains('20 Wiegetage'));
    });

    test('der Block zeigt die Rate des Wochen-Checks, nicht eine eigene', () {
      // The weekly check's own scenario: 21 days of 2100 kcal, a daily
      // weigh-in losing 0.02 kg/day.
      final profile = const KcalCalculator().applyLiveGoals(
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
      final log = _weighIns({
        for (var n = 1; n <= 21; n++) n: 84 - 0.02 * (21 - n),
      });
      final today = DateTime(_today.year, _today.month, _today.day);
      final proposal = const EnergyCheck().evaluate(
        profile: profile,
        today: today,
        intakeKcal: (_) => 2100,
        burnedKcal: (_) => null,
        weightLog: log,
      )!;
      final rate = EnergyCheck.weightRate(log, today: today);
      expect(rate.kgPerWeek, proposal.weeklyRateKg);
      expect(rate.weighInDays, proposal.weighInDays);
      // The block itself carries the check's number and its weigh-in days.
      expect(
        _summary({}, weightLog: log),
        contains(
          'Gewichtstrend über 21 Tage: '
          '${paceLabelForWeeklyRateKg(proposal.weeklyRateKg)} ',
        ),
      );
      expect(
        _summary({}, weightLog: log),
        endsWith('; ${proposal.weighInDays} Wiegetage).'),
      );
    });
  });

  group('coachWeekSummary: Trainings', () {
    test('ohne Trainingshistorie keine Zahl statt einer falschen Null', () {
      expect(_summary({}), isNot(contains('Training')));
    });

    test('zaehlt nur die sieben Tage vor heute', () {
      final out = _summary(
        {},
        trainings: [
          _daysAgo(8, hour: 23), // before the window
          DateTime(2026, 10, 11, 0, 5), // first minute of the window
          _daysAgo(3, hour: 18),
          DateTime(2026, 10, 17, 23, 55), // last minute of the window
          _daysAgo(0, hour: 9), // today
        ],
      );
      expect(out, endsWith('$_keineWiegung Trainings in der App: 3.'));
    });

    test('Historie vorhanden, aber diese Woche nichts: ehrliche Null', () {
      expect(
        _summary({}, trainings: [_daysAgo(30)]),
        endsWith('Trainings in der App: 0.'),
      );
    });
  });
}
