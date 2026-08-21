import 'dart:math' as math;

import '../l10n/l10n.dart';
import '../models/model_limits.dart';
import '../models/user_profile.dart';

/// Schätzt aktive Kilokalorien aus Schritten.
///
/// Das ist bewusst kein fixer "kcal pro Schritt"-Wert. Schritte werden erst
/// über eine höhenbasierte Schrittlänge in Distanz umgerechnet, dann über den
/// etablierten Netto-Energieaufwand fürs Gehen geschätzt:
///
///   Distanz km = (steps − baselineSteps) × stepLengthMeters / 1000
///   active kcal ≈ 0.5 × bodyWeightKg × distanceKm
///
/// Die 0.5 kcal/kg/km stammen aus der horizontalen Netto-Komponente der
/// ACSM-Walking-Gleichung (0.1 ml O2/kg/m × 5 kcal/L O2). Netto ist hier
/// wichtig: Das Food-Ziel enthält bereits Grundumsatz/Alltag; "Verbrannt" soll
/// nur den zusätzlichen Bewegungsbonus addieren, nicht Ruheumsatz doppelt.
/// Messreihen (Weyand 2010, Ludlow & Weyand 2016) liegen bei 0.52–0.63 —
/// 0.5 ist also die konservative Untergrenze, nicht die Mitte. Die alte
/// Konstante 0.00057 kcal/Schritt/kg (bis Juni 2026) war der Omni-Calculator-
/// BRUTTO-Wert inklusive Ruheumsatz und zählte beim Addieren auf BMR×PAL rund
/// 110–130 kcal doppelt.
///
/// [baselineSteps] (Kalorien-Review 2026-08-21): Schritte, die die gewählte
/// Aktivitätsstufe ohnehin schon enthält ([ActivityLevelInfo.baselineSteps]).
/// Nur Schritte darüber zählen — sonst stünde der Büro-Alltag einmal im PAL
/// und ein zweites Mal in „Verbrannt". Default 0 = alles zählt (reine
/// Umrechnung, z. B. für Tests).
///
/// Die Schrittlänge nutzt gängige Pedometer-Heuristiken aus der Körpergröße
/// (männlich 41.5 %, weiblich 41.3 %, neutral 41.4 %) — eine Industrie-
/// Konvention für zügiges Komfort-Tempo (~1.3 m/s), keine Studie. Bei
/// langsamem Alltagsgehen überschätzt sie die Distanz, der höhere Netto-
/// Aufwand pro km gleicht das bei den kcal weitgehend aus.
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
  int baselineSteps = 0,
}) {
  if (steps <= 0 || weightKg <= 0 || heightCm <= 0) {
    return 0;
  }
  final extraSteps = steps - (baselineSteps < 0 ? 0 : baselineSteps);
  if (extraSteps <= 0) return 0;
  final distanceKm = estimateWalkingDistanceKm(
    steps: extraSteps,
    heightCm: heightCm,
    sex: sex,
  );
  final activeKcal = weightKg * distanceKm * 0.5;
  return activeKcal.clamp(0, 99999).round();
}

/// Ergebnis von [KcalCalculator.weeksToGoalRange]: [linearWeeks] ist die
/// optimistische Untergrenze (konstantes Defizit, 7700 kcal/kg),
/// [dynamicWeeks] die Obergrenze aus der Wochensimulation mit sinkendem
/// Bedarf — `null`, wenn das Ziel bei unverändertem Tagesziel gar nicht
/// erreicht wird, weil das Defizit vorher aufgebraucht ist.
typedef WeeksToGoalRange = ({int linearWeeks, int? dynamicWeeks});

