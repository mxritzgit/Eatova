import 'package:intl/intl.dart';

import '../l10n/l10n.dart';

enum BiologicalSex { male, female, neutral }

extension BiologicalSexLabel on BiologicalSex {
  /// Nutzersichtbares Label, sprachaktiv ueber die ARB.
  ///
  /// Seit der i18n-Migration (Paket 6, 2026-08-10) hier zuhause statt als
  /// nackter Getter: die Persistenz (`sex.name`) blieb unberuehrt, s.
  /// `profile_sync.dart`/`sync_outbox.dart` — nur die ANZEIGE braucht die
  /// aktive Sprache. Mirrors [MealSlotStyle.label] (Paket 2).
  String label(AppLocalizations l10n) => switch (this) {
        BiologicalSex.male => l10n.commonSexLabelMale,
        BiologicalSex.female => l10n.commonSexLabelFemale,
        BiologicalSex.neutral => l10n.commonSexLabelNeutral,
      };
}

/// Beruf und Alltag. Multipliziert den Grundumsatz (BMR) zum Erhaltungsbedarf
/// (TDEE) — PAL-Stufen in Anlehnung an FAO/WHO/UNU 2004 und die DGE.
///
/// **Seit dem Kalorien-Review 2026-08-21 (docs/REVIEW-KCAL-2026-08-21.md)
/// beginnt die Leiter bei 1,4, nicht mehr bei 1,2.** 1,2 ist in allen
/// Leitlinien der Wert für bettlägerige/immobile Menschen; der Büroalltag
/// ohne Sport liegt bei DGE 1,4–1,5, EFSA 1,4, gemessen (Doubly Labeled
/// Water) sogar bei 1,55–1,7. Die alten Werte 1,2/1,375/1,55/1,725/1,9 waren
/// eine Online-Rechner-Konvention ohne Primärquelle.
///
/// Gezählte Schritte werden NICHT blind addiert: jede Stufe enthält bereits
/// das für sie übliche Gehpensum ([baselineSteps], Tudor-Locke-Bänder), nur
/// Schritte darüber zählen als „Verbrannt" — sonst würde der Alltag doppelt
/// gutgeschrieben (einmal im PAL, einmal über HealthKit).
enum ActivityLevel { sedentary, light, moderate, active, athlete }

extension ActivityLevelInfo on ActivityLevel {
  /// Physical Activity Level (PAL) — Multiplikator auf den BMR.
  ///
  /// 1,4 sitzend (DGE „überwiegend sitzend"), 1,55 sitzend mit Gehen/Stehen,
  /// 1,7 überwiegend gehend/stehend, 1,85 körperlich fordernd, 2,0 schwere
  /// Arbeit plus Training (FAO/WHO/UNU: sedentary 1,40–1,69, active
  /// 1,70–1,99, vigorous 2,00–2,40).
  double get palFactor => switch (this) {
        ActivityLevel.sedentary => 1.4,
        ActivityLevel.light => 1.55,
        ActivityLevel.moderate => 1.7,
        ActivityLevel.active => 1.85,
        ActivityLevel.athlete => 2.0,
      };

  /// Schritte pro Tag, die in der Stufe schon „drin" sind. Erst Schritte
  /// darüber werden als zusätzlicher Verbrauch gutgeschrieben
  /// (`estimateKcalBurnedFromSteps(baselineSteps: …)`).
  ///
  /// Die Bänder folgen Tudor-Locke & Bassett (2004): < 5000 sedentary,
  /// 5000–7499 low active, 7500–9999 somewhat active, ≥ 10 000 active,
  /// ≥ 12 500 highly active — dasselbe Schwellenprinzip wie bei Lose It!
  /// („exclude to prevent double-counting").
  int get baselineSteps => switch (this) {
        ActivityLevel.sedentary => 5000,
        ActivityLevel.light => 7500,
        ActivityLevel.moderate => 10000,
        ActivityLevel.active => 12500,
        ActivityLevel.athlete => 15000,
      };

