import '../services/day_math.dart';

/// Kumulierte Lebenszeit-Zaehler eines Users (1:1 public.lifetime_stats).
///
/// Die Streak ist seit dem Training-Tab-Aus (2026-08-03) eine LOGGING-Streak:
/// jeder Kalendertag mit mindestens einer geloggten Mahlzeit zaehlt. Die
/// DB-Spalten heissen historisch weiter current_streak/longest_streak/
/// last_workout_date — nur die Bedeutung (und die Dart-Namen) sind neu.
class LifetimeStats {
  LifetimeStats({
    this.workoutsCompleted = 0,
    this.mealsLogged = 0,
    this.waterTotalMl = 0,
    this.stepsRecorded = 0,
    this.weightLogs = 0,
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.lastTrackedDate,
    DateTime? sessionStart,
  }) : sessionStart = sessionStart ?? DateTime.now();

  /// DEPRECATED (C7, 2026-08-08) — eingefrorener Legacy-Zaehler ohne
  /// Schreiber. `incrementWorkouts()` hatte seit dem Training-Tab-Aus
  /// (a267e15) keinen Aufrufer mehr und ist entfernt; der Wert ist fuer neue
  /// Konten dauerhaft 0.
  ///
  /// Das FELD bleibt bewusst stehen: `workouts_completed` ist eine
  /// `not null`-Spalte mit `>= 0`-Check in public.lifetime_stats, steht im
  /// expliziten select von [LifetimeStatsSync.load], ist ein Parameter der
  /// increment_lifetime_stats-RPC und liegt im LocalCache-JSON bestehender
  /// Installationen. Ein Entfernen aus dem Wire-Format wuerde beides brechen.
  /// Nicht per `@Deprecated` annotiert, weil das an jeder Lesestelle
  /// (LocalCache-Serialisierung, Profil-Export) `flutter analyze` vollschreiben
  /// wuerde, ohne dass die Stellen etwas anders machen koennten.
  final int workoutsCompleted;

  final int mealsLogged;

  /// DEPRECATED (C7) — wie [workoutsCompleted]: `addWater()` verschwand mit
  /// den Wasser-Kacheln des Heute-Tabs, die Spalte `water_total_ml` bleibt.
  final int waterTotalMl;

  /// DEPRECATED (C7) — wie [workoutsCompleted]: `addSteps()` verschwand mit
  /// dem Heute-Tab, die Spalte `steps_recorded` bleibt. Der aktuelle
  /// Schrittstand lebt als `HomeStore.dailySteps` und kommt aus HealthKit.
  final int stepsRecorded;

  final int weightLogs;

  /// Aktuelle Logging-Streak in aufeinanderfolgenden Tagen.
  final int currentStreak;

  /// Hoechste je erreichte Streak (Highscore, nie absteigend).
  final int longestStreak;

  /// Datum (date-only) des letzten gezaehlten Logging-Tages, oder null.
  /// Persistiert in der historisch benannten Spalte last_workout_date.
  final DateTime? lastTrackedDate;

  final DateTime sessionStart;

  Duration get sessionDuration => DateTime.now().difference(sessionStart);

  /// C7: die eingefrorenen Legacy-Zaehler ([workoutsCompleted], [waterTotalMl],
  /// [stepsRecorded]) sind hier bewusst NICHT mehr aenderbar — sie haben
  /// keinen Schreiber mehr und werden nur noch durchgereicht. Der Konstruktor
  /// nimmt sie weiterhin entgegen, damit [fromRow] und der LocalCache die
  /// bestehenden Werte rekonstruieren koennen.
  LifetimeStats copyWith({
    int? mealsLogged,
    int? weightLogs,
    int? currentStreak,
    int? longestStreak,
    DateTime? lastTrackedDate,
  }) {
    return LifetimeStats(
      workoutsCompleted: workoutsCompleted,
      mealsLogged: mealsLogged ?? this.mealsLogged,
      waterTotalMl: waterTotalMl,
      stepsRecorded: stepsRecorded,
      weightLogs: weightLogs ?? this.weightLogs,
      currentStreak: currentStreak ?? this.currentStreak,
      longestStreak: longestStreak ?? this.longestStreak,
      lastTrackedDate: lastTrackedDate ?? this.lastTrackedDate,
      sessionStart: sessionStart,
    );
  }

  LifetimeStats incrementMeals() =>
      copyWith(mealsLogged: mealsLogged + 1);

  LifetimeStats incrementWeightLogs() =>
      copyWith(weightLogs: weightLogs + 1);

