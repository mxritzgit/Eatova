import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// B2 (docs/REVIEW-2026-08-08.md): Das Tagesziel wird auf 1200..5000 geklemmt,
// `paceLabel` und `weeksToGoal` rechneten aber weiter mit dem UNGEKAPPTEN
// `kcalDelta` des Ziels. Ergebnis: Die App verspricht ein Tempo, das ihr
// eigenes Tagesziel nicht hergibt — beim Standardprofil 1 kg/Woche statt
// tatsaechlich 0,72 kg/Woche.
//
// Diese Datei sichert die *effektive* Rate ab: alles wird aus
// (kcal − Erhaltung) hergeleitet, nicht aus dem Wunsch-Delta.

void main() {
  const calc = KcalCalculator();

  // Standardprofil aus dem Review: 78 kg / 178 cm / 30 J. / neutral / sitzend.
  // BMR 1664,5 · Erhaltung 1997 (×1,2).
  const standard = UserProfile();

  group('B2 · Untergrenze kappt das Defizit', () {
    test('lose1kg: gewuenscht 900 kcal, ausgegeben 1200 kcal', () {
      final t = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose1kg),
      );

      expect(t.maintenanceKcal, 1997);
      expect(t.uncappedKcal, 900, reason: '1997 − 1100 = 897 → auf 50 gerundet');
      expect(t.kcal, KcalCalculator.kcalFloor);
      expect(t.floorApplied, isTrue);
      expect(t.ceilingApplied, isFalse);
    });

    test('effektive Rate ist 0,72 kg/Woche, nicht die versprochene 1,0', () {
      final t = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose1kg),
      );

      // 1997 − 1200 = 797 kcal/Tag ≙ 797 × 7 / 7700 = 0,7245 kg/Woche.
      expect(t.effectiveKcalDelta, -797);
      expect(t.effectiveWeeklyRateKg, closeTo(-0.7245, 0.0005));
      expect(t.promisedWeeklyRateKg, -1.0);
      expect(t.matchesPromisedPace, isFalse);
      expect(t.effectivePaceLabel(), '−0,72 kg/Woche');
    });

    test('lose075kg und lose1kg: identischer Plan ⇒ identisches Versprechen',
        () {
      final schnell = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose1kg),
      );
      final langsamer = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose075kg),
      );

      // Beide landen auf 1200 kcal — dann darf die App nicht zwei
      // verschiedene Tempi und zwei verschiedene Zeitraeume ausweisen.
      expect(schnell.kcal, langsamer.kcal);
      expect(schnell.effectiveWeeklyRateKg, langsamer.effectiveWeeklyRateKg);
      expect(schnell.effectivePaceLabel(), langsamer.effectivePaceLabel());

      final zielProfil = standard.copyWith(targetWeightKg: 68);
      expect(
        calc.weeksToGoal(zielProfil.copyWith(weightGoal: WeightGoal.lose1kg)),
        calc.weeksToGoal(
          zielProfil.copyWith(weightGoal: WeightGoal.lose075kg),
        ),
      );
    });

    test('weeksToGoal folgt der effektiven Rate: 14 statt 10 Wochen', () {
      final profil = standard.copyWith(
        targetWeightKg: 68,
        weightGoal: WeightGoal.lose1kg,
      );
      // 10 kg / 0,7245 kg pro Woche = 13,8 → aufgerundet 14.
      expect(calc.weeksToGoal(profil), 14);
    });

    test('ohne Klemme bleibt das Versprechen erhalten (Rundungstoleranz)', () {
      final t = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose05kg),
      );

      expect(t.kcal, 1450);
      expect(t.floorApplied, isFalse);
      // 1997 − 1450 = 547 statt 550 — reine 50er-Rundung, kein gebrochenes
      // Versprechen.
      expect(t.effectiveKcalDelta, -547);
      expect(t.matchesPromisedPace, isTrue);
      expect(t.effectivePaceLabel(), '−0,5 kg/Woche');
    });

    test('paceWarning nennt Grenze, echtes Ziel und echtes Tempo', () {
      final t = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose1kg),
      );
      final hinweis = t.paceWarning();

      expect(hinweis, isNotNull);
      expect(hinweis, contains('1200'));
      expect(hinweis, contains('0,72'));

      final ohne = calc.calculate(
        standard.copyWith(weightGoal: WeightGoal.lose05kg),
      );
      expect(ohne.paceWarning(), isNull);
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
    });

    test('weeksToGoal liefert null, wenn die Richtung kippt', () {
      expect(calc.weeksToGoal(gross), isNull);
    });

    test('erreichbare Zunahme wird weiterhin prognostiziert', () {
      final profil = standard.copyWith(
        targetWeightKg: 88,
        weightGoal: WeightGoal.gain05kg,
      );
      final t = calc.calculate(profil);

      expect(t.kcal, 2550);
      expect(t.ceilingApplied, isFalse);
      expect(t.effectiveKcalDelta, 553);
      // 10 kg / 0,5027 = 19,89 → 20 Wochen.
      expect(calc.weeksToGoal(profil), 20);
    });
  });

  group('B2 · keine Division durch (fast) null', () {
    test('Erhaltung: stabiles Label, keine Prognose', () {
      final t = calc.calculate(standard);

      // 1997 → 2000 durch die 50er-Rundung: +3 kcal sind Rauschen.
      expect(t.effectiveKcalDelta, 3);
      expect(t.effectivePaceLabel(), 'Gewicht stabil');
      expect(t.matchesPromisedPace, isTrue);
      expect(
        calc.weeksToGoal(standard.copyWith(targetWeightKg: 68)),
        isNull,
        reason: 'Erhaltung fuehrt zu keinem Wunschgewicht',
      );
    });

    test('Klemme frisst das Defizit fast vollstaendig ⇒ keine Prognose', () {
      // 45 kg / 150 cm / 40 J. / weiblich / sitzend: Erhaltung 1232.
      // −275 → 957 → gerundet 950 → Untergrenze 1200. Rest: −32 kcal/Tag
      // ≙ 0,029 kg/Woche. Richtung stimmt, das Tempo ist nur bedeutungslos.
      const knapp = UserProfile(
        weightKg: 45,
        heightCm: 150,
        ageYears: 40,
        sex: BiologicalSex.female,
        targetWeightKg: 40,
        weightGoal: WeightGoal.lose025kg,
      );
      final t = calc.calculate(knapp);

      expect(t.floorApplied, isTrue);
      expect(t.effectiveKcalDelta, -32);
      expect(t.effectiveWeeklyRateKg.abs(), lessThan(weeklyRateNoiseKg));
      expect(t.effectivePaceLabel(), 'Gewicht stabil');
      expect(calc.weeksToGoal(knapp), isNull);
    });

    test('Untergrenze kann ein Abnehm-Ziel in einen Ueberschuss drehen', () {
      // 35 kg / 140 cm / 80 J.: Erhaltung 896 — die Untergrenze liegt
      // 304 kcal DARUEBER. „Abnehmen" wuerde real Zunehmen bedeuten.
      const winzig = UserProfile(
        weightKg: 35,
        heightCm: 140,
        ageYears: 80,
        targetWeightKg: 32,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(winzig);

      expect(t.kcal, KcalCalculator.kcalFloor);
      expect(t.effectiveKcalDelta, 304);
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
      expect(paceLabelForWeeklyRateKg(-0.7245), '−0,72 kg/Woche');
      expect(paceLabelForWeeklyRateKg(-0.999), '−1 kg/Woche');
    });

    test('nicht-endliche Raten erreichen kein Widget', () {
      expect(paceLabelForWeeklyRateKg(double.nan), 'Gewicht stabil');
      expect(paceLabelForWeeklyRateKg(double.infinity), 'Gewicht stabil');
      expect(paceLabelForWeeklyRateKg(0), 'Gewicht stabil');
    });
  });

  group('B2 · Tagesziel bleibt innerhalb der DB-Grenzen', () {
    test('kcal-Klemme der App liegt innerhalb von profiles.daily_kcal_goal',
        () {
      // Die App-Grenze (1200..5000) ist bewusst enger als die DB-Grenze
      // (800..7000): 1200 kcal ist die Ernaehrungs-Untergrenze, nicht die
      // Constraint. Enger heisst: was die App rechnet, passt immer in die DB.
      expect(
        KcalCalculator.kcalFloor,
        greaterThanOrEqualTo(ProfileLimits.dailyKcalGoalMin),
      );
      expect(
        KcalCalculator.kcalCeiling,
        lessThanOrEqualTo(ProfileLimits.dailyKcalGoalMax),
      );
    });
  });
}