  String label(AppLocalizations l10n) => switch (this) {
        ActivityLevel.sedentary => l10n.commonActivityLabelSedentary,
        ActivityLevel.light => l10n.commonActivityLabelLight,
        ActivityLevel.moderate => l10n.commonActivityLabelModerate,
        ActivityLevel.active => l10n.commonActivityLabelActive,
        ActivityLevel.athlete => l10n.commonActivityLabelAthlete,
      };

  String description(AppLocalizations l10n) => switch (this) {
        ActivityLevel.sedentary => l10n.commonActivityDescSedentary,
        ActivityLevel.light => l10n.commonActivityDescLight,
        ActivityLevel.moderate => l10n.commonActivityDescModerate,
        ActivityLevel.active => l10n.commonActivityDescActive,
        ActivityLevel.athlete => l10n.commonActivityDescAthlete,
      };
}

/// Ernährungspräferenz des Users. Steuert, welche Rezepte Eatova aktiv
/// empfiehlt (Rezept-Empfehlungen + „Passt zu deinem Ziel"). Default [none]
/// empfiehlt alles, damit Bestands-Profile und Tests unverändert bleiben.
/// Keine medizinische Allergie-Garantie — eine Empfehlungs-Filterung, der User
/// kann über den Kategorie-Filter weiterhin jedes Rezept manuell durchsuchen.
enum DietPreference { none, vegetarian, vegan, pescetarian }

extension DietPreferenceInfo on DietPreference {
  String label(AppLocalizations l10n) => switch (this) {
        DietPreference.none => l10n.commonDietLabelNone,
        DietPreference.vegetarian => l10n.commonDietLabelVegetarian,
        DietPreference.vegan => l10n.commonDietLabelVegan,
        DietPreference.pescetarian => l10n.commonDietLabelPescetarian,
      };

  String description(AppLocalizations l10n) => switch (this) {
        DietPreference.none => l10n.commonDietDescNone,
        DietPreference.vegetarian => l10n.commonDietDescVegetarian,
        DietPreference.vegan => l10n.commonDietDescVegan,
        DietPreference.pescetarian => l10n.commonDietDescPescetarian,
      };
}

/// Energiegehalt von einem Kilogramm Körpermasse (Faustregel nach Wishnofsky).
///
/// **Einzige Quelle** für die Umrechnung kcal ↔ kg im Projekt: sowohl
/// [WeightGoalInfo.weeklyRateKg] (das *versprochene* Tempo) als auch
/// `KcalTargets.effectiveWeeklyRateKg` (das *tatsächlich erreichbare*) rechnen
/// hierüber. Zwei verschiedene Zahlen an zwei Stellen waren genau der Kern von
/// B2 (docs/REVIEW-2026-08-08.md).
const int kcalPerKgBodyMass = 7700;

/// Unterhalb dieser Wochenrate ist eine Differenz reines Rundungsrauschen.
///
/// `KcalCalculator` rundet das Tagesziel auf 50 kcal — das verschiebt die
/// Rate um bis zu 25 kcal/Tag ≙ 0,023 kg/Woche. 0,05 kg/Woche (≙ 55 kcal/Tag)
/// liegt sicher darüber und zugleich weit unter dem kleinsten echten Tempo
/// ([WeightGoal.lose025kg] = 0,25 kg/Woche). Wird für drei Entscheidungen
/// benutzt: „Gewicht stabil"-Label, „Versprechen gehalten?" und „Prognose
/// überhaupt sinnvoll?".
const double weeklyRateNoiseKg = 0.05;