/// Prognose-Satz der Onboarding-Zusammenfassung für eine [WeeksToGoalRange]:
/// Spanne „in ca. 13–15 Wochen", bei zusammenfallenden Grenzen die einfache
/// Form, ohne dynamische Obergrenze „frühestens".
String timelineEstimateText(
  AppLocalizations l10n, {
  required int targetWeightKg,
  required WeeksToGoalRange weeks,
}) {
  final dynamicWeeks = weeks.dynamicWeeks;
  if (dynamicWeeks == null) {
    return l10n.onboardingTimelineEstimateOpen(
      targetWeightKg,
      weeks.linearWeeks,
    );
  }
  if (dynamicWeeks == weeks.linearWeeks) {
    return l10n.onboardingTimelineEstimate(targetWeightKg, dynamicWeeks);
  }
  return l10n.onboardingTimelineEstimateRange(
    targetWeightKg,
    weeks.linearWeeks,
    dynamicWeeks,
  );
}

/// Gegenstück zu [timelineEstimateText] für die Plan-Karte im Profil
/// („Noch 10 kg · Ziel in ca. 13–15 Wochen").
String goalProgressWeeksText(
  AppLocalizations l10n, {
  required int gap,
  required WeeksToGoalRange weeks,
}) {
  final dynamicWeeks = weeks.dynamicWeeks;
  if (dynamicWeeks == null) {
    return l10n.profileGoalProgressWeeksOpen(gap, weeks.linearWeeks);
  }
  if (dynamicWeeks == weeks.linearWeeks) {
    return l10n.profileGoalProgressWeeks(gap, dynamicWeeks);
  }
  return l10n.profileGoalProgressWeeksRange(gap, weeks.linearWeeks, dynamicWeeks);
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
    required this.floor,
    required this.appliedKcalDelta,
    required this.maxDeficitKcal,
  });

  /// Tagesziel inkl. Ziel-Delta — ohne Schritt-Bonus (der kommt dynamisch
  /// in der CaloriesOverviewCard oben drauf).
  final int kcal;

  /// Dasselbe Tagesziel **vor** der Sicherheitsklemme
  /// ([floor] … [KcalCalculator.kcalCeiling]), bereits auf 50 gerundet und
  /// bereits mit dem 1-%-Defizitdeckel ([maxDeficitKcal]) verrechnet.
  final int uncappedKcal;

  final int proteinG;
  final int carbsG;
  final int fatG;
  final int bmr;

  /// Erhaltungsbedarf: BMR × PAL der gewählten Aktivitätsstufe, ohne
  /// Ziel-Delta.
  final int maintenanceKcal;
  final WeightGoal goal;

  /// Die für dieses Profil geltende Untergrenze
  /// ([KcalCalculator.kcalFloorFor]): 1200 weiblich, 1500 männlich, 1350
  /// neutral.
  final int floor;

  /// Das tatsächlich angesetzte Delta: [WeightGoalInfo.kcalDelta], aber beim
  /// Abnehmen nie tiefer als −[maxDeficitKcal].
  final int appliedKcalDelta;

  /// 1 % Körpergewicht pro Woche in kcal/Tag ([KcalCalculator.maxDeficitKcalPerDay]).
  final int maxDeficitKcal;

  /// Die Untergrenze hat das Ziel angehoben — der Nutzer isst mehr, als sein
  /// gewähltes Tempo verlangt, und nimmt entsprechend langsamer ab.
  bool get floorApplied => uncappedKcal < floor;

  /// Die Obergrenze hat das Ziel gekappt — spiegelbildlich in der
  /// Zunahme-Richtung.
  bool get ceilingApplied => uncappedKcal > KcalCalculator.kcalCeiling;

  /// Eine der beiden Sicherheitsgrenzen hat gegriffen.
  bool get safetyClampApplied => floorApplied || ceilingApplied;

  /// Der 1-%-Deckel hat das gewünschte Defizit verkleinert (Review
  /// 2026-08-21: −1100 kcal/Tag überschreitet alle Leitlinien-Defizite, sobald
  /// 1 kg/Woche mehr als 1 % des Körpergewichts ist, also unter 100 kg).
  bool get deficitCapApplied => appliedKcalDelta != goal.kcalDelta;

  /// Tatsächliche tägliche Differenz zur Erhaltung: **negativ = Defizit**.
  ///
  /// Nicht [WeightGoal.kcalDelta] benutzen, um dem Nutzer etwas anzuzeigen —
  /// das ist der Wunsch, das hier ist der Plan.
  int get effectiveKcalDelta => kcal - maintenanceKcal;

  /// Tatsächlich erreichbare Wochenrate in kg, vorzeichenbehaftet
  /// (negativ = abnehmen).
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
  ///
  /// Seit der i18n-Migration (Paket 7, 2026-08-11) l10n-faehig: [l10n]
  /// optional, Default Deutsch ([deL10n]) — gemeinsam migriert mit
  /// [paceWarning] und `WeightGoalInfo.paceLabel`/`paceLabelForWeeklyRateKg`
  /// (B2-Kopplung, s. Paket-6-/Paket-7-Bericht). Aus einem Getter wurde eine
  /// Methode — Dart-Getter koennen keine Parameter tragen.
  String effectivePaceLabel([AppLocalizations? l10n]) =>
      paceLabelForWeeklyRateKg(effectiveWeeklyRateKg, l10n);

  /// Fertig formulierter Hinweis für die UI, wenn das Tagesziel das gewählte
  /// Tempo nicht hergibt — sonst `null`.
  ///
  /// Reihenfolge = Bindungskraft: erst die Untergrenze, dann die Obergrenze,
  /// dann der 1-%-Defizitdeckel, zuletzt ein nackter Tempo-Unterschied.
  /// Gedacht für die Plan-Karte im Einstellungs-Sheet und die
  /// Onboarding-Zusammenfassung.
  ///
  /// [l10n] optional, Default Deutsch ([deL10n]) — dasselbe Muster wie
  /// [effectivePaceLabel]. Test-API bleibt kontextfrei aufrufbar
  /// (`test/services/kcal_effective_pace_test.dart`).
  String? paceWarning([AppLocalizations? l10n]) {
    if (!safetyClampApplied && !deficitCapApplied && matchesPromisedPace) {
      return null;
    }
    final t = l10n ?? deL10n;
    final effectivePace = effectivePaceLabel(l10n);
    final promisedPace = goal.paceLabel(l10n);
    if (floorApplied) {
      return t.commonPaceWarningFloor(
        floor,
        uncappedKcal,
        effectivePace,
        promisedPace,
      );
    }
    if (ceilingApplied) {
      return t.commonPaceWarningCeiling(
        KcalCalculator.kcalCeiling,
        uncappedKcal,
        effectivePace,
        promisedPace,
      );
    }
    if (deficitCapApplied) {
      return t.commonPaceWarningDeficitCap(
        maxDeficitKcal,
        effectivePace,
        promisedPace,
      );
    }
    return t.commonPaceWarningMismatch(effectivePace, promisedPace);
  }
}

