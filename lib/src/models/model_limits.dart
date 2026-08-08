/// Grenzwerte der PostgreSQL-Check-Constraints als Client-Konstanten.
///
/// ## Warum es diese Datei gibt
///
/// Jede Spalte in Supabase, die der Nutzer beeinflussen kann, traegt eine
/// `check`-Constraint — der Client validierte bisher nichts davon.
/// `FilteringTextInputFormatter.digitsOnly` ist ein **Typ**-Guard, kein
/// **Wertebereichs**-Guard, und das wurde ueberall verwechselt ausser bei
/// `age_years` (docs/REVIEW-2026-08-08.md, Kapitel I).
///
/// Konkret: Wer "75,5" in ein Gewichtsfeld tippt, verliert das Komma und
/// schickt 755 kg an die DB. Ergebnis ist PostgreSQL-Fehler `23514`, und der
/// Outbox-Sync verwarf diese Ops bislang sofort — reproduzierbar, nicht
/// zuordenbar, ohne Korrekturfenster fuer den Nutzer.
///
/// ## Clamp oder Ablehnung?
///
/// Beides ist hier vorhanden, und die Wahl ist bewusst zu treffen:
///
/// * **Ablehnen** (`isValid…`) bei allem, was der Nutzer **selbst tippt**:
///   Gewicht, Groesse, Alter, Wunschgewicht, Tagesziele, manuell korrigierte
///   Kalorien/Gramm. 755 kg auf 300 kg zu klemmen ist eine *stille
///   Verfaelschung* — der Nutzer wollte 75,5 kg und bekaeme 300 kg ins Profil
///   geschrieben, ohne es zu merken. Solche Eingaben gehoeren mit einer
///   Feldfehlermeldung zurueckgewiesen.
///
/// * **Klemmen** (`clamp…`) bei allem, was aus einer **fremden Quelle** kommt
///   und wo es keinen Menschen gibt, den man fragen koennte: Modellantworten
///   der Meal-Scan-Function, Open-Food-Facts-Felder, abgeleitete Werte aus
///   Skalierungen (`adjustedToGrams`), Rezept-Konvertierungen. Hier ist ein
///   geklemmter Wert besser als ein verworfener Schreibvorgang.
///
/// * **Texte werden immer gekuerzt, nie abgelehnt.** Ein 300 Zeichen langes
///   OFF-Etikett ist echte Produktinformation; sie auf 160 zu kuerzen verliert
///   nichts Entscheidendes. Einzige Ausnahme: `meal_name` und `favorite_key`
///   haben eine **Mindest**laenge von 1 — der leere String ist eine
///   `23514`-Verletzung, kein harmloser Default. Dafuer gibt es
///   [isValidMealName] bzw. [isValidFavoriteKey].
///
/// * Die Clamps gehoeren an die **Modellgrenze**, eine Stelle pro Datenquelle
///   (`MealAnalysisResult.fromOpenFoodFacts`, `adjustedToGrams`,
///   `FitnessRecipe.toMealResult`, `KcalCalculator.calculate`,
///   `_buildProfile()`), nicht in jedes Widget. Feldvalidierung obendrauf ist
///   UX, nicht Sicherheit.
///
/// ## DB-Grenze vs. Plausibilitaetsgrenze
///
/// Beides wird getrennt gefuehrt. [LoggedMealLimits] & Co. bilden exakt ab,
/// was die DB akzeptiert; [PlausibilityLimits] bildet ab, was physikalisch
/// sinnvoll ist. Beispiel: die DB kennt gar keine Spalte fuer kcal/100 g
/// (das Feld lebt im `payload`-JSON), aber ueber 900 kcal/100 g ist
/// unmoeglich — das ist reines Fett. OFF liefert dort regelmaessig die
/// kJ-Zahl. Der Aufrufer waehlt bewusst, gegen welche der beiden Grenzen er
/// prueft.
///
/// ## Nicht-endliche Zahlen
///
/// `double.nan` bedeutet "kein Wert" und ist fuer **jede** [isValid]-Funktion
/// ungueltig. Die `clamp…`-Funktionen liefern dafuer den `fallback`, der
/// standardmaessig die **Untergrenze** ist. Genau daraus entstand B1
/// (0 kcal statt "unbekannt") — wer einen anderen Ersatzwert braucht, muss
/// ihn explizit uebergeben. `infinity` clampt auf die Obergrenze,
/// `-infinity` auf die Untergrenze; keine Funktion in dieser Datei wirft.
///
/// Die Datei ist bewusst **abhaengigkeitsfrei** (kein Flutter-, kein
/// Paket-Import), damit sie aus Modellen, Services und Tests gleichermassen
/// nutzbar ist.
library;

