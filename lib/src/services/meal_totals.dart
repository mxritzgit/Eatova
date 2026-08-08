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