  /// Verbucht einen getrackten Tag (>= 1 geloggte Mahlzeit) und fuehrt die
  /// Streak fort.
  ///
  /// - War der letzte getrackte Tag *gestern* (relativ zu [day]), zaehlt
  ///   die Streak +1 weiter.
  /// - Selber Tag: idempotent (doppeltes Loggen am gleichen Tag zaehlt
  ///   nicht doppelt), nur lastTrackedDate wird auf [day] normalisiert.
  /// - [day] liegt VOR lastTrackedDate: No-op — der Food-Kalender erlaubt
  ///   Nachtraege fuer vergangene Tage, die duerfen die laufende Streak
  ///   weder resetten noch fortschreiben.
  /// - Sonst (Luecke >= 1 Tag oder erster Log) Reset auf 1.
  /// longestStreak = max(longestStreak, currentStreak danach).
  LifetimeStats recordTrackedDay(DateTime day) {
    final today = DateTime(day.year, day.month, day.day);
    int nextStreak;
    if (lastTrackedDate == null) {
      nextStreak = 1;
    } else {
      final last = DateTime(
        lastTrackedDate!.year,
        lastTrackedDate!.month,
        lastTrackedDate!.day,
      );
      // B5: Kalendertage, NICHT `.difference().inDays` — letzteres misst
      // Absolutzeit und meldet ueber die Fruehjahrsumstellung (23-Stunden-Tag)
      // fuer den Folgetag 0 statt 1. Die Streak stand dadurch am 30.03. still.
      final diffDays = daysBetween(today, last);
      if (diffDays < 0) {
        // Nachtrag fuer einen vergangenen Tag — Streak unangetastet.
        return this;
      }
      if (diffDays == 0) {
        // Schon heute gezaehlt — idempotent, Streak haelt.
        nextStreak = currentStreak < 1 ? 1 : currentStreak;
      } else if (diffDays == 1) {
        nextStreak = currentStreak + 1;
      } else {
        // Luecke (oder Zukunft) — Streak gerissen, Neustart bei 1.
        nextStreak = 1;
      }
    }
    final nextLongest = nextStreak > longestStreak ? nextStreak : longestStreak;
    return copyWith(
      currentStreak: nextStreak,
      longestStreak: nextLongest,
      lastTrackedDate: today,
    );
  }

  /// Streak fuer die ANZEIGE: currentStreak solange die Kette noch lebt
  /// (letzter getrackter Tag ist heute oder gestern relativ zu [now]),
  /// sonst 0. currentStreak selbst bleibt bis zum naechsten Log stehen —
  /// ohne diesen Check wuerde eine laengst gerissene Kette weiter ihren
  /// alten Wert zeigen.
  int effectiveStreakOn(DateTime now) {
    final last = lastTrackedDate;
    if (last == null) return 0;
    final today = DateTime(now.year, now.month, now.day);
    final lastDay = DateTime(last.year, last.month, last.day);
    // B5: siehe recordTrackedDay. Ueber die Fruehjahrsumstellung lieferte
    // `.difference().inDays` fuer 47 Stunden eine 1 — eine gerissene Kette
    // wurde am 31.03. noch als lebendig angezeigt.
    final diffDays = daysBetween(today, lastDay);
    return diffDays <= 1 ? currentStreak : 0;
  }

  /// Baut LifetimeStats aus einer public.lifetime_stats-Zeile. Defensiv:
  /// fehlende/falsch-getypte Spalten fallen auf Defaults zurueck, damit
  /// ein altes Schema (vor der Streak-Migration) nicht crasht.
  factory LifetimeStats.fromRow(Map<String, dynamic> row) {
    return LifetimeStats(
      workoutsCompleted: _toInt(row['workouts_completed']),
      mealsLogged: _toInt(row['meals_logged']),
      waterTotalMl: _toInt(row['water_total_ml']),
      stepsRecorded: _toInt(row['steps_recorded']),
      weightLogs: _toInt(row['weight_logs']),
      currentStreak: _toInt(row['current_streak']),
      longestStreak: _toInt(row['longest_streak']),
      lastTrackedDate: _toDate(row['last_workout_date']),
      sessionStart: _toDate(row['session_start']),
    );
  }

  /// Serialisiert fuer ein upsert auf public.lifetime_stats. session_start
  /// wird bewusst NICHT mitgeschrieben — der erste Insert setzt es per
  /// DB-Default, spaetere Saves sollen es nicht ueberschreiben.
  Map<String, dynamic> toRow() {
    return <String, dynamic>{
      'workouts_completed': workoutsCompleted,
      'meals_logged': mealsLogged,
      'water_total_ml': waterTotalMl,
      'steps_recorded': stepsRecorded,
      'weight_logs': weightLogs,
      'current_streak': currentStreak,
      'longest_streak': longestStreak,
      'last_workout_date':
          lastTrackedDate == null ? null : _dateOnly(lastTrackedDate!),
    };
  }

  static int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static DateTime? _toDate(Object? value) {
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  static String _dateOnly(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}
