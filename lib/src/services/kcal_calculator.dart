import '../models/model_limits.dart';
import '../models/user_profile.dart';

/// Schätzt aktive Kilokalorien aus Schritten.
///
/// Das ist bewusst kein fixer "kcal pro Schritt"-Wert mehr. Schritte werden
/// erst über eine höhenbasierte Schrittlänge in Distanz umgerechnet, dann über
/// den etablierten Netto-Energieaufwand fürs Gehen geschätzt:
///
///   Distanz km = steps × stepLengthMeters / 1000
///   active kcal ≈ 0.5 × bodyWeightKg × distanceKm
///
/// Die 0.5 kcal/kg/km stammen aus der horizontalen Netto-Komponente der
/// ACSM-Walking-Gleichung (0.1 ml O2/kg/m × 5 kcal/L O2). Netto ist hier
/// wichtig: Das Food-Ziel enthält bereits Grundumsatz/Alltag; "Verbrannt" soll
/// nur den zusätzlichen Bewegungsbonus addieren, nicht Ruheumsatz doppelt.
/// Die Schrittlänge nutzt gängige Pedometer-Heuristiken aus der Körpergröße
/// (männlich 41.5%, weiblich 41.3%, neutral 41.4%).
///
/// Liefert nie negative Werte und ist gegen Nonsense-Eingaben abgesichert.
double estimateStepLengthMeters({
  required int heightCm,
  BiologicalSex sex = BiologicalSex.neutral,
}) {
  if (heightCm <= 0) return 0;
  final ratio = switch (sex) {
    BiologicalSex.male => 0.415,
    BiologicalSex.female => 0.413,
    BiologicalSex.neutral => 0.414,
  };
  return ((heightCm * ratio) / 100).clamp(0.45, 1.05).toDouble();
}

double estimateWalkingDistanceKm({
  required int steps,
  required int heightCm,
  BiologicalSex sex = BiologicalSex.neutral,
}) {
  if (steps <= 0 || heightCm <= 0) return 0;
  return steps * estimateStepLengthMeters(heightCm: heightCm, sex: sex) / 1000;
}

int estimateKcalBurnedFromSteps({
  required int steps,
  required int weightKg,
  required int heightCm,
  BiologicalSex sex = BiologicalSex.neutral,
}) {
  if (steps <= 0 || weightKg <= 0 || heightCm <= 0) {
    return 0;
  }
  final distanceKm = estimateWalkingDistanceKm(
    steps: steps,
    heightCm: heightCm,
    sex: sex,
  );
  final activeKcal = weightKg * distanceKm * 0.5;
  return activeKcal.clamp(0, 99999).round();
}

class KcalTargets {
  const KcalTargets({
    required this.kcal,
    required this.uncappedKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.bmr,
    required this.maintenanceKcal,
    required this.goal,
  });

  /// Tagesziel inkl. Ziel-Delta — ohne Schritt-Bonus (der kommt dynamisch
  /// in der CaloriesOverviewCard oben drauf).
  final int kcal;

  /// Dasselbe Tagesziel **vor** der Sicherheitsklemme
  /// ([KcalCalculator.kcalFloor] … [KcalCalculator.kcalCeiling]), bereits auf
  /// 50 gerundet. Beim Standardprofil mit −1 kg/Woche steht hier 900, in
  /// [kcal] dagegen 1200.
  final int uncappedKcal;

  final int proteinG;
  final int carbsG;
  final int fatG;
  final int bmr;

  /// Erhaltungsbedarf: BMR × Basis-Lebensstil-Faktor, ohne Ziel-Delta.
  final int maintenanceKcal;
  final WeightGoal goal;

  /// Die Untergrenze hat das Ziel angehoben — der Nutzer isst mehr, als sein
  /// gewähltes Tempo verlangt, und nimmt entsprechend langsamer ab.
  bool get floorApplied => uncappedKcal < KcalCalculator.kcalFloor;

  /// Die Obergrenze hat das Ziel gekappt — spiegelbildlich in der
  /// Zunahme-Richtung.
  bool get ceilingApplied => uncappedKcal > KcalCalculator.kcalCeiling;

  /// Eine der beiden Sicherheitsgrenzen hat gegriffen.
  bool get safetyClampApplied => floorApplied || ceilingApplied;

