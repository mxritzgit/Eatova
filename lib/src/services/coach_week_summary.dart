import 'package:intl/intl.dart';

import '../models/user_profile.dart' show paceLabelForWeeklyRateKg;
import '../models/weight_log.dart';
import 'day_math.dart';
import 'energy_check.dart';

/// One completed local day as the Coach's week block reads it: logged kcal
/// and protein, and the day's budget (base goal plus that day's activity
/// credit, as Today and Trends count it).
typedef CoachWeekDay = ({int kcal, double proteinG, int budgetKcal});

/// Days the week block covers, all before today.
const int coachWeekDays = 7;

const List<String> _weekdays = <String>[
  'Mo',
  'Di',
  'Mi',
  'Do',
  'Fr',
  'Sa',
  'So',
];

/// The seven-day block of the Coach context (C2), German like the rest of
/// the context. Pure; the store binds its state.
///
/// Covers the [coachWeekDays] local days before [today]: today is still
/// running and would read as a short day (Trends B6, the weekly check).
/// [loggedDay] returns a day's totals, or null when nothing is logged that
/// day; an unlogged day is a gap, never 0 kcal.
///
/// A logged day below [EnergyCheck.loggedDayShare] of [goalKcal] counts as
/// logged but is left out of the averages, like the weekly check: such days
/// are almost certainly incomplete. The weight trend is
/// [EnergyCheck.weightRate], so the block never contradicts the check.
/// [trainingsFinishedAt] is null when the user keeps no training history;
/// then the count is left out instead of claiming zero workouts.
String coachWeekSummary({
  required DateTime today,
  required CoachWeekDay? Function(DateTime day) loggedDay,
  required int goalKcal,
  required int proteinGoalG,
  required WeightLog weightLog,
  Iterable<DateTime>? trainingsFinishedAt,
}) {
  final start = startOfDay(today);
  final days = [for (var n = coachWeekDays; n >= 1; n--) addDays(start, -n)];
  final perDay = <String>[];
  final logged = <CoachWeekDay>[];
  for (final day in days) {
    final totals = loggedDay(day);
    perDay.add('${_weekdays[day.weekday - 1]} ${totals?.kcal ?? '–'}');
    if (totals != null) logged.add(totals);
  }
  final threshold = goalKcal * EnergyCheck.loggedDayShare;
  final complete = [
    for (final day in logged)
      if (day.kcal >= threshold) day,
  ];
  final partial = logged.length - complete.length;

  final out = StringBuffer(
    'Letzte $coachWeekDays Tage ohne heute '
    '(${_date(days.first)}–${_date(days.last)}): '
    '${logged.length} von $coachWeekDays Tagen erfasst',
  );
  if (partial > 0) {
    out.write(
      ', davon $partial unter ${(EnergyCheck.loggedDayShare * 100).round()} % '
      'des Ziels (vermutlich unvollständig)',
    );
  }
  out.write('.');
  if (logged.isNotEmpty) {
    out.write(' kcal je Tag (– = nichts erfasst): ${perDay.join(', ')}.');
  }
  if (complete.isNotEmpty) {
    out.write(' ${_averages(complete, partial > 0, goalKcal, proteinGoalG)}');
  } else if (logged.isNotEmpty) {
    out.write(' Kein Tag vollständig erfasst, daher kein Durchschnitt.');
  }
  out.write(' ${_weightLine(EnergyCheck.weightRate(weightLog, today: start))}');
  if (trainingsFinishedAt != null) {
    final count = trainingsFinishedAt.where((finishedAt) {
      final day = finishedAt.toLocal();
      return daysBetween(day, days.first) >= 0 &&
          daysBetween(day, days.last) <= 0;
    }).length;
    out.write(' Trainings in der App: $count.');
  }
  return out.toString();
}

String _averages(
  List<CoachWeekDay> days,
  bool someDaysPartial,
  int goalKcal,
  int proteinGoalG,
) {
  final n = days.length;
  int mean(num Function(CoachWeekDay day) value) =>
      (days.fold<num>(0, (sum, day) => sum + value(day)) / n).round();
  final kind = someDaysPartial ? 'vollständige' : 'erfasste';
  final label = n == 1 ? 'Der eine $kind Tag' : 'Ø der $n ${kind}n Tage';
  final goal = days.every((day) => day.budgetKcal == goalKcal)
      ? 'Ziel $goalKcal kcal'
      : 'Ziel Ø ${mean((day) => day.budgetKcal)} kcal inkl. Aktivitätsbonus';
  final protein = StringBuffer('Protein ${mean((day) => day.proteinG)} g');
  if (proteinGoalG > 0) {
    final hit = days.where((day) => day.proteinG.round() >= proteinGoalG);
    protein.write(
      n == 1
          ? ' (Ziel $proteinGoalG g, ${hit.isEmpty ? 'nicht ' : ''}erreicht)'
          : ' (Ziel $proteinGoalG g, an ${hit.length} von $n Tagen erreicht)',
    );
  }
  return '$label: ${mean((day) => day.kcal)} kcal ($goal), $protein.';
}

String _weightLine(
  ({int weighInDays, double? kgPerWeek, double? noiseKgPerWeek}) rate,
) {
  const window = EnergyCheck.windowDays;
  final n = rate.weighInDays;
  final count = n == 1 ? '1 Wiegetag' : '$n Wiegetage';
  final kgPerWeek = rate.kgPerWeek;
  if (kgPerWeek == null) {
    if (n == 0) {
      return 'Gewichtstrend: keine Wiegung in den letzten $window Tagen.';
    }
    return 'Gewichtstrend: noch nicht bestimmbar ($count in $window Tagen, '
        'nötig sind ${EnergyCheck.minWeighInDays} über mindestens '
        '${EnergyCheck.minWeighInSpanDays} Tage).';
  }
  final noise = rate.noiseKgPerWeek;
  final band = noise != null && noise.isFinite
      ? '±${_kg(noise)} kg/Woche; '
      : '';
  return 'Gewichtstrend über $window Tage: '
      '${paceLabelForWeeklyRateKg(kgPerWeek)} ($band$count).';
}

/// The app's rate grid (0.05 kg, as [paceLabelForWeeklyRateKg]), German.
String _kg(double kg) =>
    NumberFormat('0.##', 'de').format((kg.abs() * 20).round() / 20);

String _date(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.'
    '${day.month.toString().padLeft(2, '0')}.';
