import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
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

  /// Der volle, NUTZERSICHTBARE Slot-Name („Frühstück"/„Mittagessen"/
  /// „Abendessen"/„Snacks") — aus der ARB, spricht die aktive App-Sprache.
  ///
  /// Seit der i18n-Migration (Paket 2, 2026-08-10) hier zuhause statt als
  /// `MealSlotLabel.label`-Getter in `models/logged_meal.dart`: ein Getter
  /// ohne Sprachparameter kann die ARB nicht erreichen. Der alte Name blieb
  /// dort als [MealSlotLabel.germanLabel] fuer den einen verbliebenen
  /// nicht-UI-Aufrufer (KI-Kontext) erhalten — s. dort.
  String label(AppLocalizations l10n) => switch (this) {
        MealSlot.breakfast => l10n.commonSlotBreakfast,
        MealSlot.lunch => l10n.commonSlotLunch,
        MealSlot.dinner => l10n.commonSlotDinner,
        MealSlot.snack => l10n.commonSlotSnacks,
      };

  /// Kompaktes Label für enge Slots (Segmented-Control) — kürzer als
  /// [label], z. B. „Mittag" statt „Mittagessen".
  String shortLabel(AppLocalizations l10n) => switch (this) {
        MealSlot.breakfast => l10n.commonSlotBreakfastShort,
        MealSlot.lunch => l10n.commonSlotLunchShort,
        MealSlot.dinner => l10n.commonSlotDinnerShort,
        MealSlot.snack => l10n.commonSlotSnackShort,
      };

  /// Anfangsbuchstabe für den runden Slot-Avatar der neuen Karten — aus dem
  /// sprachaktiven [label], damit er unter `en` mit „B"/„L"/„D"/„S" statt
  /// weiterhin „F"/„M"/„A"/„S" uebereinstimmt.
  String initial(AppLocalizations l10n) => label(l10n).substring(0, 1).toUpperCase();
}