// ---------------------------------------------------------------------------
// profiles
// ---------------------------------------------------------------------------

/// Grenzen der Tabelle `public.profiles`.
abstract final class ProfileLimits {
  // profiles_biometrics_range_check
  // Quelle: supabase/migrations/20260807090000_profiles_age_minimum_16.sql
  //   check (weight_kg between 30 and 300 and
  //          height_cm between 100 and 250 and
  //          age_years between 16 and 100)
  // Diese Migration ERSETZT die Fassung aus 20260517220000_security_hardening.sql
  // (dort noch age_years between 13 and 100). Es zaehlt der Endzustand.

  /// `weight_kg` ist eine `integer`-Spalte — Nachkommastellen gibt es nicht.
  static const int weightKgMin = 30;
  static const int weightKgMax = 300;

  static const int heightCmMin = 100;
  static const int heightCmMax = 250;

  /// Mindestalter 16 wegen Art. 8 DSGVO (Gesundheitsdaten, Art. 9).
  static const int ageYearsMin = 16;
  static const int ageYearsMax = 100;

  // profiles_target_weight_range_check
  // Quelle: supabase/migrations/20260523000000_onboarding_fields.sql
  //   check (target_weight_kg between 30 and 300)
  static const int targetWeightKgMin = 30;
  static const int targetWeightKgMax = 300;

  // profiles_goals_range_check
  // Quelle: supabase/migrations/20260517220000_security_hardening.sql
  static const int dailyStepsGoalMin = 1000;
  static const int dailyStepsGoalMax = 100000;

  static const int dailyKcalGoalMin = 800;
  static const int dailyKcalGoalMax = 7000;

  static const int dailyWaterGoalMlMin = 500;
  static const int dailyWaterGoalMlMax = 12000;

  static const int dailySleepGoalMinutesMin = 180;
  static const int dailySleepGoalMinutesMax = 900;

  /// Makro-Tagesziele. Das sind die Grenzen, die `KcalCalculator.calculate`
  /// treffen muss — nicht die 0..1000 der Mahlzeiten-Makros.
  static const int proteinGoalGMin = 0;
  static const int proteinGoalGMax = 400;

  static const int carbsGoalGMin = 0;
  static const int carbsGoalGMax = 800;

  static const int fatGoalGMin = 0;
  static const int fatGoalGMax = 300;

  // profiles_display_name_length_check / profiles_avatar_url_length_check
  // Quelle: supabase/migrations/20260517220000_security_hardening.sql
  //   check (char_length(display_name) <= 80)
  //   check (avatar_url is null or char_length(avatar_url) <= 2048)
  static const int displayNameMaxChars = 80;
  static const int avatarUrlMaxChars = 2048;

  // profiles_sex_check
  // Quelle: supabase/migrations/20260516160000_app_data_schema.sql
  static const Set<String> sexValues = {'male', 'female', 'neutral'};

  // profiles_activity_level_check
  // Quelle: supabase/migrations/20260523000000_onboarding_fields.sql
  static const Set<String> activityLevelValues = {
    'sedentary',
    'light',
    'moderate',
    'active',
    'athlete',
  };

  // profiles_weight_goal_check
  // Quelle: supabase/migrations/20260602120000_profiles_weight_goal.sql
  static const Set<String> weightGoalValues = {
    'lose1kg',
    'lose075kg',
    'lose05kg',
    'lose025kg',
    'maintain',
    'gain025kg',
    'gain05kg',
  };

  // profiles_diet_preference_check
  // Quelle: supabase/migrations/20260604140000_profiles_diet_preference.sql
  static const Set<String> dietPreferenceValues = {
    'none',
    'vegetarian',
    'vegan',
    'pescetarian',
  };
}

// ---------------------------------------------------------------------------
// logged_meals
// ---------------------------------------------------------------------------