class KcalCalculator {
  const KcalCalculator();

  /// Ernährungsphysiologische Untergrenze des Tagesziels für Frauen — und
  /// zugleich das absolute Minimum, das `calculate` je ausgibt.
  ///
  /// **Bewusst enger als die Datenbank.** `profiles.daily_kcal_goal` erlaubt
  /// 800…7000 ([ProfileLimits.dailyKcalGoalMin] / …Max) — das ist die
  /// Check-Constraint, also die Grenze für *manuell* gesetzte Ziele. Was
  /// `calculate` *automatisch* vorschlägt, bleibt mit 1200…5000 innerhalb
  /// davon.
  ///
  /// Die Untergrenze ist seit dem Kalorien-Review 2026-08-21
  /// geschlechtsabhängig ([kcalFloorFor]): 1200 kcal ist die Leitlinien-
  /// Untergrenze für Frauen (AHA/ACC/TOS 2013, Academy of Nutrition and
  /// Dietetics), für Männer nennen dieselben Leitlinien 1500–1800 kcal. Die
  /// frühere Unisex-Klemme bei 1200 setzte einen 100-kg-Mann ohne Warnung auf
  /// 1200 kcal.
  ///
  /// Weil die App-Grenzen die DB-Grenzen echt einschließen, kann `calculate`
  /// keinen `23514` erzeugen; ein Test in
  /// test/services/kcal_effective_pace_test.dart hält diese Beziehung fest.
  /// Die Klemme kostet allerdings Tempo — siehe [KcalTargets.floorApplied].
  static const int kcalFloor = 1200;

