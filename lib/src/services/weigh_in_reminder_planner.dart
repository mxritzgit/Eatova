import '../l10n/l10n.dart';
import '../models/reminder_time.dart';
import 'app_entry.dart';
import 'day_math.dart';
import 'notification_service.dart';
import 'streak_reminder_planner.dart' show streakReminderHorizonDays;

/// Plans the opt-in weigh-in reminder (review 2026-10-22).
///
/// The weekly check needs weigh-ins spread over two weeks, and its explainer
/// asks for 2–3 a week before breakfast. Whoever forgets to weigh never gets
/// a check, so this reminder offers exactly that rhythm: Monday and Thursday
/// mornings, at most two extra notifications a week. Pure like the streak
/// planner, and planned through the same cancel-first
/// [NotificationService.scheduleAll], so both lists always go in together.

/// The weekdays that get a reminder, in id slot order.
const List<int> weighInReminderWeekdays = <int>[
  DateTime.monday,
  DateTime.thursday,
];

/// Local wall-clock time of the reminder: before breakfast.
const ReminderTime weighInReminderTime = ReminderTime(7, 30);

/// The ids right after the streak reminders' range: one Monday and one
/// Thursday per week over the four-week horizon,
/// `first + (week mod 4) * 2 + weekday slot`. The horizon holds exactly four
/// of each weekday, so one run never reuses an id, and a weekday keeps its id
/// across runs, so a re-plan overwrites instead of duplicating.
const int weighInReminderIdFirst =
    reminderNudgeIdFirst + streakReminderHorizonDays;
const int weighInReminderIdCount = 8;

/// A Monday: week numbers count from it.
final DateTime _weekEpoch = DateTime(2000, 1, 3);

/// The weigh-in reminders from [now] over the streak reminders' horizon (four
/// weeks; every app start, resume and log re-plans). A slot at or before
/// [now] is skipped, and so is today's once [weighedToday]. Mondays name the
/// weekly check, which shows its result on that day.
///
/// The texts use the language at planning time; [l10n] defaults to German.
List<NotificationSpec> planWeighInReminders(
  DateTime now, {
  AppLocalizations? l10n,
  bool weighedToday = false,
}) {
  final t = l10n ?? deL10n;
  final today = startOfDay(now);
  final specs = <NotificationSpec>[];
  for (var offset = 0; offset < streakReminderHorizonDays; offset++) {
    // Calendar arithmetic, not Duration, so the time holds across DST.
    final when = DateTime(
      today.year,
      today.month,
      today.day + offset,
      weighInReminderTime.hour,
      weighInReminderTime.minute,
    );
    final slot = weighInReminderWeekdays.indexOf(when.weekday);
    if (slot < 0 || !when.isAfter(now)) continue;
    if (offset == 0 && weighedToday) continue;
    final week = daysBetween(when, _weekEpoch) ~/ 7;
    specs.add(
      NotificationSpec(
        id: weighInReminderIdFirst + (week % 4) * 2 + slot,
        title: t.weighInReminderTitle,
        body: when.weekday == DateTime.monday
            ? t.weighInReminderMondayBody
            : t.weighInReminderThursdayBody,
        scheduledFor: when,
        payload: AppEntry.weighIn.id,
      ),
    );
  }
  return specs;
}