  /// Tatsächliche tägliche Differenz zur Erhaltung: **negativ = Defizit**.
  ///
  /// Nicht [WeightGoal.kcalDelta] benutzen, um dem Nutzer etwas anzuzeigen —
  /// das ist der Wunsch, das hier ist der Plan.
  int get effectiveKcalDelta => kcal - maintenanceKcal;

  /// Tatsächlich erreichbare Wochenrate in kg, vorzeichenbehaftet
  /// (negativ = abnehmen). Standardprofil mit −1 kg/Woche: −0,7245.
  double get effectiveWeeklyRateKg =>
      effectiveKcalDelta * 7 / kcalPerKgBodyMass;

  /// Die vom gewählten Ziel versprochene Rate, gleiches Vorzeichen.
  double get promisedWeeklyRateKg => goal.signedWeeklyRateKg;

  /// `true`, solange Wunsch und Wirklichkeit nur um die 50er-Rundung
  /// auseinanderliegen ([weeklyRateNoiseKg]).
  bool get matchesPromisedPace =>
      (effectiveWeeklyRateKg - promisedWeeklyRateKg).abs() < weeklyRateNoiseKg;

  /// Tempo-Label aus der **effektiven** Rate, z.B. "−0,72 kg/Woche". Liefert
  /// "Gewicht stabil", wenn nichts Nennenswertes übrig bleibt.
  String get effectivePaceLabel =>
      paceLabelForWeeklyRateKg(effectiveWeeklyRateKg);

  /// Fertig formulierter Hinweis für die UI, wenn das Tagesziel das gewählte
  /// Tempo nicht hergibt — sonst `null`.
  ///
  /// Gedacht für die Plan-Karte im Einstellungs-Sheet und die
  /// Onboarding-Zusammenfassung: dort steht heute „Erhaltung 1997 · −1
  /// kg/Woche" direkt über „1200", und die Differenz ist 797, nicht 1100.
  String? get paceWarning {
    if (!safetyClampApplied && matchesPromisedPace) return null;
    if (floorApplied) {
      return 'Aus Sicherheitsgründen liegt dein Tagesziel bei '
          '${KcalCalculator.kcalFloor} kcal statt $uncappedKcal kcal. '
          'Dein tatsächliches Tempo ist damit $effectivePaceLabel statt '
          '${goal.paceLabel}.';
    }
    if (ceilingApplied) {
      return 'Dein Tagesziel ist bei ${KcalCalculator.kcalCeiling} kcal '
          'gedeckelt (rechnerisch wären es $uncappedKcal kcal). '
          'Dein tatsächliches Tempo ist damit $effectivePaceLabel statt '
          '${goal.paceLabel}.';
    }
    return 'Dein tatsächliches Tempo ist $effectivePaceLabel statt '
        '${goal.paceLabel}.';
  }
}

class KcalCalculator {
  const KcalCalculator();

  /// Fallback-Lebensstil-Faktor über dem BMR, falls kein Aktivitätslevel
  /// gesetzt ist. Entspricht [ActivityLevel.sedentary] (1.2) — bewusst
  /// sitzend, weil die *tatsächlich* gegangenen Schritte separat als
  /// "Verbrannt" angerechnet werden (CaloriesOverviewCard).
  ///
  /// Früher war dies der EINZIGE Faktor; jetzt wählt der User im Onboarding
  /// sein Aktivitätslevel und der TDEE nutzt dessen PAL ([ActivityLevel]).
  /// Schritte separat zählen verhindert weiterhin die Doppelzählung.
  static const double baseLifestyleFactor = 1.2;

  /// Ernährungsphysiologische Untergrenze des Tagesziels.
  ///
  /// **Bewusst enger als die Datenbank.** `profiles.daily_kcal_goal` erlaubt
  /// 800…7000 ([ProfileLimits.dailyKcalGoalMin] / …Max) — das ist die
  /// Check-Constraint, also die Grenze für *manuell* gesetzte Ziele. Was
  /// `calculate` *automatisch* vorschlägt, bleibt mit 1200…5000 innerhalb
  /// davon: 1200 kcal ist die gängige Untergrenze für eine Diät ohne
  /// ärztliche Begleitung, 5000 die Obergrenze für einen sinnvollen Aufbau.
  ///
  /// Weil die App-Grenzen die DB-Grenzen echt einschließen, kann `calculate`
  /// keinen `23514` erzeugen; ein Test in
  /// test/services/kcal_effective_pace_test.dart hält diese Beziehung fest.
  /// Die Klemme kostet allerdings Tempo — siehe [KcalTargets.floorApplied].
  static const int kcalFloor = 1200;

