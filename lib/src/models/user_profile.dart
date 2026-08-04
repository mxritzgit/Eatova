enum BiologicalSex { male, female, neutral }

extension BiologicalSexLabel on BiologicalSex {
  String get label => switch (this) {
        BiologicalSex.male => 'männlich',
        BiologicalSex.female => 'weiblich',
        BiologicalSex.neutral => 'neutral',
      };
}

/// Alltags-Aktivität ohne gezähltes Training. Multipliziert den Grundumsatz
/// (BMR) zum Erhaltungsbedarf (TDEE) — die etablierten PAL-Faktoren. Schritte
/// werden zusätzlich getrennt als „Verbrannt" angerechnet, deshalb ist hier
/// bewusst der Alltags-Anteil gemeint, nicht das geplante Workout.
enum ActivityLevel { sedentary, light, moderate, active, athlete }

extension ActivityLevelInfo on ActivityLevel {
  /// Physical Activity Level (PAL) — Multiplikator auf den BMR.
  double get palFactor => switch (this) {
        ActivityLevel.sedentary => 1.2,
        ActivityLevel.light => 1.375,
        ActivityLevel.moderate => 1.55,
        ActivityLevel.active => 1.725,
        ActivityLevel.athlete => 1.9,
      };

  String get label => switch (this) {
        ActivityLevel.sedentary => 'Kaum aktiv',
        ActivityLevel.light => 'Leicht aktiv',
        ActivityLevel.moderate => 'Mäßig aktiv',
        ActivityLevel.active => 'Sehr aktiv',
        ActivityLevel.athlete => 'Extrem aktiv',
      };

  String get description => switch (this) {
        ActivityLevel.sedentary => 'Bürojob, wenig Bewegung',
        ActivityLevel.light => 'Leichte Bewegung, 1–2× Sport/Woche',
        ActivityLevel.moderate => 'Aktiver Alltag, 3–5× Sport/Woche',
        ActivityLevel.active => 'Täglich aktiv, 6–7× Sport/Woche',
        ActivityLevel.athlete => 'Körperliche Arbeit + tägl. Training',
      };
}

/// Ernährungspräferenz des Users. Steuert, welche Rezepte Eatova aktiv
/// empfiehlt (Rezept-Empfehlungen + „Passt zu deinem Ziel"). Default [none]
/// empfiehlt alles, damit Bestands-Profile und Tests unverändert bleiben.
/// Keine medizinische Allergie-Garantie — eine Empfehlungs-Filterung, der User
/// kann über den Kategorie-Filter weiterhin jedes Rezept manuell durchsuchen.
enum DietPreference { none, vegetarian, vegan, pescetarian }

extension DietPreferenceInfo on DietPreference {
  String get label => switch (this) {
        DietPreference.none => 'Alles',
        DietPreference.vegetarian => 'Vegetarisch',
        DietPreference.vegan => 'Vegan',
        DietPreference.pescetarian => 'Pescetarisch',
      };

  String get description => switch (this) {
        DietPreference.none => 'Keine Einschränkung',
        DietPreference.vegetarian => 'Kein Fleisch, kein Fisch',
        DietPreference.vegan => 'Rein pflanzlich',
        DietPreference.pescetarian => 'Vegetarisch plus Fisch',
      };
}

/// Gewichtsziel des Users — als wöchentliche Rate gedacht (kg/Woche). Bestimmt
/// den kcal-Auf-/Abschlag auf den Erhaltungsbedarf (BMR × Aktivitäts-PAL).
/// Schritte werden davon getrennt als "Verbrannt" angerechnet — siehe
/// [KcalCalculator]. Annahme: ~7700 kcal pro kg → 1100 kcal/Tag ≙ 1 kg/Woche.
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
  double get weeklyRateKg => kcalDelta.abs() * 7 / 7700;

  /// Richtungs-Label ohne Tempo.
  String get label {
    if (kcalDelta == 0) return 'Gewicht halten';
    return isGain ? 'Zunehmen' : 'Abnehmen';
  }

  /// Vorzeichenbehaftetes Tempo, z.B. "−1 kg/Woche", "+0,5 kg/Woche".
  String get paceLabel {
    if (kcalDelta == 0) return 'Gewicht stabil';
    final sign = isGain ? '+' : '−';
    return '$sign${_formatRateKg(weeklyRateKg)} kg/Woche';
  }

  /// Kombiniertes Menü-Label, z.B. "Abnehmen · −1 kg/Woche".
  String get menuLabel =>
      kcalDelta == 0 ? 'Gewicht halten' : '$label · $paceLabel';

  /// Vorzeichenbehaftetes Delta-Label, z.B. "−1100 kcal" / "±0".
  String get deltaLabel {
    if (kcalDelta == 0) return '±0';
    final sign = kcalDelta > 0 ? '+' : '−';
    return '$sign${kcalDelta.abs()} kcal';
  }
}

/// Formatiert eine kg-Rate deutsch: 1.0 → "1", 0.5 → "0,5", 0.75 → "0,75".
String _formatRateKg(double kg) {
  if (kg == kg.roundToDouble()) return kg.toStringAsFixed(0);
  return kg
      .toStringAsFixed(2)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll('.', ',');
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

  /// Alltags-Aktivität für den Erhaltungsbedarf (PAL). Default sedentär (1.2),
  /// damit Bestands-Berechnungen unverändert bleiben.
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