/// Grenzen der Tabelle `public.logged_meals`.
///
/// Quelle der Bereiche: `logged_meals_safe_ranges_check` in
/// supabase/migrations/20260517220000_security_hardening.sql.
abstract final class LoggedMealLimits {
  //   char_length(meal_name) between 1 and 160
  /// Der leere Name ist eine Constraint-Verletzung, kein Default.
  static const int mealNameMinChars = 1;
  static const int mealNameMaxChars = 160;

  //   calories_kcal between 0 and 10000
  static const int caloriesKcalMin = 0;
  static const int caloriesKcalMax = 10000;

  //   estimated_g between 0 and 10000
  static const int estimatedGMin = 0;
  static const int estimatedGMax = 10000;

  //   (protein_g is null or protein_g between 0 and 1000)
  //   (carbs_g   is null or carbs_g   between 0 and 1000)
  //   (fat_g     is null or fat_g     between 0 and 1000)
  /// Gilt identisch fuer `protein_g`, `carbs_g` und `fat_g`. Die Spalten sind
  /// `numeric` (nullable) — daher `double`, nicht `int`.
  static const double macroGMin = 0;
  static const double macroGMax = 1000;

  //   (barcode      is null or char_length(barcode)      <= 64)
  //   (brand        is null or char_length(brand)        <= 120)
  //   (source_label is null or char_length(source_label) <= 80)
  static const int barcodeMaxChars = 64;
  static const int brandMaxChars = 120;
  static const int sourceLabelMaxChars = 80;

  //   octet_length(payload::text) <= 200000
  /// **Bytes**, nicht Zeichen — `octet_length` auf dem JSON-Text.
  static const int payloadMaxBytes = 200000;

  // Spalten-Constraint aus supabase/migrations/20260516160000_app_data_schema.sql:
  //   forced_slot text check (forced_slot in ('breakfast','lunch','dinner','snack'))
  /// `null` ist erlaubt (die Spalte ist nullable).
  static const Set<String> forcedSlotValues = {
    'breakfast',
    'lunch',
    'dinner',
    'snack',
  };
}

// ---------------------------------------------------------------------------
// favorite_meals
// ---------------------------------------------------------------------------

/// Grenzen der Tabelle `public.favorite_meals`.
///
/// Quelle: `favorite_meals_safe_ranges_check` in
/// supabase/migrations/20260517220000_security_hardening.sql.
abstract final class FavoriteMealLimits {
  //   char_length(favorite_key) between 1 and 180
  /// `favorite_key` ist Teil des Primaerschluessels (`barcode:…` / `name:…`).
  /// Kuerzen muss deshalb schon bei der **Schluesselbildung** passieren
  /// (`FavoriteMeal.idFor`), nicht erst beim Schreiben — sonst zeigen lokaler
  /// Cache und Serverzeile auf verschiedene Schluessel.
  static const int favoriteKeyMinChars = 1;
  static const int favoriteKeyMaxChars = 180;

  static const int mealNameMinChars = 1;
  static const int mealNameMaxChars = 160;

  static const int caloriesKcalMin = 0;
  static const int caloriesKcalMax = 10000;

  static const int estimatedGMin = 0;
  static const int estimatedGMax = 10000;

  static const int barcodeMaxChars = 64;
  static const int brandMaxChars = 120;
  static const int sourceLabelMaxChars = 80;
  static const int payloadMaxBytes = 200000;

  /// `favorite_meals` hat **keine** Makro-Spalten (die Tabellendefinition in
  /// 20260516160000_app_data_schema.sql kennt nur `calories_kcal` und
  /// `estimated_g`); Makros liegen ausschliesslich im `payload`-JSON. Wer
  /// Makros klemmen will, nimmt die Grenzen von [LoggedMealLimits].
  static const bool hasMacroColumns = false;
}

// ---------------------------------------------------------------------------
// weight_log
// ---------------------------------------------------------------------------

/// Grenzen der Tabelle `public.weight_log`.
abstract final class WeightLogLimits {
  // Zwei Constraints wirken gleichzeitig, die engere gewinnt:
  //   * check (weight_kg > 0)
  //     — supabase/migrations/20260516160000_app_data_schema.sql
  //   * weight_log_safe_range_check: check (weight_kg between 20 and 400)
  //     — supabase/migrations/20260517220000_security_hardening.sql
  //
  // ACHTUNG: bewusst weiter als profiles.weight_kg (30..300). Ein Messpunkt
  // im Gewichtsverlauf darf ausserhalb des Profilbereichs liegen.
  static const double weightKgMin = 20;
  static const double weightKgMax = 400;