  /// Obergrenze des automatisch berechneten Tagesziels, siehe [kcalFloor].
  static const int kcalCeiling = 5000;

  /// Mifflin-St Jeor basal metabolic rate. For [BiologicalSex.neutral] we
  /// average the male and female offsets (+5 / −161 → −78).
  double basalMetabolicRate({
    required int weightKg,
    required int heightCm,
    required int ageYears,
    required BiologicalSex sex,
  }) {
    final base = 10 * weightKg + 6.25 * heightCm - 5 * ageYears;
    final offset = switch (sex) {
      BiologicalSex.male => 5,
      BiologicalSex.female => -161,
      BiologicalSex.neutral => -78,
    };
    return base + offset;
  }

  KcalTargets calculate(UserProfile profile) {
    final bmr = basalMetabolicRate(
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
      ageYears: profile.ageYears,
      sex: profile.sex,
    );
    final maintenance = bmr * profile.activityLevel.palFactor;
    final goalAdjusted = maintenance + profile.weightGoal.kcalDelta;
    // Round daily kcal to nearest 50 for nicer-looking numbers.
    final uncappedKcal = (goalAdjusted / 50).round() * 50;
    final kcal = uncappedKcal.clamp(kcalFloor, kcalCeiling);

    // Macro split: 1.6 g protein per kg, 25% kcal from fat, rest carbs.
    //
    // Alle drei Werte gehen als profiles.protein_goal_g / carbs_goal_g /
    // fat_goal_g in die Datenbank und tragen dort Check-Constraints
    // (0..400 / 0..800 / 0..300). Deshalb klemmt jedes Makro an seiner
    // eigenen Grenze aus [ProfileLimits] — bei 300 kg ergäben 1,6 g/kg sonst
    // 480 g Protein und damit einen `23514` beim Speichern.
    final proteinG = clampProteinGoalG((profile.weightKg * 1.6).round());
    final fatG = clampFatGoalG(((kcal * 0.25) / 9).round());
    final remainingKcal = kcal - proteinG * 4 - fatG * 9;
    final carbsG = clampCarbsGoalG(remainingKcal / 4);

    return KcalTargets(
      kcal: kcal,
      uncappedKcal: uncappedKcal,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
      bmr: bmr.round(),
      maintenanceKcal: maintenance.round(),
      goal: profile.weightGoal,
    );
  }

  /// Geschätzte Wochen bis zum Wunschgewicht — auf Basis des Tagesziels, das
  /// die App tatsächlich ausgibt.
  ///
  /// Gerechnet wird mit [KcalTargets.effectiveWeeklyRateKg]
  /// ((Tagesziel − Erhaltung) ÷ [kcalPerKgBodyMass]), **nicht** mit
  /// [WeightGoalInfo.weeklyRateKg]. Sonst verspricht die Prognose ein Tempo,
  /// das die Sicherheitsklemme gar nicht zulässt (B2): Standardprofil,
  /// −1 kg/Woche, 78 → 68 kg ergab „10 Wochen", real sind es 14.
  ///
  /// Liefert `null`, wenn
  /// * das Wunschgewicht schon erreicht ist,
  /// * die effektive Rate unterhalb von [weeklyRateNoiseKg] liegt (Ziel
  ///   „halten", oder die Klemme frisst das ganze Defizit) — dann gäbe es
  ///   keine sinnvolle Zahl, und eine Division durch ~0 würde eine
  ///   Fantasie-Wochenzahl in ein Widget schreiben,
  /// * die Richtung nicht passt (Abnehm-Ziel bei höherem Wunschgewicht — oder
  ///   ein Plan, der wegen der Klemme in die Gegenrichtung wirkt).
  ///
  /// [targets] darf übergeben werden, wenn der Aufrufer `calculate` ohnehin
  /// schon aufgerufen hat; es muss aus demselben Profil stammen.
  int? weeksToGoal(UserProfile profile, {KcalTargets? targets}) {
    final diffKg = (profile.weightKg - profile.targetWeightKg).abs();
    if (diffKg == 0) return null;
    final rate = (targets ?? calculate(profile)).effectiveWeeklyRateKg;
    if (!rate.isFinite || rate.abs() < weeklyRateNoiseKg) return null;
    final needsToLose = profile.targetWeightKg < profile.weightKg;
    final planLoses = rate < 0;
    if (needsToLose != planLoses) return null;
    return (diffKg / rate.abs()).ceil();
  }
}
