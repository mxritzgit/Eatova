import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/logged_meal.dart';
import 'app_tokens.dart';

/// Single source of truth for [MealSlot] UI style (accent color, icon,
/// labels) — this switch used to be duplicated across half a dozen widgets
/// and the icons started to diverge.
extension MealSlotStyle on MealSlot {
  /// The slot color from the theme tokens; works in both modes. Breakfast
  /// carries the carb tone, lunch protein, dinner fat. Snack gets its own
  /// fourth color rather than grey, which would read as "disabled".
  Color accentOn(AppTokens t) => switch (this) {
        MealSlot.breakfast => t.carbs,
        MealSlot.lunch => t.protein,
        MealSlot.dinner => t.fat,
        MealSlot.snack => t.snack,
      };

  /// Convenience accessor where a [BuildContext] is at hand.
  Color accentIn(BuildContext context) => accentOn(context.t);

  // Slot colors come exclusively from [accentOn]/[accentIn]; the old fixed
  // dark-palette `accent` getter is gone.

  IconData get icon => switch (this) {
        MealSlot.breakfast => Icons.wb_sunny_outlined,
        MealSlot.lunch => Icons.light_mode_outlined,
        MealSlot.dinner => Icons.nights_stay_outlined,
        MealSlot.snack => Icons.cookie_outlined,
      };

  /// The full, user-visible slot name from the ARB, in the active app
  /// language. Lives here rather than as a getter on the model because a
  /// getter without a locale parameter cannot reach the ARB;
  /// [MealSlotLabel.germanLabel] remains there for the one non-UI caller.
  String label(AppLocalizations l10n) => switch (this) {
        MealSlot.breakfast => l10n.commonSlotBreakfast,
        MealSlot.lunch => l10n.commonSlotLunch,
        MealSlot.dinner => l10n.commonSlotDinner,
        MealSlot.snack => l10n.commonSlotSnacks,
      };

  /// Compact label for tight spots (segmented control) — shorter than [label].
  String shortLabel(AppLocalizations l10n) => switch (this) {
        MealSlot.breakfast => l10n.commonSlotBreakfastShort,
        MealSlot.lunch => l10n.commonSlotLunchShort,
        MealSlot.dinner => l10n.commonSlotDinnerShort,
        MealSlot.snack => l10n.commonSlotSnackShort,
      };

  /// Initial for the round slot avatar, taken from the localized [label] so
  /// it follows the active language.
  String initial(AppLocalizations l10n) => label(l10n).substring(0, 1).toUpperCase();
}