  /// Spaltentyp `numeric(5,2)` — zwei Nachkommastellen, Maximum 999.99
  /// (die Check-Constraint ist mit 400 die engere Grenze).
  /// Quelle: supabase/migrations/20260516160000_app_data_schema.sql
  static const int weightKgDecimals = 2;
}

// ---------------------------------------------------------------------------
// user_recipes
// ---------------------------------------------------------------------------

/// Grenzen der Tabelle `public.user_recipes`.
///
/// Quelle: supabase/migrations/20260530091000_user_recipes.sql
///   check (calories_kcal >= 0), (protein_g >= 0), (carbs_g >= 0),
///   (fat_g >= 0), (estimated_g >= 0)
abstract final class UserRecipeLimits {
  static const int caloriesKcalMin = 0;
  static const int proteinGMin = 0;
  static const int carbsGMin = 0;
  static const int fatGMin = 0;
  static const int estimatedGMin = 0;

  /// Die Tabelle kennt **keine** Obergrenzen — nur `>= 0`. Faktische Grenze
  /// ist der `integer`-Typ (2 147 483 647). Sobald ein Rezept als Mahlzeit
  /// geloggt wird, gelten die deutlich strengeren [LoggedMealLimits]; die
  /// sind beim Konvertieren (`FitnessRecipe.toMealResult`) anzuwenden.
  static const bool hasDbUpperBound = false;
}

// ---------------------------------------------------------------------------
// Plausibilitaet — bewusst KEINE DB-Entsprechung
// ---------------------------------------------------------------------------

/// Grenzen, die die Datenbank **nicht** kennt, die aber physikalisch bzw.
/// fachlich gelten. Sie sind strenger als die DB-Grenzen und dienen dazu,
/// offensichtlichen Datenmuell aus fremden Quellen zu erkennen.
abstract final class PlausibilityLimits {
  /// Reines Fett hat ~900 kcal/100 g — mehr ist unmoeglich.
  ///
  /// Open Food Facts liefert in `energy-kcal_100g` regelmaessig die
  /// **kJ**-Zahl (2180 statt 521 kcal). Es gibt keine DB-Spalte dafuer, das
  /// Feld lebt im `payload`-JSON — die Pruefung muss also der Client machen.
  /// Quelle: docs/REVIEW-2026-08-08.md, B7.
  static const double kcalPer100GMin = 0;
  static const double kcalPer100GMax = 900;

  /// Eine Portion von 0 g ist von der DB erlaubt (`estimated_g >= 0`), aber
  /// als Mahlzeit sinnlos — und sie fuehrt in `adjustedToGrams` zur
  /// Division durch die Ursprungsportion.
  static const int portionGramsMin = 1;
  static const int portionGramsMax = LoggedMealLimits.estimatedGMax;

  /// Umrechnungsfaktor kJ -> kcal, fuer den fehlenden OFF-Fallback.
  static const double kjPerKcal = 4.184;
}

// ---------------------------------------------------------------------------
// Interne Helfer
// ---------------------------------------------------------------------------

int _clampInt(num value, int min, int max, int? fallback) {
  if (value.isNaN) return _clampInt(fallback ?? min, min, max, min);
  // Der Vergleich vor dem Runden ist Absicht: `.round()` auf einem sehr
  // grossen double (1e300) laeuft sonst aus dem int64-Bereich.
  if (value <= min) return min;
  if (value >= max) return max;
  return value.round();
}

double _clampDouble(num value, double min, double max, double? fallback) {
  if (value.isNaN) return _clampDouble(fallback ?? min, min, max, min);
  if (value <= min) return min;
  if (value >= max) return max;
  return value.toDouble();
}

bool _isWithin(num value, num min, num max) {
  if (value.isNaN || value.isInfinite) return false;
  return value >= min && value <= max;
}

// ---------------------------------------------------------------------------
// Text: Laenge und Kuerzen
// ---------------------------------------------------------------------------