  /// Untergrenze für Männer (NIH/NHLBI, AHA/ACC/TOS: 1500 kcal).
  static const int kcalFloorMale = 1500;

  /// Untergrenze für „divers": Mittelwert der beiden Leitlinienwerte —
  /// konsistent zum gemittelten Mifflin-Offset in [basalMetabolicRate].
  static const int kcalFloorNeutral = 1350;

  /// Obergrenze des automatisch berechneten Tagesziels, siehe [kcalFloor].
  static const int kcalCeiling = 5000;

  static int kcalFloorFor(BiologicalSex sex) => switch (sex) {
        BiologicalSex.male => kcalFloorMale,
        BiologicalSex.female => kcalFloor,
        BiologicalSex.neutral => kcalFloorNeutral,
      };

  /// Größtes Tagesdefizit, das `calculate` ansetzt: 1 % des Körpergewichts
  /// pro Woche (ISSN, Garthe 2011 — Obergrenze für Abnehmen ohne
  /// Muskelverlust), in kcal/Tag: kg × 0,01 × 7700 ÷ 7 = kg × 11.
  ///
  /// Beispiele: 60 kg → 660, 78 kg → 858, 100 kg → 1100. Damit ist
  /// „−1 kg/Woche" erst ab 100 kg voll erreichbar; darunter meldet
  /// [KcalTargets.paceWarning] das tatsächliche Tempo. Leitlinien-Korridore
  /// zum Vergleich: NHLBI 500–1000, AHA/ACC/TOS 500–750, DGE/DAG 500–600
  /// kcal/Tag.
  static int maxDeficitKcalPerDay(int weightKg) =>
      weightKg * (kcalPerKgBodyMass ~/ 700);

  /// Hall-Faustregel für [weeksToGoalRange]: pro dauerhaft verlorenem
  /// Kilogramm sinkt der Tagesbedarf um rund 22 kcal (Hall et al. 2011,
  /// Lancet; enthält die adaptive Thermogenese). Die lineare 7700-Regel
  /// ignoriert das und verspricht über ein Jahr etwa das Doppelte des realen
  /// Verlusts.
  static const int kcalPerDayPerKgChanged = 22;

  /// Länger simuliert [weeksToGoalRange] nicht — danach gilt das Ziel als bei
  /// diesem Tagesziel nicht erreichbar.
  static const int maxPrognosisWeeks = 520;

  /// Protein pro kg **Referenzgewicht** ([proteinReferenceWeightKg]).
  /// 1,6 g/kg ist der Morton-2018-Breakpoint und liegt in der ISSN-Spanne
  /// 1,4–2,0.
  static const double proteinGPerKg = 1.6;

  /// Unter diesen Wert drückt der Energie-Deckel das Protein nur, wenn sonst
  /// [proteinHardMaxEnergyShare] überschritten würde (Leidy 2015: 1,2–1,6
  /// g/kg in der Diät).
  static const double proteinMinGPerKg = 1.2;

  /// AMDR-Obergrenze für Protein (IOM: 10–35 % der Energie).
  static const double proteinMaxEnergyShare = 0.35;

  /// Harte Obergrenze, falls [proteinMinGPerKg] sonst unterschritten würde.
  static const double proteinHardMaxEnergyShare = 0.40;