/// Gewichtsziel des Users — als wöchentliche Rate gedacht (kg/Woche). Bestimmt
/// den kcal-Auf-/Abschlag auf den Erhaltungsbedarf (BMR × Aktivitäts-PAL).
/// Schritte werden davon getrennt als "Verbrannt" angerechnet — siehe
/// [KcalCalculator]. Annahme: ~7700 kcal pro kg → 1100 kcal/Tag ≙ 1 kg/Woche.
///
/// **Achtung:** Das hier ist der *Wunsch*. Ob er erreichbar ist, entscheidet
/// erst `KcalCalculator.calculate` — die Sicherheitsgrenze von 1200 kcal kappt
/// das Defizit für die Mehrheit der sitzenden Nutzer. Für alles, was dem
/// Nutzer ein Tempo oder einen Zeitraum *anzeigt*, ist
/// `KcalTargets.effectiveWeeklyRateKg` die richtige Größe, nicht [kcalDelta].
enum WeightGoal {
  lose1kg,
  lose075kg,
  lose05kg,
  lose025kg,
  maintain,
  gain025kg,
  gain05kg,
}

/// Abnehm-Tempi von sanft bis ambitioniert (für Picker-Reihenfolge).
const List<WeightGoal> lossPaceGoals = <WeightGoal>[
  WeightGoal.lose025kg,
  WeightGoal.lose05kg,
  WeightGoal.lose075kg,
  WeightGoal.lose1kg,
];

/// Zunehm-Tempi von sanft bis ambitioniert.
const List<WeightGoal> gainPaceGoals = <WeightGoal>[
  WeightGoal.gain025kg,
  WeightGoal.gain05kg,
];

extension WeightGoalInfo on WeightGoal {
  /// kcal-Delta auf den Erhaltungsbedarf (1100 kcal/Tag ≙ 1 kg/Woche).
  int get kcalDelta => switch (this) {
        WeightGoal.lose1kg => -1100,
        WeightGoal.lose075kg => -825,
        WeightGoal.lose05kg => -550,
        WeightGoal.lose025kg => -275,
        WeightGoal.maintain => 0,
        WeightGoal.gain025kg => 275,
        WeightGoal.gain05kg => 550,
      };

  bool get isLoss => kcalDelta < 0;
  bool get isGain => kcalDelta > 0;

  /// Wöchentliche kg-Veränderung (≈ 7700 kcal pro kg). Vorzeichenlos.
  double get weeklyRateKg => kcalDelta.abs() * 7 / kcalPerKgBodyMass;

  /// Dieselbe Rate mit Vorzeichen: negativ beim Abnehmen, positiv beim
  /// Zunehmen. Gegenstück zu `KcalTargets.effectiveWeeklyRateKg`, damit sich
  /// Versprechen und Wirklichkeit direkt vergleichen lassen.
  double get signedWeeklyRateKg => kcalDelta * 7 / kcalPerKgBodyMass;

  /// Richtungs-Label ohne Tempo, sprachaktiv ueber die ARB (Paket 6,
  /// 2026-08-10) — s. [BiologicalSexLabel.label].
  String label(AppLocalizations l10n) {
    if (kcalDelta == 0) return l10n.commonWeightGoalLabelMaintain;
    return isGain ? l10n.commonWeightGoalLabelGain : l10n.commonWeightGoalLabelLose;
  }

  /// Vorzeichenbehaftetes Tempo, z.B. "−1 kg/Woche", "+0,5 kg/Woche".
  ///
  /// Das ist das **gewählte** Tempo — für Picker und Menüs richtig. Wo ein
  /// konkretes Profil im Spiel ist (Plan-Karten, Zusammenfassungen), gehört
  /// `KcalTargets.effectivePaceLabel` hin: nur das kennt die
  /// Sicherheitsgrenze.
  ///
  /// Seit der i18n-Migration (Paket 7, 2026-08-11) l10n-faehig — gemeinsam mit
  /// `paceLabelForWeeklyRateKg` und `KcalTargets.effectivePaceLabel`/
  /// `.paceWarning`, die denselben Weg gehen (B2-Kopplung, s. Paket-6-Bericht):
  /// [l10n] optional, Default Deutsch ([deL10n]), damit
  /// `test/services/kcal_effective_pace_test.dart` als kontextfreie Test-API
  /// weiterlaeuft (Regel 1, docs/I18N_PAKETE.md). Aus einem Getter wurde
  /// dafuer eine Methode — Dart-Getter koennen keine Parameter tragen.
  String paceLabel([AppLocalizations? l10n]) =>
      paceLabelForWeeklyRateKg(signedWeeklyRateKg, l10n);

