/// PostgreSQL check-constraint bounds as client-side constants.
///
/// `digitsOnly` is a *type* guard, not a *range* guard: "75,5" typed into a
/// weight field loses the comma and sends 755 kg, which the DB rejects with
/// `23514` and the outbox sync then drops.
///
/// ## Clamp or reject?
///
/// * **Reject** (`isValid…`) whatever the user types (weight, height, age,
///   target weight, daily goals, manually corrected kcal/grams). Clamping
///   755 kg to 300 kg silently falsifies the input; show a field error instead.
/// * **Clamp** (`clamp…`) whatever comes from a foreign source with nobody to
///   ask: meal-scan model output, Open Food Facts fields, derived values
///   (`adjustedToGrams`), recipe conversions. A clamped value beats a dropped
///   write.
/// * **Text is always truncated, never rejected.** Exception: `meal_name` and
///   `favorite_key` have a *minimum* length of 1 — the empty string is a
///   `23514` violation, see [isValidMealName] / [isValidFavoriteKey].
/// * Clamps belong at the model boundary, one place per data source, not in
///   every widget. Field validation on top is UX, not safety.
///
/// ## DB bound vs. plausibility bound
///
/// [LoggedMealLimits] & co. mirror exactly what the DB accepts;
/// [PlausibilityLimits] mirrors what is physically sensible (e.g. kcal/100 g
/// has no DB column at all but cannot exceed 900). The caller picks which one.
///
/// ## Non-finite numbers
///
/// `double.nan` means "no value" and is invalid for every [isValid] function;
/// `clamp…` returns `fallback`, which defaults to the **lower bound** — that
/// is where B1 (0 kcal instead of "unknown") came from, so pass an explicit
/// fallback if you need another. `infinity` clamps to the upper bound,
/// `-infinity` to the lower; nothing here throws.
///
/// The file is deliberately dependency-free so models, services and tests can
/// all use it.
library;

// ---------------------------------------------------------------------------
// profiles
// ---------------------------------------------------------------------------

/// Bounds of table `public.profiles`.
abstract final class ProfileLimits {
  // profiles_biometrics_range_check
  // Source: supabase/migrations/20260807090000_profiles_age_minimum_16.sql
  //   check (weight_kg between 30 and 300 and
  //          height_cm between 100 and 250 and
  //          age_years between 16 and 100)
  // Replaces the version in 20260517220000_security_hardening.sql
  // (age_years between 13 and 100); the final state wins.

  /// `weight_kg` is an `integer` column — no decimals.
  static const int weightKgMin = 30;
  static const int weightKgMax = 300;

  static const int heightCmMin = 100;
  static const int heightCmMax = 250;

  /// Minimum age 16 per GDPR Art. 8 (health data, Art. 9).
  static const int ageYearsMin = 16;
  static const int ageYearsMax = 100;

  // profiles_target_weight_range_check
  // Source: supabase/migrations/20260523000000_onboarding_fields.sql
  //   check (target_weight_kg between 30 and 300)
  static const int targetWeightKgMin = 30;
  static const int targetWeightKgMax = 300;

  // profiles_goals_range_check
  // Source: supabase/migrations/20260517220000_security_hardening.sql
  static const int dailyStepsGoalMin = 1000;
  static const int dailyStepsGoalMax = 100000;

  static const int dailyKcalGoalMin = 800;
  static const int dailyKcalGoalMax = 7000;

  static const int dailyWaterGoalMlMin = 500;
  static const int dailyWaterGoalMlMax = 12000;

  static const int dailySleepGoalMinutesMin = 180;
  static const int dailySleepGoalMinutesMax = 900;

  /// Daily macro goals — the bounds `KcalCalculator.calculate` must hit, not
  /// the 0..1000 of per-meal macros.
  static const int proteinGoalGMin = 0;
  static const int proteinGoalGMax = 400;

  static const int carbsGoalGMin = 0;
  static const int carbsGoalGMax = 800;

  static const int fatGoalGMin = 0;
  static const int fatGoalGMax = 300;

  // profiles_display_name_length_check / profiles_avatar_url_length_check
  // Source: supabase/migrations/20260517220000_security_hardening.sql
  //   check (char_length(display_name) <= 80)
  //   check (avatar_url is null or char_length(avatar_url) <= 2048)
  static const int displayNameMaxChars = 80;
  static const int avatarUrlMaxChars = 2048;

