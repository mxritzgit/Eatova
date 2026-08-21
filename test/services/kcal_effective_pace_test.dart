import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// B2 (docs/REVIEW-2026-08-08.md): Das Tagesziel wird geklemmt, `paceLabel`
// und `weeksToGoal` rechneten aber weiter mit dem UNGEKAPPTEN `kcalDelta` des
// Ziels. Ergebnis: Die App verspricht ein Tempo, das ihr eigenes Tagesziel
// nicht hergibt.
//
// Diese Datei sichert die *effektive* Rate ab: alles wird aus
// (kcal − Erhaltung) hergeleitet, nicht aus dem Wunsch-Delta.
//
// Kalorien-Review 2026-08-21 (docs/REVIEW-KCAL-2026-08-21.md): Die Klemme
// ist jetzt geschlechtsabhaengig (1200 w / 1500 m / 1350 neutral), davor
// greift ein 1-%-Defizitdeckel (kg × 11 kcal/Tag), und die PAL-Leiter
// beginnt bei 1,4. Das Standardprofil (78 kg, neutral) laeuft deshalb nicht
// mehr in die Untergrenze — dafuer jetzt in den Deckel; die Klemmen-Faelle
// tragen ein kleineres weibliches Profil.

void main() {
  const calc = KcalCalculator();

  // Standardprofil: 78 kg / 178 cm / 30 J. / neutral / sitzend.
  // BMR 1664,5 · Erhaltung 2164 (×1,3, ohne Gehen) · Deckel 825 kcal/Tag
  // (1 % = 858, auf 0,05 kg/Woche = 0,75 abgerundet).
  const standard = UserProfile();

  // Kleineres weibliches Profil: 55 kg / 160 cm / 35 J. / weiblich / sitzend.
  // BMR 1214 · Erhaltung 1578 (×1,3) · Deckel 605 kcal/Tag (1 % = 0,55
  // kg/Woche).
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
      // Erst der Deckel: 1578 − 605 = 973 → auf 50 gerundet 950.
      expect(t.appliedKcalDelta, -605);
      expect(t.uncappedKcal, 950);
      // Dann die Untergrenze fuer Frauen.
      expect(t.floor, KcalCalculator.kcalFloor);
      expect(t.kcal, KcalCalculator.kcalFloor);
      expect(t.floorApplied, isTrue);
      expect(t.ceilingApplied, isFalse);
    });

    test('effektive Rate ist 0,35 kg/Woche, nicht die versprochene 1,0', () {
      final t = calc.calculate(frau.copyWith(weightGoal: WeightGoal.lose1kg));

      // 1578 − 1200 = 378 kcal/Tag ≙ 378 × 7 / 7700 = 0,3436 kg/Woche.
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

      // Beide laufen in den Deckel (605) und dann in die Untergrenze — dann
      // darf die App nicht zwei verschiedene Tempi und zwei verschiedene
      // Zeitraeume ausweisen.
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
      // 5 kg / 0,3436 kg pro Woche = 14,6 → 15 Wochen (versprochen waeren 5).
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
      // 2164 − 1600 = 564 statt 550 — reine 50er-Rundung, kein gebrochenes
      // Versprechen (Rauschgrenze 0,05 kg/Woche ≙ 55 kcal/Tag). Das Label
      // rastert auf 0,05 und zeigt deshalb die gewaehlte runde Zahl, nicht
      // „−0,51".
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
      // Die Untergrenze ist bindender als der Deckel — nur SIE wird genannt.
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
      expect(t.kcal, 1350); // 2164 − 825 = 1339 → 1350 = Untergrenze „divers"
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
      // Hier greift statt des Deckels die Maenner-Untergrenze (2509 − 1100 =
      // 1409 → 1400 → 1500); der Hinweis nennt die Untergrenze, nicht 1 %.
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
    });
  });

  group('B2 · Obergrenze in der Zunahme-Richtung', () {
    // 160 kg / 200 cm / 20 J. / maennlich / athlete: Erhaltung 5235 kcal.
    // +550 → 5785 → auf 50 gerundet 5800 → Obergrenze 5000.
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
      // Wer +0,5 kg/Woche gewaehlt hat, bekommt real ein Defizit von
      // 235 kcal/Tag — die Richtung kippt.
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
      // 10 kg / 0,4873 = 20,5 → 21 Wochen.
      expect(calc.weeksToGoal(profil), 21);
    });
  });

  group('B2 · keine Division durch (fast) null', () {
    test('Erhaltung: stabiles Label, keine Prognose', () {
      final t = calc.calculate(standard);

      // 2164 → 2150 durch die 50er-Rundung: −14 kcal sind Rauschen.
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
      // 40 kg / 150 cm / 45 J. / weiblich / sitzend: Erhaltung 1237.
      // −275 → 962 → gerundet 950 → Untergrenze 1200. Rest: −37 kcal/Tag
      // ≙ 0,034 kg/Woche. Richtung stimmt, das Tempo ist nur bedeutungslos.
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
      // Eigener Satz statt „… ist damit Gewicht stabil statt −0,25 kg/Woche".
      expect(
        t.paceWarning(),
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '950 kcal. Damit bleibt dein Gewicht praktisch stabil, statt '
        '−0,25 kg/Woche zu erreichen.',
      );
    });

    test('Untergrenze kann ein Abnehm-Ziel in einen Ueberschuss drehen', () {
      // 35 kg / 140 cm / 80 J. / neutral: Erhaltung 971 — die Untergrenze
      // 1350 liegt 379 kcal DARUEBER. „Abnehmen" wuerde real Zunehmen
      // bedeuten.
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
                // Der Deckel darf nie in die Zunahme-Richtung wirken und nie
                // das Wunsch-Defizit vergroessern.
                if (goal.isGain && t.appliedKcalDelta != goal.kcalDelta) {
                  verstoesse.add('$wer: Deckel bei Zunahme');
                }
                if (t.appliedKcalDelta < goal.kcalDelta) {
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
    test('die sieben Ziel-Labels bleiben unveraendert', () {
      // paceLabel laeuft jetzt ueber paceLabelForWeeklyRateKg — die Ausgabe
      // fuer die Picker darf sich dadurch nicht verschieben.
      expect(WeightGoal.lose1kg.paceLabel(), '−1 kg/Woche');
      expect(WeightGoal.lose075kg.paceLabel(), '−0,75 kg/Woche');
      expect(WeightGoal.lose05kg.paceLabel(), '−0,5 kg/Woche');
      expect(WeightGoal.lose025kg.paceLabel(), '−0,25 kg/Woche');
      expect(WeightGoal.maintain.paceLabel(), 'Gewicht stabil');
      expect(WeightGoal.gain025kg.paceLabel(), '+0,25 kg/Woche');
      expect(WeightGoal.gain05kg.paceLabel(), '+0,5 kg/Woche');
    });

    test('fast-ganzzahlige Raten ergeben "1", nicht "1,"', () {
      // 1101 kcal/Tag ≙ 1,00091 kg/Woche — ein Wert, den nur die effektive
      // Rate erzeugen kann. Die alte Formatierung schnitt aus "1.00" die
      // Nullen weg und lieferte "+1, kg/Woche".
      expect(paceLabelForWeeklyRateKg(1101 * 7 / kcalPerKgBodyMass),
          '+1 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.7245), '−0,7 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.999), '−1 kg/Woche');
    });

    test('das Label rastert auf 0,05 kg/Woche (Review 2026-08-21)', () {
      // Die 50er-Rundung des Tagesziels verschiebt die Rate um bis zu
      // ±0,023 — ein gewaehltes „−0,5" darf nicht als „−0,48" erscheinen.
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
      // Die App-Grenzen (1200/1350/1500..5000) sind bewusst enger als die
      // DB-Grenze (800..7000): sie sind Ernaehrungs-Untergrenzen, nicht die
      // Constraint. Enger heisst: was die App rechnet, passt immer in die DB.
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
