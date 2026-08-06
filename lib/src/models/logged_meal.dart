import 'package:clock/clock.dart';

import '../services/local_day.dart';
import 'meal_analysis_result.dart';

enum MealSlot { breakfast, lunch, dinner, snack }

extension MealSlotLabel on MealSlot {
  String get label => switch (this) {
        MealSlot.breakfast => 'Frühstück',
        MealSlot.lunch => 'Mittagessen',
        MealSlot.dinner => 'Abendessen',
        MealSlot.snack => 'Snacks',
      };
}

/// Reine Uhrzeit-Heuristik: ordnet eine Stunde (0–23) einem [MealSlot] zu.
/// Top-level + rein, damit die Grenzen (11/15/21 Uhr) ohne LoggedMeal-Instanz
/// und ohne Wanduhr testbar sind.
MealSlot mealSlotForHour(int hour) {
  if (hour < 11) return MealSlot.breakfast;
  if (hour < 15) return MealSlot.lunch;
  if (hour < 21) return MealSlot.dinner;
  return MealSlot.snack;
}

/// Slot fuer „jetzt" anhand der aktuellen Zonen-Uhr. Liest [clock.now()]
/// (Default: DateTime.now()), damit Tests die Zeit per withClock ueber
/// Mitternacht/DST-Grenzen festnageln koennen — das Laufzeit-Verhalten
/// bleibt identisch zu DateTime.now().
MealSlot currentMealSlot() => mealSlotForHour(clock.now().hour);

class LoggedMeal {
  const LoggedMeal({
    required this.id,
    required this.result,
    required this.loggedAt,
    this.forcedSlot,
    this.localDay,
  });

  final String id;
  final MealAnalysisResult result;
  final DateTime loggedAt;
  final MealSlot? forcedSlot;

  /// DATA-6: kanonischer lokaler Tages-Schluessel (`YYYY-MM-DD`) dieser
  /// Mahlzeit, wie er serverseitig in `logged_meals.local_day` steht.
  /// Optional/additiv: aeltere Zeilen (und die bestehende home_page-
  /// Konstruktion ueber `LoggedMeal(...)` ohne dieses Feld) lassen es null —
  /// dann faellt das Bucketing auf die alte `isSameDay(.toLocal())`-Logik
  /// zurueck. Frisch geloggte/geladene Mahlzeiten tragen den Schluessel.
  final String? localDay;

  /// Der lokale Tages-Schluessel dieser Mahlzeit — bevorzugt der persistierte
  /// [localDay], sonst aus der lokalen Wanduhr von [loggedAt] berechnet.
  /// Immer non-null, damit das Bucketing einen stabilen Schluessel hat.
  String get effectiveLocalDay => localDay ?? localDayKey(loggedAt.toLocal());

  MealSlot get slot {
    if (forcedSlot != null) {
      return forcedSlot!;
    }
    return mealSlotForHour(loggedAt.hour);
  }

  LoggedMeal copyWith({
    MealAnalysisResult? result,
    DateTime? loggedAt,
    MealSlot? forcedSlot,
    String? localDay,
  }) {
    return LoggedMeal(
      id: id,
      result: result ?? this.result,
      loggedAt: loggedAt ?? this.loggedAt,
      forcedSlot: forcedSlot ?? this.forcedSlot,
      localDay: localDay ?? this.localDay,
    );
  }
}