  // profiles_sex_check
  // Source: supabase/migrations/20260516160000_app_data_schema.sql
  static const Set<String> sexValues = {'male', 'female', 'neutral'};

  // profiles_activity_level_check
  // Source: supabase/migrations/20260523000000_onboarding_fields.sql
  static const Set<String> activityLevelValues = {
    'sedentary',
    'light',
    'moderate',
    'active',
    'athlete',
  };

  // profiles_weight_goal_check
  // Source: supabase/migrations/20260602120000_profiles_weight_goal.sql
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
  // Source: supabase/migrations/20260604140000_profiles_diet_preference.sql
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

/// Bounds of table `public.logged_meals`.
///
/// Source: `logged_meals_safe_ranges_check` in
/// supabase/migrations/20260517220000_security_hardening.sql.
abstract final class LoggedMealLimits {
  //   char_length(meal_name) between 1 and 160
  /// The empty name is a constraint violation, not a default.
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
  /// Same for `protein_g`, `carbs_g` and `fat_g`. The columns are `numeric`
  /// (nullable), hence `double`, not `int`.
  static const double macroGMin = 0;
  static const double macroGMax = 1000;

  //   (barcode      is null or char_length(barcode)      <= 64)
  //   (brand        is null or char_length(brand)        <= 120)
  //   (source_label is null or char_length(source_label) <= 80)
  static const int barcodeMaxChars = 64;
  static const int brandMaxChars = 120;
  static const int sourceLabelMaxChars = 80;

  //   octet_length(payload::text) <= 200000
  /// **Bytes**, not characters — `octet_length` on the JSON text.
  static const int payloadMaxBytes = 200000;

  // Column constraint from
  // supabase/migrations/20260516160000_app_data_schema.sql:
  //   forced_slot text check (forced_slot in ('breakfast','lunch','dinner','snack'))
  /// `null` is allowed (the column is nullable).
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

/// Bounds of table `public.favorite_meals`.
///
/// Source: `favorite_meals_safe_ranges_check` in
/// supabase/migrations/20260517220000_security_hardening.sql.
abstract final class FavoriteMealLimits {
  //   char_length(favorite_key) between 1 and 180
  /// `favorite_key` is part of the primary key (`barcode:…` / `name:…`), so
  /// truncation must happen at key construction (`FavoriteMeal.idFor`), not at
  /// write time — otherwise local cache and server row use different keys.
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

  /// `favorite_meals` has no macro columns (only `calories_kcal` and
  /// `estimated_g`); macros live in the `payload` JSON. To clamp macros, use
  /// the bounds of [LoggedMealLimits].
  static const bool hasMacroColumns = false;
}

// ---------------------------------------------------------------------------
// weight_log
// ---------------------------------------------------------------------------

/// Bounds of table `public.weight_log`.
abstract final class WeightLogLimits {
  // Two constraints apply at once, the tighter one wins:
  //   * check (weight_kg > 0)
  //     — supabase/migrations/20260516160000_app_data_schema.sql
  //   * weight_log_safe_range_check: check (weight_kg between 20 and 400)
  //     — supabase/migrations/20260517220000_security_hardening.sql
  //
  // Deliberately wider than profiles.weight_kg (30..300): a measurement in the
  // weight history may fall outside the profile range.
  static const double weightKgMin = 20;
  static const double weightKgMax = 400;

  /// Column type `numeric(5,2)` — two decimals, max 999.99 (the check
  /// constraint at 400 is tighter).
  /// Source: supabase/migrations/20260516160000_app_data_schema.sql
  static const int weightKgDecimals = 2;
}

// ---------------------------------------------------------------------------
// user_recipes
// ---------------------------------------------------------------------------

/// Bounds of table `public.user_recipes`.
///
/// Source: supabase/migrations/20260530091000_user_recipes.sql
///   check (calories_kcal >= 0), (protein_g >= 0), (carbs_g >= 0),
///   (fat_g >= 0), (estimated_g >= 0)
abstract final class UserRecipeLimits {
  static const int caloriesKcalMin = 0;
  static const int proteinGMin = 0;
  static const int carbsGMin = 0;
  static const int fatGMin = 0;
  static const int estimatedGMin = 0;