  /// Kombiniertes Menü-Label, z.B. "Abnehmen · −1 kg/Woche".
  String menuLabel(AppLocalizations l10n) => kcalDelta == 0
      ? l10n.commonWeightGoalLabelMaintain
      : '${label(l10n)} · ${paceLabel(l10n)}';

  /// Vorzeichenbehaftetes Delta-Label, z.B. "−1100 kcal" / "±0".
  String get deltaLabel {
    if (kcalDelta == 0) return '±0';
    final sign = kcalDelta > 0 ? '+' : '−';
    return '$sign${kcalDelta.abs()} kcal';
  }
}

/// Label für eine **tatsächliche** Wochenrate (vorzeichenbehaftet, negativ =
/// abnehmen), z.B. −0,7545 → "−0,75 kg/Woche".
///
/// Die Zahl wird auf das 0,05-Raster gerundet ([_formatRateKg]): die
/// 50er-Rundung des Tagesziels verschiebt die Rate um bis zu ±0,023 kg/Woche,
/// und „−0,48 kg/Woche" für ein gewähltes „−0,5" wäre falsche Präzision bei
/// einer Formel mit ±10 % Unschärfe (Kalorien-Review 2026-08-21).
///
/// Alles unterhalb von [weeklyRateNoiseKg] heißt "Gewicht stabil" — sonst
/// würde die 50er-Rundung des Tagesziels beim Ziel „halten" ein Tempo von
/// "+0 kg/Woche" ausweisen. Nicht-endliche Werte können hier nicht ankommen
/// (die Rate entsteht aus zwei Ganzzahlen), werden aber trotzdem abgefangen,
/// damit kein "NaN kg/Woche" in ein Widget gelangt.
///
/// [l10n] ist optional (Default Deutsch, [deL10n]) — dasselbe Muster wie
/// Paket 6s `sync_error_messages.dart`. Seit dem Nachzieh-Fix (Paket 7,
/// 2026-08-11) folgt auch die Zahl selbst ([_formatRateKg]) der Sprache:
/// ein englisches "−0.5 kg/week" mit deutschem Komma ("−0,5") war dieselbe
/// Leck-Klasse wie der Text drumherum, nur eine Ebene tiefer.
String paceLabelForWeeklyRateKg(double signedRateKg, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  if (!signedRateKg.isFinite || signedRateKg.abs() < weeklyRateNoiseKg) {
    return t.commonPaceStable;
  }
  final sign = signedRateKg > 0 ? '+' : '−';
  return t.commonPaceRateLabel(
    '$sign${_formatRateKg(signedRateKg.abs(), t.localeName)}',
  );
}

/// Formatiert eine kg-Rate auf das 0,05-Raster, locale-bewusst: unter `de`
/// 1.0 → "1", 0.5 → "0,5", 0.75 → "0,75", 0.4818 → "0,5", 0.7545 → "0,75",
/// 0.118 → "0,1"; unter `en` dieselben Werte mit Punkt statt Komma ("0.5"
/// usw.).
///
/// Erwartet einen vorzeichenlosen Wert; das Vorzeichen setzt der Aufrufer.
/// Erst runden, dann formatieren: [NumberFormat]s eigene Rundung auf der
/// UNGERUNDETEN Rate könnte anders runden als das explizite
/// `(kg * 20).round() / 20` — deshalb bleibt der Rundungsschritt in eigener
/// Hand, [NumberFormat] übernimmt nur noch die Anzeige (Trennzeichen,
/// Nachkommastellen kappen) des bereits gerundeten Werts. 0,05 ist zugleich
/// [weeklyRateNoiseKg]: was als „Versprechen gehalten" gilt, zeigt auch
/// dieselbe Zahl.
String _formatRateKg(double kg, String localeName) {
  final gerundet = (kg.abs() * 20).round() / 20;
  return NumberFormat('0.##', localeName).format(gerundet);
}

