import 'package:eatova/src/models/day_nutrition.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';

/// The day summary a widget test hands to `TodayScreen`, built the way
/// `HomeStore.nutritionSummaryForFoodDate` builds it: [consumedKcal] is the
/// eaten kcal, [macroProgress] only contributes the grams.
DayNutritionSummary todaySummary({
  UserProfile profile = const UserProfile(),
  int consumedKcal = 0,
  int burnedKcal = 0,
  MacroProgress macroProgress = MacroProgress.empty,
}) => DayNutritionSummary(
  profile: profile,
  burnedKcal: burnedKcal,
  consumed: MacroProgress(
    proteinG: macroProgress.proteinG,
    carbsG: macroProgress.carbsG,
    fatG: macroProgress.fatG,
    kcal: consumedKcal,
  ),
);