/// Zeichenzahl nach PostgreSQL-Semantik: `char_length()` zaehlt **Code
/// Points**, `String.length` in Dart dagegen UTF-16-Code-Units.
///
/// Fuer `'🥗'` liefert Postgres 1, Dart 2. Wer gegen eine
/// `char_length`-Constraint prueft, muss deshalb hierueber gehen.
int charLength(String value) => value.runes.length;

/// Kuerzt [value] auf hoechstens [maxChars] **Code Points**.
///
/// Der Schnitt erfolgt an Runengrenzen: `substring(0, 160)` wuerde ein
/// Emoji, das genau ueber der Grenze liegt, zwischen High- und
/// Low-Surrogate zerteilen und einen String hinterlassen, der kein gueltiges
/// UTF-16 mehr ist (und den Postgres/JSON-Encoder zum Stolpern bringt).
///
/// Bekannte Grenze: zusammengesetzte Grapheme-Cluster (Familien-Emoji mit
/// Zero-Width-Joiner, Flaggen, Hautton-Modifier) koennen an einer Runengrenze
/// auseinanderfallen. Das Ergebnis bleibt gueltiges UTF-16 und
/// constraint-konform — es kann nur anders aussehen als erwartet. Fuer
/// Grapheme-Cluster-Treue braeuchte es `package:characters`; diese Datei
/// bleibt bewusst abhaengigkeitsfrei.
String truncateToChars(String value, int maxChars) {
  if (maxChars <= 0) return '';
  if (value.length <= maxChars) return value; // schneller Pfad: reines ASCII
  final runes = value.runes.toList(growable: false);
  if (runes.length <= maxChars) return value;
  return String.fromCharCodes(runes.take(maxChars));
}

// ---------------------------------------------------------------------------
// Text-Clamps (Kuerzen) und Text-Pruefungen
// ---------------------------------------------------------------------------

const String _mealNameFallback = 'Mahlzeit';
const String _favoriteKeyFallback = 'name:mahlzeit';

/// Macht [value] fuer `meal_name` schreibbar: trimmen, leere Namen durch
/// [fallback] ersetzen (die Constraint verlangt mindestens 1 Zeichen) und auf
/// 160 Code Points kuerzen.
String clampMealName(String value, {String fallback = _mealNameFallback}) {
  final getrimmt = value.trim();
  var basis = getrimmt.isEmpty ? fallback.trim() : getrimmt;
  if (basis.isEmpty) basis = _mealNameFallback;
  final gekuerzt = truncateToChars(basis, LoggedMealLimits.mealNameMaxChars).trimRight();
  return gekuerzt.isEmpty ? _mealNameFallback : gekuerzt;
}

/// `true`, wenn [value] die Constraint `char_length(meal_name) between 1 and
/// 160` erfuellt. Fuer Formulare: leere Namen gehoeren abgelehnt, zu lange
/// gekuerzt.
bool isValidMealName(String value) {
  final laenge = charLength(value.trim());
  return laenge >= LoggedMealLimits.mealNameMinChars &&
      laenge <= LoggedMealLimits.mealNameMaxChars;
}

/// Macht [value] fuer `favorite_key` schreibbar (1..180 Zeichen).
///
/// Siehe die Warnung an [FavoriteMealLimits.favoriteKeyMaxChars]: das gehoert
/// in die Schluesselbildung, nicht ans Schreiben.
String clampFavoriteKey(String value, {String fallback = _favoriteKeyFallback}) {
  final getrimmt = value.trim();
  var basis = getrimmt.isEmpty ? fallback.trim() : getrimmt;
  if (basis.isEmpty) basis = _favoriteKeyFallback;
  return truncateToChars(basis, FavoriteMealLimits.favoriteKeyMaxChars);
}

/// `true`, wenn [value] die Constraint `char_length(favorite_key) between 1
/// and 180` erfuellt.
bool isValidFavoriteKey(String value) {
  final laenge = charLength(value.trim());
  return laenge >= FavoriteMealLimits.favoriteKeyMinChars &&
      laenge <= FavoriteMealLimits.favoriteKeyMaxChars;
}

/// Kuerzt `brand` auf 120 Zeichen. `null` und leere/nur-Leerzeichen-Werte
/// werden zu `null` — die Spalte ist nullable, ein leerer Markenname traegt
/// keine Information.
String? clampBrand(String? value) =>
    _clampNullableText(value, LoggedMealLimits.brandMaxChars);

