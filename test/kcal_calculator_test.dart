import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// Kalorien-Review 2026-08-21 (docs/REVIEW-KCAL-2026-08-21.md): PAL-Leiter
// 1,4…2,0 statt 1,2…1,9, Schritt-Basis je Stufe, geschlechtsabhaengige
// Untergrenze, 1-%-Defizitdeckel, Protein nach Referenzgewicht, Prognose als
// Spanne. Die Zahlen hier sind aus dem Python-Spiegel des Rechners
// abgeleitet und von Hand gegen calculator.net / NIH BWP geprueft.

void main() {
  group('estimateKcalBurnedFromSteps', () {
    test('uses body weight and height-derived walking distance', () {
      final averageMale = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 78,
        heightCm: 178,
        sex: BiologicalSex.male,
      );
      final heavierMale = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 200,
        heightCm: 178,
        sex: BiologicalSex.male,
      );
      final lighterMale = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 67,
        heightCm: 178,
        sex: BiologicalSex.male,
      );

      // 0,739 m × 10 000 = 7,39 km × 0,5 kcal/kg/km.
      expect(averageMale, 288);
      expect(heavierMale, 739);
      expect(lighterMale, 247);
      expect(heavierMale, greaterThan(lighterMale));
    });

    test('uses profile height so taller users burn more for the same step count', () {
      final shorter = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 78,
        heightCm: 165,
        sex: BiologicalSex.neutral,
      );
      final taller = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 78,
        heightCm: 195,
        sex: BiologicalSex.neutral,
      );

      expect(shorter, 266);
      expect(taller, 315);
      expect(taller, greaterThan(shorter));
    });

    test('returns zero for invalid step or body inputs', () {
      expect(
        estimateKcalBurnedFromSteps(
          steps: 0,
          weightKg: 78,
          heightCm: 178,
          sex: BiologicalSex.neutral,
        ),
        0,
      );
      expect(
        estimateKcalBurnedFromSteps(
          steps: 10000,
          weightKg: 0,
          heightCm: 178,
          sex: BiologicalSex.neutral,
        ),
        0,
      );
      expect(
        estimateKcalBurnedFromSteps(
          steps: 10000,
          weightKg: 78,
          heightCm: 0,
          sex: BiologicalSex.neutral,
        ),
        0,
      );
    });

    test('jeder Schritt zaehlt — linear, ohne Schwelle', () {
      // Produktentscheidung (Review 2026-08-21): Die PAL-Leiter klammert das
      // Gehen aus, deshalb darf hier KEINE Schritt-Basis abgezogen werden —
      // der erste Schritt ist genauso viel wert wie der zehntausendste.
      final fuenf = estimateKcalBurnedFromSteps(
        steps: 5000,
        weightKg: 78,
        heightCm: 178,
        sex: BiologicalSex.male,
      );
      final zehn = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 78,
        heightCm: 178,
        sex: BiologicalSex.male,
      );
      expect(fuenf, 144);
      expect(zehn, 288);
      expect(
        estimateKcalBurnedFromSteps(
          steps: 1,
          weightKg: 78,
          heightCm: 178,
          sex: BiologicalSex.male,
        ),
        0,
        reason: '0,029 kcal runden auf 0 — aber nicht wegen einer Schwelle',
      );
      expect(
        estimateKcalBurnedFromSteps(
          steps: 100,
          weightKg: 78,
          heightCm: 178,
          sex: BiologicalSex.male,
        ),
        3,
      );
    });

    test('das Beispiel aus dem Review: 7000 Schritte bei 100 kg / 180 cm', () {
      // Alte Formel (bis Juni 2026): 7000 × 100 × 0,00057 = 399 kcal — das
      // war der Omni-BRUTTO-Wert inkl. Ruheumsatz. Netto (ACSM-Horizontal-
      // komponente) sind es 261 kcal: 0,747 m × 7000 = 5,23 km × 100 kg × 0,5.
      expect(
        estimateKcalBurnedFromSteps(
          steps: 7000,
          weightKg: 100,
          heightCm: 180,
          sex: BiologicalSex.male,
        ),
        261,
      );
    });
  });

  group('KcalCalculator.calculate', () {
    const calc = KcalCalculator();
    const base = UserProfile(); // 78kg, 178cm, 30J, neutral, sitzend

    test('maintenance uses the activity level, not the step goal', () {
      // Der Bug war: Tagesbedarf wurde aus dem Schritt-ZIEL hochgerechnet
      // und die echten Schritte nochmal addiert. Jetzt darf das Schrittziel
      // den Bedarf NICHT mehr beeinflussen.
      final low = calc.calculate(base.copyWith(dailyStepsGoal: 3000));
      final high = calc.calculate(base.copyWith(dailyStepsGoal: 15000));
      expect(low.kcal, high.kcal);
      expect(low.maintenanceKcal, high.maintenanceKcal);
    });

    test('maintain goal targets the maintenance need (~BMR x 1.3)', () {
      final t = calc.calculate(base); // WeightGoal.maintain
      expect(t.goal, WeightGoal.maintain);
      expect(t.bmr, 1665); // 1664,5 gerundet
      expect(t.maintenanceKcal, 2164); // 1664,5 BMR × 1,3 = 2163,85
      expect(t.kcal, 2150); // auf 50 gerundet
      expect(t.floor, KcalCalculator.kcalFloorNeutral);
      expect(t.deficitCapApplied, isFalse);
    });

    test('weight goal applies its kcal delta on top of maintenance', () {
      final maintain = calc.calculate(base.copyWith(weightGoal: WeightGoal.maintain));
      final lose = calc.calculate(base.copyWith(weightGoal: WeightGoal.lose05kg));
      final gain = calc.calculate(base.copyWith(weightGoal: WeightGoal.gain05kg));

      expect(lose.kcal, maintain.kcal - 550); // −0,5 kg/Woche → 1600
      expect(gain.kcal, maintain.kcal + 550); // +0,5 kg/Woche → 2700
      // Erhaltungsbedarf bleibt unabhängig vom Ziel gleich.
      expect(lose.maintenanceKcal, maintain.maintenanceKcal);
      expect(gain.maintenanceKcal, maintain.maintenanceKcal);
    });

    test('-1 kg/week applies the full 1100 kcal deficit from 100 kg upwards', () {
      // 1 % Koerpergewicht pro Woche: bei 110 kg sind 1,1 kg erlaubt, der
      // Deckel (1210 kcal/Tag) greift nicht.
      const heavy = UserProfile(
        weightKg: 110,
        heightCm: 185,
        ageYears: 30,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.moderate,
      );
      final maintain = calc.calculate(heavy.copyWith(weightGoal: WeightGoal.maintain));
      final lose1kg = calc.calculate(heavy.copyWith(weightGoal: WeightGoal.lose1kg));
      expect(WeightGoal.lose1kg.weeklyRateKg, 1.0);
      // 110 × 11 = 1210 ≥ 1100: der Deckel greift nicht.
      expect(KcalCalculator.maxDeficitKcalPerDay(110), 1210);
      expect(lose1kg.deficitCapApplied, isFalse);
      expect(lose1kg.appliedKcalDelta, -1100);
      expect(lose1kg.kcal, maintain.kcal - 1100);
    });

    test('1-%-Deckel: unter 100 kg wird das Defizit begrenzt', () {
      // 78 kg → 858 kcal/Tag (78 × 11), auf 0,05 kg/Woche abgerundet = 825
      // (0,75). "−1 kg/Woche" ergibt damit real −0,75 kg/Woche — und der
      // Hinweis nennt den Deckel mit runden Zahlen.
      final t = calc.calculate(base.copyWith(weightGoal: WeightGoal.lose1kg));
      expect(KcalCalculator.maxDeficitKcalPerDay(78), 825);
      expect(t.maxDeficitKcal, 825);
      expect(t.appliedKcalDelta, -825);
      expect(t.deficitCapApplied, isTrue);
      expect(t.uncappedKcal, 1350); // 2163,85 − 825 = 1339 → 1350
      expect(t.kcal, 1350); // = Untergrenze „divers", aber nicht geklemmt
      expect(t.floorApplied, isFalse);
      expect(t.effectiveKcalDelta, -814);
      expect(t.effectiveWeeklyRateKg, closeTo(-0.74, 0.0005));
      expect(t.effectivePaceLabel(), '−0,75 kg/Woche');
      expect(t.paceWarning(), contains('825'));
      expect(t.paceWarning(), contains('1 %'));
      expect(t.paceWarning(), contains('−0,75 kg/Woche statt −1 kg/Woche'));

      // −0,75 kg/Woche (825) trifft den Deckel genau → kein Deckel-Fall,
      // aber derselbe Plan.
      final t075 = calc.calculate(base.copyWith(weightGoal: WeightGoal.lose075kg));
      expect(t075.deficitCapApplied, isFalse);
      expect(t075.kcal, 1350);
      expect(t075.paceWarning(), isNull);
    });

    test('Deckel rastert auf 0,05 kg/Woche (55-kcal-Schritte)', () {
      // kg × 11, abgerundet auf 55er-Schritte = (kg ÷ 5) × 55, mindestens 275.
      expect(KcalCalculator.maxDeficitKcalPerDay(30), 330); // 0,3 kg/Woche
      expect(KcalCalculator.maxDeficitKcalPerDay(45), 495); // 0,45
      expect(KcalCalculator.maxDeficitKcalPerDay(55), 605); // 0,55
      expect(KcalCalculator.maxDeficitKcalPerDay(60), 660); // 0,6
      expect(KcalCalculator.maxDeficitKcalPerDay(70), 770); // 0,7
      expect(KcalCalculator.maxDeficitKcalPerDay(74), 770); // 814 → 770
      expect(KcalCalculator.maxDeficitKcalPerDay(78), 825); // 858 → 825
      expect(KcalCalculator.maxDeficitKcalPerDay(99), 1045); // 1089 → 1045
      expect(KcalCalculator.maxDeficitKcalPerDay(100), 1100);
      expect(KcalCalculator.maxDeficitKcalPerDay(130), 1430);
      for (var kg = 30; kg <= 300; kg++) {
        final cap = KcalCalculator.maxDeficitKcalPerDay(kg);
        expect(cap % 55, 0, reason: '$kg kg');
        expect(cap, lessThanOrEqualTo(kg * 11), reason: '$kg kg');
        expect(cap, greaterThan(kg * 11 - 55), reason: '$kg kg');
      }
    });

    test('Zunahme-Stufen kennen keinen Deckel', () {
      final t = calc.calculate(base.copyWith(weightGoal: WeightGoal.gain05kg));
      expect(t.appliedKcalDelta, 550);
      expect(t.deficitCapApplied, isFalse);
    });

    test('clamps daily kcal into a sane range — per sex', () {
      const tiny = UserProfile(
        weightKg: 35,
        heightCm: 140,
        ageYears: 80,
        weightGoal: WeightGoal.lose1kg,
      );
      expect(calc.calculate(tiny).kcal, KcalCalculator.kcalFloorNeutral);
      expect(
        calc.calculate(tiny.copyWith(sex: BiologicalSex.female)).kcal,
        KcalCalculator.kcalFloor,
      );
      expect(
        calc.calculate(tiny.copyWith(sex: BiologicalSex.male)).kcal,
        KcalCalculator.kcalFloorMale,
      );
    });

    test('Untergrenzen: 1200 weiblich, 1500 maennlich, 1350 neutral', () {
      expect(KcalCalculator.kcalFloorFor(BiologicalSex.female), 1200);
      expect(KcalCalculator.kcalFloorFor(BiologicalSex.male), 1500);
      expect(KcalCalculator.kcalFloorFor(BiologicalSex.neutral), 1350);
      expect(KcalCalculator.kcalFloor, 1200, reason: 'absolutes Minimum');
    });

    test('100-kg-Mann, sitzend, −1 kg/Woche: 1500 MIT Warnung statt 1200 ohne',
        () {
      // Vorher: 2316 − 1100 = 1216 → 1200, ohne Warnung. Jetzt: PAL 1,3 →
      // 2509 − 1100 = 1409 → 1400 → Maenner-Untergrenze 1500, und der
      // Hinweis sagt es.
      const mann = UserProfile(
        weightKg: 100,
        heightCm: 180,
        ageYears: 40,
        sex: BiologicalSex.male,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(mann);
      expect(t.maintenanceKcal, 2509);
      expect(t.uncappedKcal, 1400);
      expect(t.kcal, 1500);
      expect(t.floor, 1500);
      expect(t.floorApplied, isTrue);
      expect(t.effectivePaceLabel(), '−0,9 kg/Woche');
      expect(t.paceWarning(), contains('1500 kcal statt 1400 kcal'));
    });

    test('activity level scales maintenance via its PAL factor', () {
      final sedentary =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.sedentary));
      final moderate =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.moderate));
      final athlete =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.athlete));

      // 1664,5 BMR × {1,3, 1,6, 1,9}
      expect(sedentary.maintenanceKcal, 2164);
      expect(moderate.maintenanceKcal, 2663);
      expect(athlete.maintenanceKcal, 3163);
      expect(moderate.kcal, greaterThan(sedentary.kcal));
      expect(athlete.kcal, greaterThan(moderate.kcal));
    });

    test('PAL-Leiter OHNE Gehen: 1,3 … 1,9 (FAO-Sitzbasis + Thermogenese)', () {
      // Gesamt-inklusive DGE/FAO-Leiter (1,4 … 2,0) minus ~0,1 Gehanteil —
      // der kommt ueber die Schritte einzeln dazu.
      expect(ActivityLevel.sedentary.palFactor, 1.3);
      expect(ActivityLevel.light.palFactor, 1.45);
      expect(ActivityLevel.moderate.palFactor, 1.6);
      expect(ActivityLevel.active.palFactor, 1.75);
      expect(ActivityLevel.athlete.palFactor, 1.9);
    });
  });

  group('KcalCalculator.weeksToGoal', () {
    const calc = KcalCalculator();
    const base = UserProfile();

    test('Prognose folgt der EFFEKTIVEN Rate, nicht dem Wunsch-Delta', () {
      // B2: Frueher wurde stur `kcalDelta / 7700` gerechnet — also das
      // Tempo, das der Nutzer gewaehlt hat, nicht das, was sein Tagesziel
      // hergibt.
      //
      // 78 → 68 kg = 10 kg. Erhaltung 2164.
      //   −0,5 kg/Woche → Ziel 1600 kcal (50er-Rundung) → real 564 kcal/Tag
      //     ≙ 0,5127 kg/Woche → 10 / 0,5127 = 19,5 → 20 Wochen.
      final profile = base.copyWith(
        targetWeightKg: 68,
        weightGoal: WeightGoal.lose05kg,
      );
      expect(calc.weeksToGoal(profile), 20);

      // −1 kg/Woche: der 1-%-Deckel laesst 825 kcal zu → Ziel 1350, real
      // 814 kcal/Tag ≙ 0,74 kg/Woche → 13,5 → 14 Wochen (nicht 10).
      expect(
        calc.weeksToGoal(base.copyWith(
          targetWeightKg: 68,
          weightGoal: WeightGoal.lose1kg,
        )),
        14,
      );
    });

    test('is null when maintaining or already at target', () {
      expect(calc.weeksToGoal(base.copyWith(weightGoal: WeightGoal.maintain)), isNull);
      expect(
        calc.weeksToGoal(base.copyWith(
          targetWeightKg: 78,
          weightGoal: WeightGoal.lose05kg,
        )),
        isNull,
      );
    });

    test('is null when target direction contradicts the goal', () {
      // Ziel über aktuellem Gewicht, aber Abnehm-Ziel gewählt → kein Sinn.
      expect(
        calc.weeksToGoal(base.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        )),
        isNull,
      );
    });
  });

  group('KcalCalculator.weeksToGoalRange', () {
    const calc = KcalCalculator();
    const base = UserProfile();

    test('linear ist die Untergrenze, dynamisch die Obergrenze', () {
      // 78 → 68 kg bei −0,5 kg/Woche: linear 20 Wochen; mit sinkendem Bedarf
      // (22 kcal/Tag pro verlorenem kg, Hall) 25 Wochen.
      final profile = base.copyWith(
        targetWeightKg: 68,
        weightGoal: WeightGoal.lose05kg,
      );
      final range = calc.weeksToGoalRange(profile);
      expect(range, isNotNull);
      expect(range!.linearWeeks, 20);
      expect(range.dynamicWeeks, 25);
      expect(calc.weeksToGoal(profile), range.linearWeeks);
    });

    test('das Review-Beispiel: 100 → 85 kg, sitzend, −0,5 kg/Woche', () {
      // Linear 30 Wochen, dynamisch 45 — der NIH Body Weight Planner kommt
      // fuer ein vergleichbares Profil auf ~41. Die lineare Zahl allein war
      // also um ein Drittel zu optimistisch.
      const p3 = UserProfile(
        weightKg: 100,
        heightCm: 180,
        ageYears: 40,
        sex: BiologicalSex.male,
        targetWeightKg: 85,
        weightGoal: WeightGoal.lose05kg,
      );
      final range = calc.weeksToGoalRange(p3);
      expect(range, (linearWeeks: 30, dynamicWeeks: 45));
    });

    test('ohne Prognose (weeksToGoal null) auch keine Spanne', () {
      expect(calc.weeksToGoalRange(base), isNull);
      expect(
        calc.weeksToGoalRange(base.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        )),
        isNull,
      );
    });

    test('Defizit vor dem Ziel aufgebraucht ⇒ dynamisch null („fruehestens")', () {
      // Standardprofil, Ziel 68 kg bei −0,25 kg/Woche: Erhaltung 2164, Ziel
      // 1900 → 264 kcal/Tag. Pro verlorenem kg schrumpft das um 22 kcal — nach
      // ~10 kg ist fast nichts mehr uebrig, die Rate faellt unter das
      // Rauschen. Linear waeren es 42 Wochen — dynamisch unerreichbar.
      final profile = base.copyWith(
        targetWeightKg: 68,
        weightGoal: WeightGoal.lose025kg,
      );
      final range = calc.weeksToGoalRange(profile);
      expect(range, isNotNull);
      expect(range!.linearWeeks, 42);
      expect(range.dynamicWeeks, isNull);
    });

    test('Zunahme: der Bedarf steigt mit jedem Kilo, die Spanne oeffnet sich', () {
      final profile = base.copyWith(
        targetWeightKg: 88,
        weightGoal: WeightGoal.gain05kg,
      );
      final range = calc.weeksToGoalRange(profile);
      expect(range, (linearWeeks: 21, dynamicWeeks: 27));
    });

    test('dynamisch ist nie kleiner als linear', () {
      for (final goal in WeightGoal.values) {
        for (final weight in const [50, 78, 120, 200]) {
          final profile = UserProfile(
            weightKg: weight,
            targetWeightKg: goal.isGain ? weight + 6 : weight - 6,
            weightGoal: goal,
          );
          final range = calc.weeksToGoalRange(profile);
          if (range == null) continue;
          expect(range.linearWeeks, greaterThan(0));
          final dynamicWeeks = range.dynamicWeeks;
          if (dynamicWeeks != null) {
            expect(dynamicWeeks, greaterThanOrEqualTo(range.linearWeeks),
                reason: '$weight kg / ${goal.name}');
          }
        }
      }
    });
  });

  group('Prognose-Texte', () {
    test('Spanne, Einzelwert und „fruehestens" (deutsch)', () {
      expect(
        timelineEstimateText(
          deL10n,
          targetWeightKg: 68,
          weeks: (linearWeeks: 13, dynamicWeeks: 15),
        ),
        '68 kg in ca. 13–15 Wochen erreichbar – anfangs schneller, später '
        'langsamer.',
      );
      expect(
        timelineEstimateText(
          deL10n,
          targetWeightKg: 68,
          weeks: (linearWeeks: 13, dynamicWeeks: 13),
        ),
        '68 kg in ca. 13 Wochen erreichbar.',
      );
      expect(
        timelineEstimateText(
          deL10n,
          targetWeightKg: 40,
          weeks: (linearWeeks: 57, dynamicWeeks: null),
        ),
        '40 kg frühestens in ca. 57 Wochen erreichbar – mit sinkendem Gewicht '
        'lässt das Tempo nach.',
      );
      expect(
        goalProgressWeeksText(
          deL10n,
          gap: 10,
          weeks: (linearWeeks: 13, dynamicWeeks: 15),
        ),
        'Noch 10 kg · Ziel in ca. 13–15 Wochen',
      );
      expect(
        goalProgressWeeksText(
          deL10n,
          gap: 10,
          weeks: (linearWeeks: 13, dynamicWeeks: 13),
        ),
        'Noch 10 kg · Ziel in ca. 13 Wochen',
      );
      expect(
        goalProgressWeeksText(
          deL10n,
          gap: 5,
          weeks: (linearWeeks: 57, dynamicWeeks: null),
        ),
        'Noch 5 kg · Ziel frühestens in ca. 57 Wochen',
      );
    });
  });
}
