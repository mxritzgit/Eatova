import 'package:flutter/material.dart';

import '../models/logged_meal.dart';
import 'app_tokens.dart';

/// Zentrale UI-Stilzuordnung für [MealSlot] (Akzentfarbe, Tageszeit-Icon,
/// kompaktes Label). Vorher war dieses switch 5–6× über Widgets dupliziert
/// (add_meal_sheet, recipes_screen, meal_analysis_sheet, existing_meals_list)
/// und die Icons begannen zu divergieren. Eine Quelle der Wahrheit.
extension MealSlotStyle on MealSlot {
  /// Die Slot-Farbe aus den Theme-Tokens — funktioniert in beiden
  /// Anzeige-Modi. Die Zuordnung folgt dem Entwurf: Frühstück trägt den
  /// Kohlenhydrat-Ton, Mittag den Protein-Ton, Abend den Fett-Ton. Snack
  /// bekommt eine eigene vierte Farbe statt Grau — ein grauer Slot läse
  /// sich wie „deaktiviert".
  Color accentOn(AppTokens t) => switch (this) {
        MealSlot.breakfast => t.carbs,
        MealSlot.lunch => t.protein,
        MealSlot.dinner => t.fat,
        MealSlot.snack => t.snack,
      };

  /// Bequemer Zugriff, wo ein [BuildContext] zur Hand ist.
  Color accentIn(BuildContext context) => accentOn(context.t);

  // Der frühere `accent`-Getter (feste Dunkel-Palette aus app_colors.dart)
  // ist mit der Verifikations-Welle 2026-08-09 entfallen: er hatte in lib/
  // und test/ keinen Aufrufer mehr und war der letzte Grund, warum
  // lib/src/theme/ noch `app_colors.dart` importierte. Slot-Farben kommen
  // ausschließlich über [accentOn]/[accentIn] — die kennen beide Modi.

  IconData get icon => switch (this) {
        MealSlot.breakfast => Icons.wb_sunny_outlined,
        MealSlot.lunch => Icons.light_mode_outlined,
        MealSlot.dinner => Icons.nights_stay_outlined,
        MealSlot.snack => Icons.cookie_outlined,
      };

  /// Kompaktes Label für enge Slots (Segmented-Control) — kürzer als das
  /// Modell-Label ([MealSlotLabel.label], z. B. „Mittagessen"/„Snacks").
  String get shortLabel => switch (this) {
        MealSlot.breakfast => 'Frühstück',
        MealSlot.lunch => 'Mittag',
        MealSlot.dinner => 'Abend',
        MealSlot.snack => 'Snack',
      };

  /// Anfangsbuchstabe für den runden Slot-Avatar der neuen Karten.
  String get initial => label.substring(0, 1).toUpperCase();
}