/// Kuerzt `barcode` auf 64 Zeichen (nullable).
String? clampBarcode(String? value) =>
    _clampNullableText(value, LoggedMealLimits.barcodeMaxChars);

/// Kuerzt `source_label` auf 80 Zeichen (nullable).
String? clampSourceLabel(String? value) =>
    _clampNullableText(value, LoggedMealLimits.sourceLabelMaxChars);

/// Kuerzt `avatar_url` auf 2048 Zeichen (nullable).
String? clampAvatarUrl(String? value) =>
    _clampNullableText(value, ProfileLimits.avatarUrlMaxChars);

/// Kuerzt `display_name` auf 80 Zeichen. Die Spalte ist `not null default ''`
/// und hat **keine** Mindestlaenge — der leere String bleibt daher erlaubt.
String clampDisplayName(String value) =>
    truncateToChars(value.trim(), ProfileLimits.displayNameMaxChars);

String? _clampNullableText(String? value, int maxChars) {
  if (value == null) return null;
  final getrimmt = value.trim();
  if (getrimmt.isEmpty) return null;
  return truncateToChars(getrimmt, maxChars);
}

// ---------------------------------------------------------------------------
// Zahl-Clamps: profiles
// ---------------------------------------------------------------------------

/// Klemmt auf `profiles.weight_kg` (30..300, ganzzahlig).
///
/// **Nur als letzte Bremse vor der DB benutzen.** Bei Nutzereingaben ist
/// [isValidProfileWeightKg] richtig: "75,5" wird durch `digitsOnly` zu 755,
/// und 755 auf 300 zu klemmen schreibt eine Zahl ins Profil, die der Nutzer
/// nie gemeint hat.
int clampProfileWeightKg(num value, {int? fallback}) =>
    _clampInt(value, ProfileLimits.weightKgMin, ProfileLimits.weightKgMax, fallback);

/// Klemmt auf `profiles.height_cm` (100..250).
int clampProfileHeightCm(num value, {int? fallback}) =>
    _clampInt(value, ProfileLimits.heightCmMin, ProfileLimits.heightCmMax, fallback);

/// Klemmt auf `profiles.age_years` (16..100).
int clampProfileAgeYears(num value, {int? fallback}) =>
    _clampInt(value, ProfileLimits.ageYearsMin, ProfileLimits.ageYearsMax, fallback);

/// Klemmt auf `profiles.target_weight_kg` (30..300).
int clampProfileTargetWeightKg(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.targetWeightKgMin,
  ProfileLimits.targetWeightKgMax,
  fallback,
);

/// Klemmt auf `profiles.daily_steps_goal` (1000..100000).
int clampDailyStepsGoal(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.dailyStepsGoalMin,
  ProfileLimits.dailyStepsGoalMax,
  fallback,
);

/// Klemmt auf `profiles.daily_kcal_goal` (800..7000).
int clampDailyKcalGoal(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.dailyKcalGoalMin,
  ProfileLimits.dailyKcalGoalMax,
  fallback,
);

/// Klemmt auf `profiles.daily_water_goal_ml` (500..12000).
int clampDailyWaterGoalMl(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.dailyWaterGoalMlMin,
  ProfileLimits.dailyWaterGoalMlMax,
  fallback,
);

/// Klemmt auf `profiles.daily_sleep_goal_minutes` (180..900).
int clampDailySleepGoalMinutes(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.dailySleepGoalMinutesMin,
  ProfileLimits.dailySleepGoalMinutesMax,
  fallback,
);

/// Klemmt auf `profiles.protein_goal_g` (0..400) — das `proteinG.clamp(0, 400)`
/// aus `KcalCalculator.calculate`.
int clampProteinGoalG(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.proteinGoalGMin,
  ProfileLimits.proteinGoalGMax,
  fallback,
);

/// Klemmt auf `profiles.carbs_goal_g` (0..800).
int clampCarbsGoalG(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.carbsGoalGMin,
  ProfileLimits.carbsGoalGMax,
  fallback,
);