class UserProfile {
  const UserProfile({
    this.weightKg = 78,
    this.heightCm = 178,
    this.ageYears = 30,
    this.sex = BiologicalSex.neutral,
    this.activityLevel = ActivityLevel.sedentary,
    this.targetWeightKg = 78,
    this.dailyStepsGoal = 8000,
    this.dailyKcalGoal = 2200,
    this.dailyWaterGoalMl = 2500,
    this.dailySleepGoalMinutes = 7 * 60 + 30,
    this.proteinGoalG = 130,
    this.carbsGoalG = 240,
    this.fatGoalG = 70,
    this.weightGoal = WeightGoal.maintain,
    this.diet = DietPreference.none,
    this.onboardingCompleted = false,
  });

  final int weightKg;
  final int heightCm;
  final int ageYears;
  final BiologicalSex sex;

  /// Beruf/Alltag für den Erhaltungsbedarf (PAL). Default sitzend (1,4) —
  /// die konservativste Stufe, die Leitlinien für freilebende Erwachsene
  /// kennen; „im Zweifel eine Stufe tiefer" gilt auch hier.
  final ActivityLevel activityLevel;

  /// Wunschgewicht. Treibt nur die Zeit-Prognose (Wochen bis Ziel), nicht das
  /// Tagesziel selbst — das hängt am gewählten Tempo ([weightGoal]).
  final int targetWeightKg;

  final int dailyStepsGoal;
  final int dailyKcalGoal;
  final int dailyWaterGoalMl;
  final int dailySleepGoalMinutes;
  final int proteinGoalG;
  final int carbsGoalG;
  final int fatGoalG;
  final WeightGoal weightGoal;

  /// Ernährungspräferenz für die Rezept-Empfehlung. Default [DietPreference.none]
  /// (alles). Gespiegelt nach public.profiles.diet_preference.
  final DietPreference diet;

  /// True sobald der User das verpflichtende Onboarding durchlaufen hat.
  /// Steuert das Gate in [EatovaHomePage] — gespiegelt nach
  /// public.profiles.onboarding_completed.
  final bool onboardingCompleted;

  UserProfile copyWith({
    int? weightKg,
    int? heightCm,
    int? ageYears,
    BiologicalSex? sex,
    ActivityLevel? activityLevel,
    int? targetWeightKg,
    int? dailyStepsGoal,
    int? dailyKcalGoal,
    int? dailyWaterGoalMl,
    int? dailySleepGoalMinutes,
    int? proteinGoalG,
    int? carbsGoalG,
    int? fatGoalG,
    WeightGoal? weightGoal,
    DietPreference? diet,
    bool? onboardingCompleted,
  }) {
    return UserProfile(
      weightKg: weightKg ?? this.weightKg,
      heightCm: heightCm ?? this.heightCm,
      ageYears: ageYears ?? this.ageYears,
      sex: sex ?? this.sex,
      activityLevel: activityLevel ?? this.activityLevel,
      targetWeightKg: targetWeightKg ?? this.targetWeightKg,
      dailyStepsGoal: dailyStepsGoal ?? this.dailyStepsGoal,
      dailyKcalGoal: dailyKcalGoal ?? this.dailyKcalGoal,
      dailyWaterGoalMl: dailyWaterGoalMl ?? this.dailyWaterGoalMl,
      dailySleepGoalMinutes:
          dailySleepGoalMinutes ?? this.dailySleepGoalMinutes,
      proteinGoalG: proteinGoalG ?? this.proteinGoalG,
      carbsGoalG: carbsGoalG ?? this.carbsGoalG,
      fatGoalG: fatGoalG ?? this.fatGoalG,
      weightGoal: weightGoal ?? this.weightGoal,
      diet: diet ?? this.diet,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    );
  }
}
