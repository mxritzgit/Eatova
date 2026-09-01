import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// B2: the daily target is clamped, but `paceLabel` and `weeksToGoal` used to
// keep computing from the uncapped goal delta, so the app promised a pace its
// own target could not deliver. This file pins the *effective* rate: every
// number derives from (kcal − maintenance), not from the wanted delta.
//
// Since the calorie review the floor is sex-dependent (1200 f / 1500 m / 1350
// neutral) and a 1 % deficit cap (kg × 11 kcal/day) applies first. The default
// profile therefore hits the cap, not the floor, so the clamp cases use a
// smaller female profile.

void main() {
  const calc = KcalCalculator();

  // Default profile: 78 kg / 178 cm / 30 y / neutral / sedentary.
  // BMR 1664.5 · maintenance 2164 (×1.3) · cap 825 kcal/day (1 % = 858,
  // rounded down to the 0.05 kg/week grid).
  //
  // Wunschgewicht 70 statt der Vorgabe 78: seit P9-08d plant `calculate` mit
  // dem WIRKSAMEN Ziel, und Wunsch == Gewicht heisst "erreicht" — ein
  // Abnehm-Profil ohne Rest-Weg faellt auf Halten zurueck. Diese Suite misst
  // aber genau die Defizit-Plaene. Auf die Zahlen unten wirkt das nicht: das
  // Wunschgewicht geht nur in die Prognose ein, nicht in das Tagesziel.
  const standard = UserProfile(targetWeightKg: 70);

  // Smaller female profile: 55 kg / 160 cm / 35 y / female / sedentary.
  // BMR 1214 · maintenance 1578 (×1.3) · cap 605 kcal/day.
  const frau = UserProfile(
    weightKg: 55,
    heightCm: 160,
    ageYears: 35,
    sex: BiologicalSex.female,
    targetWeightKg: 50,
  );

  group('B2 · Untergrenze kappt das Defizit', () {
    test('lose1kg: gewuenscht 1100 kcal, ausgegeben 1200 kcal', () {
      final t = calc.calculate(frau.copyWith(weightGoal: WeightGoal.lose1kg));

      expect(t.maintenanceKcal, 1578);
      // First the cap: 1578 − 605 = 973 → rounded to 950.
      expect(t.appliedKcalDelta, -605);
      expect(t.uncappedKcal, 950);
      // Then the female floor.
      expect(t.floor, KcalCalculator.kcalFloor);
      expect(t.kcal, KcalCalculator.kcalFloor);
      expect(t.floorApplied, isTrue);
      expect(t.ceilingApplied, isFalse);
    });

    test('effektive Rate ist 0,35 kg/Woche, nicht die versprochene 1,0', () {
      final t = calc.calculate(frau.copyWith(weightGoal: WeightGoal.lose1kg));

      // 1578 − 1200 = 378 kcal/day ≙ 378 × 7 / 7700 = 0.3436 kg/week.
      expect(t.effectiveKcalDelta, -378);
      expect(t.effectiveWeeklyRateKg, closeTo(-0.3436, 0.0005));
      expect(t.promisedWeeklyRateKg, -1.0);
      expect(t.matchesPromisedPace, isFalse);
      expect(t.effectivePaceLabel(), '−0,35 kg/Woche');
    });

    test('lose075kg und lose1kg: identischer Plan ⇒ identisches Versprechen',
        () {
      final schnell = calc.calculate(
        frau.copyWith(weightGoal: WeightGoal.lose1kg),
      );
      final langsamer = calc.calculate(
        frau.copyWith(weightGoal: WeightGoal.lose075kg),
      );

      // Both hit the cap and then the floor, so the app must not report two
      // different paces and two different timelines.
      expect(schnell.kcal, langsamer.kcal);
      expect(schnell.effectiveWeeklyRateKg, langsamer.effectiveWeeklyRateKg);
      expect(schnell.effectivePaceLabel(), langsamer.effectivePaceLabel());
      expect(
        calc.weeksToGoal(frau.copyWith(weightGoal: WeightGoal.lose1kg)),
        calc.weeksToGoal(frau.copyWith(weightGoal: WeightGoal.lose075kg)),
      );
    });

    test('weeksToGoal folgt der effektiven Rate: 15 statt 5 Wochen', () {
      final profil = frau.copyWith(weightGoal: WeightGoal.lose1kg);
      // 5 kg / 0.3436 per week = 14.6 → 15 weeks (5 were promised).
      expect(calc.weeksToGoal(profil), 15);
      expect(
        calc.weeksToGoalRange(profil),
        (linearWeeks: 15, dynamicWeeks: 18),
      );
    });

    test('ohne Klemme bleibt das Versprechen erhalten (Rundungstoleranz)', () {
      final t = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose05kg),
      );

      expect(t.kcal, 1600);
      expect(t.floorApplied, isFalse);
      expect(t.deficitCapApplied, isFalse);
      // 2164 − 1600 = 564 instead of 550: pure rounding, not a broken promise
      // (noise threshold 0.05 kg/week ≙ 55 kcal/day). The label snaps to the
      // 0.05 grid and shows the chosen round number.
      expect(t.effectiveKcalDelta, -564);
      expect(t.matchesPromisedPace, isTrue);
      expect(t.effectivePaceLabel(), '−0,5 kg/Woche');
      expect(t.paceWarning(), isNull);
    });

    test('paceWarning nennt Grenze, echtes Ziel und echtes Tempo', () {
      final t = calc.calculate(frau.copyWith(weightGoal: WeightGoal.lose1kg));
      final hinweis = t.paceWarning();

      expect(hinweis, isNotNull);
      expect(hinweis, contains('1200'));
      expect(hinweis, contains('950'));
      expect(hinweis, contains('0,35'));
      // The floor binds harder than the cap, so only the floor is named.
      expect(hinweis, isNot(contains('1 %')));
    });
  });

  group('Review 2026-08-21 · 1-%-Defizitdeckel', () {
    test('Standardprofil, −1 kg/Woche: Deckel 825 statt 1100', () {
      final t = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose1kg),
      );
      expect(t.maxDeficitKcal, 825);
      expect(t.appliedKcalDelta, -825);
      expect(t.deficitCapApplied, isTrue);
      expect(t.kcal, 1350); // 2164 − 825 = 1339 → 1350 = neutral floor
      expect(t.floorApplied, isFalse);
      expect(t.effectivePaceLabel(), '−0,75 kg/Woche');

      final hinweis = t.paceWarning();
      expect(hinweis, isNotNull);
      expect(hinweis, contains('1 %'));
      expect(hinweis, contains('825'));
      expect(hinweis, contains('−0,75 kg/Woche'));
      expect(hinweis, contains('−1 kg/Woche'));
    });

    test('ab 100 kg ist 1 kg/Woche genau 1 % — kein Deckel', () {
      const hundert = UserProfile(
        weightKg: 100,
        heightCm: 180,
        ageYears: 40,
        sex: BiologicalSex.male,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(hundert);
      expect(t.maxDeficitKcal, 1100);
      expect(t.deficitCapApplied, isFalse);
      // The male floor bites instead of the cap (2509 − 1100 = 1409 → 1500),
      // so the warning names the floor, not the 1 % rule.
      expect(t.kcal, 1500);
      expect(t.floorApplied, isTrue);
      expect(t.paceWarning(), contains('1500'));
      expect(t.paceWarning(), isNot(contains('1 %')));
    });

    test('Deckel = Gewicht × 11 (1 % × 7700 ÷ 7), auf 0,05 kg/Woche abgerundet',
        () {
      expect(KcalCalculator.maxDeficitKcalPerDay(45), 495); // 0,45
      expect(KcalCalculator.maxDeficitKcalPerDay(60), 660); // 0,6
      expect(KcalCalculator.maxDeficitKcalPerDay(78), 825); // 858 → 0,75
      expect(KcalCalculator.maxDeficitKcalPerDay(99), 1045); // 1089 → 0,95
      expect(KcalCalculator.maxDeficitKcalPerDay(100), 1100);
      expect(KcalCalculator.maxDeficitKcalPerDay(300), 3300);
      // Lower bound of the cap: below ~25 kg the 1 % rule would fall under the
      // gentlest pace and forbid even −0,25 kg/Woche. Unreachable through a
      // valid profile (weightKgMin 30), which is exactly why nothing else
      // pins it — the guard would be free to disappear unnoticed.
      expect(
        KcalCalculator.maxDeficitKcalPerDay(10),
        WeightGoal.lose025kg.kcalDelta.abs(),
        reason: 'der Deckel darf das sanfteste Tempo nie unterbieten',
      );
    });
  });

  group('B2 · Obergrenze in der Zunahme-Richtung', () {
    // 160 kg / 200 cm / 20 y / male / athlete: maintenance 5235 kcal.
    // +550 → 5785 → rounded 5800 → ceiling 5000.
    const gross = UserProfile(
      weightKg: 160,
      heightCm: 200,
      ageYears: 20,
      sex: BiologicalSex.male,
      activityLevel: ActivityLevel.athlete,
      targetWeightKg: 170,
      weightGoal: WeightGoal.gain05kg,
    );

    test('Obergrenze macht aus dem Ueberschuss ein Defizit', () {
      final t = calc.calculate(gross);

      expect(t.maintenanceKcal, 5235);
      expect(t.uncappedKcal, 5800);
      expect(t.kcal, KcalCalculator.kcalCeiling);
      expect(t.ceilingApplied, isTrue);
      // Choosing +0.5 kg/week really yields a 235 kcal/day deficit: the
      // direction flips.
      expect(t.effectiveKcalDelta, -235);
      expect(t.effectiveWeeklyRateKg, lessThan(0));
      expect(t.matchesPromisedPace, isFalse);
      expect(t.paceWarning(), contains('5000'));
    });

    test('weeksToGoal liefert null, wenn die Richtung kippt', () {
      expect(calc.weeksToGoal(gross), isNull);
      expect(calc.weeksToGoalRange(gross), isNull);
    });

    test('erreichbare Zunahme wird weiterhin prognostiziert', () {
      final profil = standard.copyWith(
        targetWeightKg: 88,
        weightGoal: WeightGoal.gain05kg,
      );
      final t = calc.calculate(profil);

      expect(t.kcal, 2700);
      expect(t.ceilingApplied, isFalse);
      expect(t.effectiveKcalDelta, 536);
      // 10 kg / 0.4873 = 20.5 → 21 weeks.
      expect(calc.weeksToGoal(profil), 21);
    });
  });

  group('B2 · keine Division durch (fast) null', () {
    test('Erhaltung: stabiles Label, keine Prognose', () {
      final t = calc.calculate(standard);

      // 2164 → 2150 through the rounding: −14 kcal is noise.
      expect(t.effectiveKcalDelta, -14);
      expect(t.effectivePaceLabel(), 'Gewicht stabil');
      expect(t.matchesPromisedPace, isTrue);
      expect(
        calc.weeksToGoal(standard.copyWith(targetWeightKg: 68)),
        isNull,
        reason: 'Erhaltung fuehrt zu keinem Wunschgewicht',
      );
    });

    test('Klemme frisst das Defizit fast vollstaendig ⇒ keine Prognose', () {
      // 40 kg / 150 cm / 45 y / female / sedentary: maintenance 1237.
      // −275 → 950 → floor 1200. What is left is −37 kcal/day ≙ 0.034 kg/week:
      // right direction, meaningless pace.
      const knapp = UserProfile(
        weightKg: 40,
        heightCm: 150,
        ageYears: 45,
        sex: BiologicalSex.female,
        targetWeightKg: 36,
        weightGoal: WeightGoal.lose025kg,
      );
      final t = calc.calculate(knapp);

      expect(t.floorApplied, isTrue);
      expect(t.effectiveKcalDelta, -37);
      expect(t.effectiveWeeklyRateKg.abs(), lessThan(weeklyRateNoiseKg));
      expect(t.effectivePaceLabel(), 'Gewicht stabil');
      expect(calc.weeksToGoal(knapp), isNull);
      expect(calc.weeksToGoalRange(knapp), isNull);
      // Its own sentence instead of the awkward pace phrasing.
      expect(
        t.paceWarning(),
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '950 kcal. Damit bleibt dein Gewicht praktisch stabil, statt '
        '−0,25 kg/Woche zu erreichen.',
      );
    });

    test('Untergrenze kann ein Abnehm-Ziel in einen Ueberschuss drehen', () {
      // 35 kg / 140 cm / 80 y / neutral: maintenance 971, and the 1350 floor
      // sits 379 kcal above it, so losing weight would really mean gaining.
      const winzig = UserProfile(
        weightKg: 35,
        heightCm: 140,
        ageYears: 80,
        targetWeightKg: 32,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(winzig);

      expect(t.kcal, KcalCalculator.kcalFloorNeutral);
      expect(t.effectiveKcalDelta, 379);
      expect(t.effectiveWeeklyRateKg, greaterThan(0));
      expect(calc.weeksToGoal(winzig), isNull);
    });

    test('kein NaN, kein Infinity, keine negative Wochenzahl im ganzen Raum',
        () {
      final verstoesse = <String>[];

      // The whole file measures against `kcal − maintenance`, so the PAL
      // ladder is the silent premise of every number here. Pinned as a
      // literal AND against what `calculate` really multiplies with: the
      // sweep used to walk all five levels while only checking finiteness,
      // so 1,45 → 1,5 passed through unseen.
      const palLeiter = <ActivityLevel, double>{
        ActivityLevel.sedentary: 1.3,
        ActivityLevel.light: 1.45,
        ActivityLevel.moderate: 1.6,
        ActivityLevel.active: 1.75,
        ActivityLevel.athlete: 1.9,
      };

      for (var weight = ProfileLimits.weightKgMin;
          weight <= ProfileLimits.weightKgMax;
          weight += 7) {
        for (var height = ProfileLimits.heightCmMin;
            height <= ProfileLimits.heightCmMax;
            height += 11) {
          for (final sex in BiologicalSex.values) {
            for (final level in ActivityLevel.values) {
              for (final goal in WeightGoal.values) {
                final profil = UserProfile(
                  weightKg: weight,
                  heightCm: height,
                  ageYears: 42,
                  sex: sex,
                  activityLevel: level,
                  targetWeightKg: goal.isGain ? weight + 8 : weight - 8,
                  weightGoal: goal,
                );
                final t = calc.calculate(profil);
                final wer = '$weight kg / $height cm / ${sex.name} / '
                    '${level.name} / ${goal.name}';

                if (level.palFactor != palLeiter[level]) {
                  verstoesse.add('$wer: PAL ${level.palFactor}');
                }
                final erwarteteErhaltung = (calc.basalMetabolicRate(
                      weightKg: weight,
                      heightCm: height,
                      ageYears: 42,
                      sex: sex,
                    ) *
                        palLeiter[level]!)
                    .round();
                if (t.maintenanceKcal != erwarteteErhaltung) {
                  verstoesse.add('$wer: Erhaltung ${t.maintenanceKcal} statt '
                      '$erwarteteErhaltung');
                }
                if (!t.effectiveWeeklyRateKg.isFinite) {
                  verstoesse.add('$wer: Rate ${t.effectiveWeeklyRateKg}');
                }
                if (t.effectivePaceLabel().isEmpty) {
                  verstoesse.add('$wer: leeres Label');
                }
                final wochen = calc.weeksToGoal(profil);
                if (wochen != null && wochen <= 0) {
                  verstoesse.add('$wer: $wochen Wochen');
                }
                final spanne = calc.weeksToGoalRange(profil);
                if ((spanne == null) != (wochen == null)) {
                  verstoesse.add('$wer: Spanne und Einzelwert widersprechen');
                }
                final dynamisch = spanne?.dynamicWeeks;
                if (spanne != null &&
                    dynamisch != null &&
                    dynamisch < spanne.linearWeeks) {
                  verstoesse.add('$wer: dynamisch $dynamisch < linear');
                }
                // The cap must never act in the gain direction and never
                // enlarge the wanted deficit. Measured against the WIRKSAME
                // Richtung (P9-08d): am oberen Spaltenrand (296 kg + 8 = 304 >
                // 300) laesst sich kein konsistentes Zunehm-Ziel mehr bilden,
                // und dort plant `calculate` richtigerweise Halten.
                final wirksam = profil.effectiveWeightGoal;
                if (wirksam.isGain && t.appliedKcalDelta != wirksam.kcalDelta) {
                  verstoesse.add('$wer: Deckel bei Zunahme');
                }
                if (t.appliedKcalDelta < wirksam.kcalDelta) {
                  verstoesse.add('$wer: Deckel vergroessert das Defizit');
                }
              }
            }
          }
        }
      }

      expect(verstoesse, isEmpty,
          reason: verstoesse.take(5).join(' | '));
    });
  });

  group('B2 · Formatierung der Rate', () {
    test('die sieben Ziel-Labels und ihre kcal-Deltas bleiben unveraendert',
        () {
      // The delta ladder is what the label is derived from, and the 0,05 grid
      // swallows a drift of up to ~27 kcal/day — so the labels alone leave the
      // ladder free to move without a single test turning red.
      expect(WeightGoal.lose1kg.kcalDelta, -1100);
      expect(WeightGoal.lose075kg.kcalDelta, -825);
      expect(WeightGoal.lose05kg.kcalDelta, -550);
      expect(WeightGoal.lose025kg.kcalDelta, -275);
      expect(WeightGoal.maintain.kcalDelta, 0);
      expect(WeightGoal.gain025kg.kcalDelta, 275);
      expect(WeightGoal.gain05kg.kcalDelta, 550);
      // paceLabel now routes through paceLabelForWeeklyRateKg; the picker
      // output must not shift because of it.
      expect(WeightGoal.lose1kg.paceLabel(), '−1 kg/Woche');
      expect(WeightGoal.lose075kg.paceLabel(), '−0,75 kg/Woche');
      expect(WeightGoal.lose05kg.paceLabel(), '−0,5 kg/Woche');
      expect(WeightGoal.lose025kg.paceLabel(), '−0,25 kg/Woche');
      expect(WeightGoal.maintain.paceLabel(), 'Gewicht stabil');
      expect(WeightGoal.gain025kg.paceLabel(), '+0,25 kg/Woche');
      expect(WeightGoal.gain05kg.paceLabel(), '+0,5 kg/Woche');
    });

    test('fast-ganzzahlige Raten ergeben "1", nicht "1,"', () {
      // 1101 kcal/day ≙ 1.00091 kg/week, a value only the effective rate can
      // produce. The old formatting stripped the zeros from "1.00" and
      // produced a stray comma.
      expect(paceLabelForWeeklyRateKg(1101 * 7 / kcalPerKgBodyMass),
          '+1 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.7245), '−0,7 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.999), '−1 kg/Woche');
    });

    test('das Label rastert auf 0,05 kg/Woche (Review 2026-08-21)', () {
      // Rounding the daily target shifts the rate by up to ±0.023, so a chosen
      // −0.5 must not surface as −0.48.
      expect(paceLabelForWeeklyRateKg(-0.4818), '−0,5 kg/Woche');
      expect(paceLabelForWeeklyRateKg(0.5182), '+0,5 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.7545), '−0,75 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.2545), '−0,25 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.4545), '−0,45 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.118), '−0,1 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.0245), 'Gewicht stabil');
      expect(paceLabelForWeeklyRateKg(0.05), '+0,05 kg/Woche');
    });

    test('nicht-endliche Raten erreichen kein Widget', () {
      expect(paceLabelForWeeklyRateKg(double.nan), 'Gewicht stabil');
      expect(paceLabelForWeeklyRateKg(double.infinity), 'Gewicht stabil');
      expect(paceLabelForWeeklyRateKg(0), 'Gewicht stabil');
    });
  });

  group('B2 · Tagesziel bleibt innerhalb der DB-Grenzen', () {
    test('kcal-Klemmen der App liegen innerhalb von profiles.daily_kcal_goal',
        () {
      // The app limits (1200/1350/1500..5000) are deliberately tighter than
      // the DB constraint (800..7000): they are nutritional floors, so
      // anything the app computes always fits the DB.
      for (final sex in BiologicalSex.values) {
        expect(
          KcalCalculator.kcalFloorFor(sex),
          greaterThanOrEqualTo(ProfileLimits.dailyKcalGoalMin),
        );
        expect(
          KcalCalculator.kcalFloorFor(sex),
          greaterThanOrEqualTo(KcalCalculator.kcalFloor),
          reason: 'kcalFloor ist das absolute Minimum',
        );
      }
      expect(
        KcalCalculator.kcalCeiling,
        lessThanOrEqualTo(ProfileLimits.dailyKcalGoalMax),
      );
    });
  });
}