/// Klemmt auf `profiles.fat_goal_g` (0..300) — das `fatG.clamp(0, 300)` aus
/// `KcalCalculator.calculate`.
int clampFatGoalG(num value, {int? fallback}) =>
    _clampInt(value, ProfileLimits.fatGoalGMin, ProfileLimits.fatGoalGMax, fallback);

// ---------------------------------------------------------------------------
// Zahl-Clamps: logged_meals / favorite_meals
// ---------------------------------------------------------------------------

/// Klemmt auf `calories_kcal` (0..10000). Gilt fuer `logged_meals` und
/// `favorite_meals` gleichermassen.
int clampMealCaloriesKcal(num value, {int? fallback}) => _clampInt(
  value,
  LoggedMealLimits.caloriesKcalMin,
  LoggedMealLimits.caloriesKcalMax,
  fallback,
);

/// Klemmt auf `estimated_g` (0..10000, DB-Grenze).
///
/// Fuer Portionsgroessen, die eine Mahlzeit beschreiben sollen, ist
/// [clampPortionGrams] (ab 1 g) die richtige Wahl.
int clampMealEstimatedG(num value, {int? fallback}) => _clampInt(
  value,
  LoggedMealLimits.estimatedGMin,
  LoggedMealLimits.estimatedGMax,
  fallback,
);

/// Klemmt `protein_g` / `carbs_g` / `fat_g` einer Mahlzeit auf 0..1000.
///
/// Nicht zu verwechseln mit den Tages**zielen** im Profil (0..400 / 0..800 /
/// 0..300) — dafuer gibt es [clampProteinGoalG] & Co.
double clampMealMacroG(num value, {double? fallback}) => _clampDouble(
  value,
  LoggedMealLimits.macroGMin,
  LoggedMealLimits.macroGMax,
  fallback,
);

// ---------------------------------------------------------------------------
// Zahl-Clamps: weight_log
// ---------------------------------------------------------------------------

/// Klemmt auf `weight_log.weight_kg` (20..400) und rundet auf zwei
/// Nachkommastellen — der Spaltentyp ist `numeric(5,2)` und wuerde
/// serverseitig ohnehin runden. Mitzurunden haelt lokalen Cache und
/// Serverzeile identisch.
double clampWeightLogKg(num value, {double? fallback}) {
  final geklemmt = _clampDouble(
    value,
    WeightLogLimits.weightKgMin,
    WeightLogLimits.weightKgMax,
    fallback,
  );
  return roundToDecimals(geklemmt, WeightLogLimits.weightKgDecimals);
}

/// Rundet [value] auf [decimals] Nachkommastellen (kaufmaennisch, wie
/// PostgreSQL `numeric`).
double roundToDecimals(double value, int decimals) {
  if (!value.isFinite) return value;
  var faktor = 1.0;
  for (var i = 0; i < decimals; i++) {
    faktor *= 10;
  }
  return (value * faktor).round() / faktor;
}

// ---------------------------------------------------------------------------
// Zahl-Clamps: Plausibilitaet
// ---------------------------------------------------------------------------

/// Klemmt kcal/100 g auf 0..900 (physikalische Grenze, keine DB-Grenze).
double clampKcalPer100G(num value, {double? fallback}) => _clampDouble(
  value,
  PlausibilityLimits.kcalPer100GMin,
  PlausibilityLimits.kcalPer100GMax,
  fallback,
);

/// Klemmt eine Portionsgroesse auf 1..10000 g — strenger als die DB-Grenze
/// [LoggedMealLimits.estimatedGMin] (0 g), weil eine 0-g-Portion in
/// `adjustedToGrams` keine sinnvolle Bezugsgroesse ist.
int clampPortionGrams(num value, {int? fallback}) => _clampInt(
  value,
  PlausibilityLimits.portionGramsMin,
  PlausibilityLimits.portionGramsMax,
  fallback,
);

// ---------------------------------------------------------------------------
// Pruefungen: fuer Nutzereingaben, die abgelehnt statt verbogen werden sollen
// ---------------------------------------------------------------------------

/// `true`, wenn [value] `profiles.weight_kg` (30..300) erfuellt.
/// `NaN` und `infinity` sind immer ungueltig.
bool isValidProfileWeightKg(num value) =>
    _isWithin(value, ProfileLimits.weightKgMin, ProfileLimits.weightKgMax);

