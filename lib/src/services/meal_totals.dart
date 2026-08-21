import 'package:flutter/material.dart' show DateUtils;

import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import 'local_day.dart';

/// Reine Aggregations-Helfer für die Tages-Ernährungswerte. Aus dem Home-State
/// (`_EatovaHomePageState`) extrahiert, damit die kcal-/Makro-Mathematik ohne
/// UI deterministisch unit-testbar ist und nicht im God-Object versteckt liegt.

/// Alle für [date] geloggten Mahlzeiten — tag-genau, die Uhrzeit wird ignoriert.
///
/// DATA-6: Mahlzeiten mit persistiertem [LoggedMeal.localDay] werden ueber
/// diesen kanonischen lokalen Tages-Schluessel gebucketet — denselben, den
/// Koffein (`caffeine_entries.local_day`) verwendet. Dadurch landet ein
/// 23:45-Ortszeit-Eintrag fuer BEIDE Tracks im selben Tag, auch wenn die
/// Ansicht spaeter unter einer anderen Zonen-/DST-Offset laeuft. Zeilen ohne
/// localDay (Altbestand bzw. home_page-Konstruktion ohne das Feld) fallen auf
/// die alte `isSameDay(.toLocal())`-Logik zurueck — verhaltensidentisch zu
/// vorher, daher kein Bruch bestehender Pins.
List<LoggedMeal> mealsForFoodDate(List<LoggedMeal> meals, DateTime date) {
  final dayKey = localDayKey(date.toLocal());
  final day = DateUtils.dateOnly(date);
  return meals.where((meal) {
    final persisted = meal.localDay;
    if (persisted != null) {
      return persisted == dayKey;
    }
    return DateUtils.isSameDay(meal.loggedAt, day);
  }).toList(growable: false);
}

/// Summe der gegessenen Kalorien an [date].
int consumedKcalForFoodDate(List<LoggedMeal> meals, DateTime date) {
  return mealsForFoodDate(meals, date)
      .fold<int>(0, (sum, meal) => sum + meal.result.caloriesKcal);
}

/// Makro-Fortschritt (Protein/KH/Fett/kcal) an [date], summiert aus den
/// Einzel-Mahlzeiten.
MacroProgress macroProgressForFoodDate(List<LoggedMeal> meals, DateTime date) {
  return mealsForFoodDate(meals, date).fold<MacroProgress>(
    MacroProgress.empty,
    (progress, meal) => progress.add(meal.result),
  );
}

/// Tages-Summe EINES Mahlzeiten-Slots: die aufsummierten Makros/kcal plus die
/// Anzahl der Einträge, die hineingeflossen sind. [MacroProgress] selbst
/// kennt keine Stückzahl, der Coach-Kontext nennt sie aber mit („5 Einträge"),
/// damit das Modell „nur durchs Abendessen" von „ein großes Abendessen"
/// unterscheiden kann.
typedef SlotTotals = ({MacroProgress macros, int entries});

/// Makro-Fortschritt je [MealSlot] an [date] — die Slot-Aufschlüsselung von
/// [macroProgressForFoodDate] für den Coach-Kontext (Frage „wie viel Protein
/// habe ich nur durchs Abendessen gegessen?").
///
/// Enthält NUR Slots, in denen an [date] mindestens eine Mahlzeit liegt, in
/// [MealSlot.values]-Reihenfolge (Frühstück → Mittagessen → Abendessen →
/// Snacks) unabhängig von der Log-Reihenfolge. Slots ohne Eintrag fehlen
/// komplett, statt mit [MacroProgress.empty] aufzutauchen — der Aufrufer muss
/// nichts herausfiltern, und „leer" ist von „0 kcal geloggt" unterscheidbar.
/// Der Slot kommt aus [LoggedMeal.slot] (forcedSlot vor Uhrzeit-Heuristik);
/// der Tagesfilter ist derselbe wie bei allen Helfern hier
/// ([mealsForFoodDate], DATA-6-Bucketing).
Map<MealSlot, SlotTotals> slotTotalsForFoodDate(
  List<LoggedMeal> meals,
  DateTime date,
) {
  final bySlot = <MealSlot, SlotTotals>{};
  for (final meal in mealsForFoodDate(meals, date)) {
    final previous =
        bySlot[meal.slot] ?? (macros: MacroProgress.empty, entries: 0);
    bySlot[meal.slot] = (
      macros: previous.macros.add(meal.result),
      entries: previous.entries + 1,
    );
  }
  // Kanonische Slot-Reihenfolge statt Einfüge-Reihenfolge: die Map wird im
  // Kontext linear ausgegeben, und „Frühstück; Mittagessen; Abendessen" liest
  // sich für Modell wie Mensch als Tagesablauf.
  return {
    for (final slot in MealSlot.values)
      if (bySlot.containsKey(slot)) slot: bySlot[slot]!,
  };
}