  /// Fettanteil an der Energie (AMDR/EFSA 20–35 %).
  static const double fatEnergyShare = 0.25;

  /// Kohlenhydrate sind der Rest. Weil Protein höchstens
  /// [proteinHardMaxEnergyShare] und Fett genau [fatEnergyShare] belegen,
  /// bleiben mindestens 35 % der Energie — bei [kcalFloor] also ≥ 105 g und
  /// damit über dem IOM-EAR von 100 g. Der Rest kann nie negativ werden; die
  /// frühere Formel (1,6 g × Ist-Gewicht ohne Deckel) schrieb ab ~141 kg bei
  /// 1200 kcal negative Kohlenhydrate, die nur der DB-Clamp auf 0 hob.
  static const int carbsMinG = 100;

  /// Mifflin-St Jeor basal metabolic rate. For [BiologicalSex.neutral] we
  /// average the male and female offsets (+5 / −161 → −78).
  ///
  /// Die Koeffizienten sind exakt Mifflin et al. 1990 (n = 498, 19–78 J.),
  /// von der Academy of Nutrition and Dietetics für normal-, über- und
  /// adipöse Erwachsene empfohlen; typische Trefferquote ±10 % bei 70–82 %
  /// der Personen. Streng genommen schätzt die Formel den Ruheumsatz (REE),
  /// nicht den Grundumsatz im engen Sinn.
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

  /// Bezugsgewicht für das Proteinziel.
  ///
  /// Bis BMI 25 das Ist-Gewicht; darüber das adjustierte Körpergewicht
  /// (ESPEN-Praxis, DGE: „ein Körpergewicht zugrunde legen, bei dem die
  /// Person Normalgewicht hätte"): Gewicht bei BMI 25 plus 25 % des
  /// Überschusses. 1,6 g × Ist-Gewicht ergab bei 130 kg 208 g Protein — bei
  /// einem 1200-kcal-Ziel 69 % der Energie.
  static double proteinReferenceWeightKg({
    required int weightKg,
    required int heightCm,
  }) {
    if (heightCm <= 0 || weightKg <= 0) {
      return weightKg < 0 ? 0 : weightKg.toDouble();
    }
    final heightM = heightCm / 100;
    final normalKg = 25 * heightM * heightM;
    if (weightKg <= normalKg) return weightKg.toDouble();
    return normalKg + 0.25 * (weightKg - normalKg);
  }