/// `true`, wenn [value] `profiles.height_cm` (100..250) erfuellt.
bool isValidProfileHeightCm(num value) =>
    _isWithin(value, ProfileLimits.heightCmMin, ProfileLimits.heightCmMax);

/// `true`, wenn [value] `profiles.age_years` (16..100) erfuellt.
bool isValidProfileAgeYears(num value) =>
    _isWithin(value, ProfileLimits.ageYearsMin, ProfileLimits.ageYearsMax);

/// `true`, wenn [value] `profiles.target_weight_kg` (30..300) erfuellt.
bool isValidProfileTargetWeightKg(num value) =>
    _isWithin(value, ProfileLimits.targetWeightKgMin, ProfileLimits.targetWeightKgMax);

/// `true`, wenn [value] `profiles.daily_steps_goal` (1000..100000) erfuellt.
bool isValidDailyStepsGoal(num value) =>
    _isWithin(value, ProfileLimits.dailyStepsGoalMin, ProfileLimits.dailyStepsGoalMax);

/// `true`, wenn [value] `profiles.daily_kcal_goal` (800..7000) erfuellt.
bool isValidDailyKcalGoal(num value) =>
    _isWithin(value, ProfileLimits.dailyKcalGoalMin, ProfileLimits.dailyKcalGoalMax);

/// `true`, wenn [value] `profiles.daily_water_goal_ml` (500..12000) erfuellt.
bool isValidDailyWaterGoalMl(num value) => _isWithin(
  value,
  ProfileLimits.dailyWaterGoalMlMin,
  ProfileLimits.dailyWaterGoalMlMax,
);

/// `true`, wenn [value] `profiles.daily_sleep_goal_minutes` (180..900) erfuellt.
bool isValidDailySleepGoalMinutes(num value) => _isWithin(
  value,
  ProfileLimits.dailySleepGoalMinutesMin,
  ProfileLimits.dailySleepGoalMinutesMax,
);

/// `true`, wenn [value] `profiles.protein_goal_g` (0..400) erfuellt.
bool isValidProteinGoalG(num value) =>
    _isWithin(value, ProfileLimits.proteinGoalGMin, ProfileLimits.proteinGoalGMax);

/// `true`, wenn [value] `profiles.carbs_goal_g` (0..800) erfuellt.
bool isValidCarbsGoalG(num value) =>
    _isWithin(value, ProfileLimits.carbsGoalGMin, ProfileLimits.carbsGoalGMax);

/// `true`, wenn [value] `profiles.fat_goal_g` (0..300) erfuellt.
bool isValidFatGoalG(num value) =>
    _isWithin(value, ProfileLimits.fatGoalGMin, ProfileLimits.fatGoalGMax);

/// `true`, wenn [value] `calories_kcal` (0..10000) erfuellt.
bool isValidMealCaloriesKcal(num value) => _isWithin(
  value,
  LoggedMealLimits.caloriesKcalMin,
  LoggedMealLimits.caloriesKcalMax,
);

/// `true`, wenn [value] `estimated_g` (0..10000) erfuellt.
bool isValidMealEstimatedG(num value) =>
    _isWithin(value, LoggedMealLimits.estimatedGMin, LoggedMealLimits.estimatedGMax);

/// `true`, wenn [value] `protein_g`/`carbs_g`/`fat_g` (0..1000) erfuellt.
bool isValidMealMacroG(num value) =>
    _isWithin(value, LoggedMealLimits.macroGMin, LoggedMealLimits.macroGMax);

/// `true`, wenn [value] `weight_log.weight_kg` (20..400) erfuellt.
bool isValidWeightLogKg(num value) =>
    _isWithin(value, WeightLogLimits.weightKgMin, WeightLogLimits.weightKgMax);

/// `true`, wenn [value] als kcal/100 g physikalisch moeglich ist (0..900).
bool isPlausibleKcalPer100G(num value) => _isWithin(
  value,
  PlausibilityLimits.kcalPer100GMin,
  PlausibilityLimits.kcalPer100GMax,
);

/// `true`, wenn [value] als Portionsgroesse plausibel ist (1..10000 g).
bool isPlausiblePortionGrams(num value) => _isWithin(
  value,
  PlausibilityLimits.portionGramsMin,
  PlausibilityLimits.portionGramsMax,
);