  /// The table has no upper bounds, only `>= 0`; the effective limit is the
  /// `integer` type. Once a recipe is logged as a meal the much stricter
  /// [LoggedMealLimits] apply, enforced in `FitnessRecipe.toMealResult`.
  static const bool hasDbUpperBound = false;
}

// ---------------------------------------------------------------------------
// Plausibility — deliberately no DB counterpart
// ---------------------------------------------------------------------------

/// Bounds the database does not know but that hold physically. Stricter than
/// the DB bounds; they catch obvious junk from foreign sources.
abstract final class PlausibilityLimits {
  /// Pure fat is ~900 kcal/100 g — more is impossible.
  ///
  /// Open Food Facts regularly puts the **kJ** number into `energy-kcal_100g`.
  /// There is no DB column for it (the field lives in the `payload` JSON), so
  /// the client must check. Source: docs/REVIEW-2026-08-08.md, B7.
  static const double kcalPer100GMin = 0;
  static const double kcalPer100GMax = 900;

  /// A 0 g portion is DB-legal (`estimated_g >= 0`) but meaningless as a meal
  /// and divides by the base portion in `adjustedToGrams`.
  static const int portionGramsMin = 1;
  static const int portionGramsMax = LoggedMealLimits.estimatedGMax;

  /// kJ -> kcal factor, for the missing OFF fallback.
  static const double kjPerKcal = 4.184;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

int _clampInt(num value, int min, int max, int? fallback) {
  if (value.isNaN) return _clampInt(fallback ?? min, min, max, min);
  // Compare before rounding: `.round()` on a huge double (1e300) would
  // overflow int64.
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
// Text: length and truncation
// ---------------------------------------------------------------------------

/// Character count with PostgreSQL semantics: `char_length()` counts code
/// points, Dart's `String.length` counts UTF-16 code units (`'🥗'` is 1 vs. 2).
/// Any check against a `char_length` constraint must go through here.
int charLength(String value) => value.runes.length;

/// Truncates [value] to at most [maxChars] code points.
///
/// Cuts on rune boundaries; `substring(0, 160)` would split an emoji between
/// its surrogates and leave invalid UTF-16. Known limit: composed grapheme
/// clusters (ZWJ emoji, flags, skin tones) may fall apart — the result stays
/// valid UTF-16 and constraint-compliant. Cluster fidelity would need
/// `package:characters`; this file stays dependency-free.
String truncateToChars(String value, int maxChars) {
  if (maxChars <= 0) return '';
  if (value.length <= maxChars) return value; // fast path: pure ASCII
  final runes = value.runes.toList(growable: false);
  if (runes.length <= maxChars) return value;
  return String.fromCharCodes(runes.take(maxChars));
}

// ---------------------------------------------------------------------------
// Text clamps (truncation) and text checks
// ---------------------------------------------------------------------------

const String _mealNameFallback = 'Mahlzeit';
const String _favoriteKeyFallback = 'name:mahlzeit';

/// Makes [value] writable as `meal_name`: trim, replace empty names with
/// [fallback] (the constraint requires >= 1 char), truncate to 160 code points.
String clampMealName(String value, {String fallback = _mealNameFallback}) {
  final getrimmt = value.trim();
  var basis = getrimmt.isEmpty ? fallback.trim() : getrimmt;
  if (basis.isEmpty) basis = _mealNameFallback;
  final gekuerzt = truncateToChars(basis, LoggedMealLimits.mealNameMaxChars).trimRight();
  return gekuerzt.isEmpty ? _mealNameFallback : gekuerzt;
}

/// `true` if [value] satisfies `char_length(meal_name) between 1 and 160`.
/// For forms: reject empty names, truncate overlong ones.
bool isValidMealName(String value) {
  final laenge = charLength(value.trim());
  return laenge >= LoggedMealLimits.mealNameMinChars &&
      laenge <= LoggedMealLimits.mealNameMaxChars;
}

/// Makes [value] writable as `favorite_key` (1..180 chars).
///
/// See the warning on [FavoriteMealLimits.favoriteKeyMaxChars]: this belongs
/// in key construction, not at write time.
String clampFavoriteKey(String value, {String fallback = _favoriteKeyFallback}) {
  final getrimmt = value.trim();
  var basis = getrimmt.isEmpty ? fallback.trim() : getrimmt;
  if (basis.isEmpty) basis = _favoriteKeyFallback;
  return truncateToChars(basis, FavoriteMealLimits.favoriteKeyMaxChars);
}

/// `true` if [value] satisfies `char_length(favorite_key) between 1 and 180`.
bool isValidFavoriteKey(String value) {
  final laenge = charLength(value.trim());
  return laenge >= FavoriteMealLimits.favoriteKeyMinChars &&
      laenge <= FavoriteMealLimits.favoriteKeyMaxChars;
}

/// Truncates `brand` to 120 chars. `null` and blank values become `null`: the
/// column is nullable and an empty brand carries no information.
String? clampBrand(String? value) =>
    _clampNullableText(value, LoggedMealLimits.brandMaxChars);

/// Truncates `barcode` to 64 chars (nullable).
String? clampBarcode(String? value) =>
    _clampNullableText(value, LoggedMealLimits.barcodeMaxChars);

/// Truncates `source_label` to 80 chars (nullable).
String? clampSourceLabel(String? value) =>
    _clampNullableText(value, LoggedMealLimits.sourceLabelMaxChars);

/// Truncates `avatar_url` to 2048 chars (nullable).
String? clampAvatarUrl(String? value) =>
    _clampNullableText(value, ProfileLimits.avatarUrlMaxChars);

/// Truncates `display_name` to 80 chars. The column is `not null default ''`
/// with no minimum length, so the empty string stays allowed.
String clampDisplayName(String value) =>
    truncateToChars(value.trim(), ProfileLimits.displayNameMaxChars);

String? _clampNullableText(String? value, int maxChars) {
  if (value == null) return null;
  final getrimmt = value.trim();
  if (getrimmt.isEmpty) return null;
  return truncateToChars(getrimmt, maxChars);
}

// ---------------------------------------------------------------------------
// Numeric clamps: profiles
// ---------------------------------------------------------------------------

/// Clamps to `profiles.weight_kg` (30..300, integer).
///
/// Last resort before the DB only. For user input use
/// [isValidProfileWeightKg]: "75,5" becomes 755 via `digitsOnly`, and clamping
/// 755 to 300 writes a number the user never meant.
int clampProfileWeightKg(num value, {int? fallback}) =>
    _clampInt(value, ProfileLimits.weightKgMin, ProfileLimits.weightKgMax, fallback);

/// Clamps to `profiles.height_cm` (100..250).
int clampProfileHeightCm(num value, {int? fallback}) =>
    _clampInt(value, ProfileLimits.heightCmMin, ProfileLimits.heightCmMax, fallback);

/// Clamps to `profiles.age_years` (16..100).
int clampProfileAgeYears(num value, {int? fallback}) =>
    _clampInt(value, ProfileLimits.ageYearsMin, ProfileLimits.ageYearsMax, fallback);

/// Clamps to `profiles.target_weight_kg` (30..300).
int clampProfileTargetWeightKg(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.targetWeightKgMin,
  ProfileLimits.targetWeightKgMax,
  fallback,
);

/// Clamps to `profiles.daily_steps_goal` (1000..100000).
int clampDailyStepsGoal(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.dailyStepsGoalMin,
  ProfileLimits.dailyStepsGoalMax,
  fallback,
);

/// Clamps to `profiles.daily_kcal_goal` (800..7000).
int clampDailyKcalGoal(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.dailyKcalGoalMin,
  ProfileLimits.dailyKcalGoalMax,
  fallback,
);

/// Clamps to `profiles.daily_water_goal_ml` (500..12000).
int clampDailyWaterGoalMl(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.dailyWaterGoalMlMin,
  ProfileLimits.dailyWaterGoalMlMax,
  fallback,
);

/// Clamps to `profiles.daily_sleep_goal_minutes` (180..900).
int clampDailySleepGoalMinutes(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.dailySleepGoalMinutesMin,
  ProfileLimits.dailySleepGoalMinutesMax,
  fallback,
);

/// Clamps to `profiles.protein_goal_g` (0..400) — the `proteinG.clamp(0, 400)`
/// from `KcalCalculator.calculate`.
int clampProteinGoalG(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.proteinGoalGMin,
  ProfileLimits.proteinGoalGMax,
  fallback,
);

/// Clamps to `profiles.carbs_goal_g` (0..800).
int clampCarbsGoalG(num value, {int? fallback}) => _clampInt(
  value,
  ProfileLimits.carbsGoalGMin,
  ProfileLimits.carbsGoalGMax,
  fallback,
);

/// Clamps to `profiles.fat_goal_g` (0..300) — the `fatG.clamp(0, 300)` from
/// `KcalCalculator.calculate`.
int clampFatGoalG(num value, {int? fallback}) =>
    _clampInt(value, ProfileLimits.fatGoalGMin, ProfileLimits.fatGoalGMax, fallback);

// ---------------------------------------------------------------------------
// Numeric clamps: logged_meals / favorite_meals
// ---------------------------------------------------------------------------

/// Clamps to `calories_kcal` (0..10000), same for `logged_meals` and
/// `favorite_meals`.
int clampMealCaloriesKcal(num value, {int? fallback}) => _clampInt(
  value,
  LoggedMealLimits.caloriesKcalMin,
  LoggedMealLimits.caloriesKcalMax,
  fallback,
);

/// Clamps to `estimated_g` (0..10000, DB bound).
///
/// For portion sizes describing a meal use [clampPortionGrams] (from 1 g).
int clampMealEstimatedG(num value, {int? fallback}) => _clampInt(
  value,
  LoggedMealLimits.estimatedGMin,
  LoggedMealLimits.estimatedGMax,
  fallback,
);

/// Clamps a meal's `protein_g` / `carbs_g` / `fat_g` to 0..1000.
///
/// Not the daily *goals* in the profile (0..400 / 0..800 / 0..300) — those are
/// [clampProteinGoalG] & co.
double clampMealMacroG(num value, {double? fallback}) => _clampDouble(
  value,
  LoggedMealLimits.macroGMin,
  LoggedMealLimits.macroGMax,
  fallback,
);

// ---------------------------------------------------------------------------
// Numeric clamps: weight_log
// ---------------------------------------------------------------------------

/// Clamps to `weight_log.weight_kg` (20..400) and rounds to two decimals: the
/// column is `numeric(5,2)` and would round server-side anyway, so rounding
/// here keeps local cache and server row identical.
double clampWeightLogKg(num value, {double? fallback}) {
  final geklemmt = _clampDouble(
    value,
    WeightLogLimits.weightKgMin,
    WeightLogLimits.weightKgMax,
    fallback,
  );
  return roundToDecimals(geklemmt, WeightLogLimits.weightKgDecimals);
}

/// Rounds [value] to [decimals] decimals (half-up, like PostgreSQL `numeric`).
double roundToDecimals(double value, int decimals) {
  if (!value.isFinite) return value;
  var faktor = 1.0;
  for (var i = 0; i < decimals; i++) {
    faktor *= 10;
  }
  return (value * faktor).round() / faktor;
}

// ---------------------------------------------------------------------------
// Numeric clamps: plausibility
// ---------------------------------------------------------------------------

/// Clamps kcal/100 g to 0..900 (physical bound, not a DB bound).
double clampKcalPer100G(num value, {double? fallback}) => _clampDouble(
  value,
  PlausibilityLimits.kcalPer100GMin,
  PlausibilityLimits.kcalPer100GMax,
  fallback,
);

/// Clamps a portion size to 1..10000 g — stricter than the DB bound
/// [LoggedMealLimits.estimatedGMin] (0 g), because a 0 g portion is no usable
/// reference in `adjustedToGrams`.
int clampPortionGrams(num value, {int? fallback}) => _clampInt(
  value,
  PlausibilityLimits.portionGramsMin,
  PlausibilityLimits.portionGramsMax,
  fallback,
);

// ---------------------------------------------------------------------------
// Checks: for user input that should be rejected, not bent into range
// ---------------------------------------------------------------------------

/// `true` if [value] satisfies `profiles.weight_kg` (30..300).
/// `NaN` and `infinity` are always invalid.
bool isValidProfileWeightKg(num value) =>
    _isWithin(value, ProfileLimits.weightKgMin, ProfileLimits.weightKgMax);

/// `true` if [value] satisfies `profiles.height_cm` (100..250).
bool isValidProfileHeightCm(num value) =>
    _isWithin(value, ProfileLimits.heightCmMin, ProfileLimits.heightCmMax);

/// `true` if [value] satisfies `profiles.age_years` (16..100).
bool isValidProfileAgeYears(num value) =>
    _isWithin(value, ProfileLimits.ageYearsMin, ProfileLimits.ageYearsMax);

/// `true` if [value] satisfies `profiles.target_weight_kg` (30..300).
bool isValidProfileTargetWeightKg(num value) =>
    _isWithin(value, ProfileLimits.targetWeightKgMin, ProfileLimits.targetWeightKgMax);

/// `true` if [value] satisfies `profiles.daily_steps_goal` (1000..100000).
bool isValidDailyStepsGoal(num value) =>
    _isWithin(value, ProfileLimits.dailyStepsGoalMin, ProfileLimits.dailyStepsGoalMax);

/// `true` if [value] satisfies `profiles.daily_kcal_goal` (800..7000).
bool isValidDailyKcalGoal(num value) =>
    _isWithin(value, ProfileLimits.dailyKcalGoalMin, ProfileLimits.dailyKcalGoalMax);

/// `true` if [value] satisfies `profiles.daily_water_goal_ml` (500..12000).
bool isValidDailyWaterGoalMl(num value) => _isWithin(
  value,
  ProfileLimits.dailyWaterGoalMlMin,
  ProfileLimits.dailyWaterGoalMlMax,
);

/// `true` if [value] satisfies `profiles.daily_sleep_goal_minutes` (180..900).
bool isValidDailySleepGoalMinutes(num value) => _isWithin(
  value,
  ProfileLimits.dailySleepGoalMinutesMin,
  ProfileLimits.dailySleepGoalMinutesMax,
);

/// `true` if [value] satisfies `profiles.protein_goal_g` (0..400).
bool isValidProteinGoalG(num value) =>
    _isWithin(value, ProfileLimits.proteinGoalGMin, ProfileLimits.proteinGoalGMax);

/// `true` if [value] satisfies `profiles.carbs_goal_g` (0..800).
bool isValidCarbsGoalG(num value) =>
    _isWithin(value, ProfileLimits.carbsGoalGMin, ProfileLimits.carbsGoalGMax);

/// `true` if [value] satisfies `profiles.fat_goal_g` (0..300).
bool isValidFatGoalG(num value) =>
    _isWithin(value, ProfileLimits.fatGoalGMin, ProfileLimits.fatGoalGMax);

/// `true` if [value] satisfies `calories_kcal` (0..10000).
bool isValidMealCaloriesKcal(num value) => _isWithin(
  value,
  LoggedMealLimits.caloriesKcalMin,
  LoggedMealLimits.caloriesKcalMax,
);

/// `true` if [value] satisfies `estimated_g` (0..10000).
bool isValidMealEstimatedG(num value) =>
    _isWithin(value, LoggedMealLimits.estimatedGMin, LoggedMealLimits.estimatedGMax);

/// `true` if [value] satisfies `protein_g`/`carbs_g`/`fat_g` (0..1000).
bool isValidMealMacroG(num value) =>
    _isWithin(value, LoggedMealLimits.macroGMin, LoggedMealLimits.macroGMax);

/// `true` if [value] satisfies `weight_log.weight_kg` (20..400).
bool isValidWeightLogKg(num value) =>
    _isWithin(value, WeightLogLimits.weightKgMin, WeightLogLimits.weightKgMax);

/// `true` if [value] is physically possible as kcal/100 g (0..900).
bool isPlausibleKcalPer100G(num value) => _isWithin(
  value,
  PlausibilityLimits.kcalPer100GMin,
  PlausibilityLimits.kcalPer100GMax,
);

/// `true` if [value] is a plausible portion size (1..10000 g).
bool isPlausiblePortionGrams(num value) => _isWithin(
  value,
  PlausibilityLimits.portionGramsMin,
  PlausibilityLimits.portionGramsMax,
);