  KcalTargets calculate(UserProfile profile) {
    final bmr = basalMetabolicRate(
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
      ageYears: profile.ageYears,
      sex: profile.sex,
    );
    final maintenance = bmr * profile.activityLevel.palFactor;

    // 1-%-Deckel nur in Abnehm-Richtung; Zunahme-Stufen bleiben wie gewählt.
    final maxDeficit = maxDeficitKcalPerDay(profile.weightKg);
    final wishedDelta = profile.weightGoal.kcalDelta;
    final appliedDelta = wishedDelta < -maxDeficit ? -maxDeficit : wishedDelta;

    final goalAdjusted = maintenance + appliedDelta;
    // Round daily kcal to nearest 50 for nicer-looking numbers.
    final uncappedKcal = (goalAdjusted / 50).round() * 50;
    final floor = kcalFloorFor(profile.sex);
    final kcal = uncappedKcal.clamp(floor, kcalCeiling);

    // Makros: Protein nach Referenzgewicht mit Energie-Deckel, Fett 25 %,
    // Kohlenhydrate der Rest (≥ 35 % der Energie, s. [carbsMinG]).
    //
    // Alle drei Werte gehen als profiles.protein_goal_g / carbs_goal_g /
    // fat_goal_g in die Datenbank und tragen dort Check-Constraints
    // (0..400 / 0..800 / 0..300). Die Clamps aus [ProfileLimits] bleiben als
    // letzte Sicherung stehen, auch wenn die Formel sie rechnerisch nicht
    // mehr erreicht.
    final refKg = proteinReferenceWeightKg(
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
    );
    var proteinG = (refKg * proteinGPerKg).round();
    final softCapG = (kcal * proteinMaxEnergyShare / 4).floor();
    if (proteinG > softCapG) {
      final minG = (refKg * proteinMinGPerKg).round();
      proteinG = minG > softCapG
          ? math.min(minG, (kcal * proteinHardMaxEnergyShare / 4).floor())
          : softCapG;
    }
    proteinG = clampProteinGoalG(proteinG);
    final fatG = clampFatGoalG(((kcal * fatEnergyShare) / 9).round());
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
      floor: floor,
      appliedKcalDelta: appliedDelta,
      maxDeficitKcal: maxDeficit,
    );
  }

  /// Geschätzte Wochen bis zum Wunschgewicht — **optimistische Untergrenze**
  /// auf Basis des Tagesziels, das die App tatsächlich ausgibt, bei
  /// konstantem Defizit.
  ///
  /// Gerechnet wird mit [KcalTargets.effectiveWeeklyRateKg]
  /// ((Tagesziel − Erhaltung) ÷ [kcalPerKgBodyMass]), **nicht** mit
  /// [WeightGoalInfo.weeklyRateKg]. Sonst verspricht die Prognose ein Tempo,
  /// das der Defizitdeckel oder die Sicherheitsklemme gar nicht zulässt (B2).
  ///
  /// Für die Anzeige gehört [weeksToGoalRange] her: die lineare Zahl ist
  /// systematisch zu optimistisch, weil der Bedarf mit jedem Kilo sinkt.
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

  /// Prognose als Spanne: linear ([weeksToGoal]) bis dynamisch.
  ///
  /// Die dynamische Zahl simuliert Woche für Woche mit festem Tagesziel und
  /// einem Bedarf, der pro verändertem Kilogramm um
  /// [kcalPerDayPerKgChanged] kcal sinkt (Abnehmen) bzw. steigt (Zunehmen).
  /// Für 100 → 85 kg bei −550 kcal/Tag ergibt das 46 statt 30 Wochen; der
  /// NIH Body Weight Planner liegt für ein vergleichbares Profil bei ~41.
  ///
  /// `dynamicWeeks == null`: das Defizit ist vor dem Ziel aufgebraucht (oder
  /// [maxPrognosisWeeks] überschritten) — bei unverändertem Tagesziel wird
  /// das Wunschgewicht nicht erreicht; die UI zeigt dann „frühestens".
  /// Ganz `null`, wenn schon [weeksToGoal] keine Prognose hergibt.
  WeeksToGoalRange? weeksToGoalRange(
    UserProfile profile, {
    KcalTargets? targets,
  }) {
    final t = targets ?? calculate(profile);
    final linear = weeksToGoal(profile, targets: t);
    if (linear == null) return null;

    final diffKg = (profile.weightKg - profile.targetWeightKg).abs().toDouble();
    final losing = profile.targetWeightKg < profile.weightKg;
    final direction = losing ? -1 : 1;

    var changedKg = 0.0;
    var weeks = 0;
    while (changedKg < diffKg) {
      if (weeks >= maxPrognosisWeeks) {
        return (linearWeeks: linear, dynamicWeeks: null);
      }
      final maintenanceNow =
          t.maintenanceKcal + direction * kcalPerDayPerKgChanged * changedKg;
      final weeklyKg = (t.kcal - maintenanceNow) * 7 / kcalPerKgBodyMass;
      final progress = direction * weeklyKg;
      if (!progress.isFinite || progress < weeklyRateNoiseKg) {
        return (linearWeeks: linear, dynamicWeeks: null);
      }
      changedKg += progress;
      weeks++;
    }
    return (linearWeeks: linear, dynamicWeeks: math.max(weeks, linear));
  }
}
