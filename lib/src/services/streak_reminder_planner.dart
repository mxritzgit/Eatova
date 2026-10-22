import '../l10n/l10n.dart';
import '../models/lifetime_stats.dart';
import '../models/reminder_time.dart';
import 'app_entry.dart';
import 'complete_day.dart';
import 'day_math.dart';
import 'notification_service.dart';

/// Plans the evening streak-saver reminders (PROD-1, purely local).
///
/// PURE: (now, stats, time) yields a deterministic spec list for
/// [NotificationService.scheduleAll], which is cancel-first.

/// Default wall-clock hour of the reminder (20:00 local) until the user picks
/// another time (C4, [ReminderTime]).
const int streakReminderHour = ReminderTime.defaultHour;

/// Hard cap of the planning horizon in calendar days (D10).
///
/// Four weeks: shorter misses a holiday or sick week, the very case the
/// reminder exists for; longer is spam and pushes users into the D11 blocked
/// state. Finite by necessity — a real repeat via `matchDateTimeComponents`
/// is OS-managed and unstoppable without the app.
const int streakReminderHorizonDays = 28;

/// Day offsets from the first planned evening: daily for a week, then weekly.
///
/// The taper is deliberate — after week one the streak is broken anyway and
/// daily nudges are just pressure. 10 slots also stay far below the iOS limit
/// of 64 pending local notifications.
///
/// Dated single slots, not `DateTimeComponents.time`: that drops the date and
/// repeats only the time, turning n specs into n daily notifications forever.
const List<int> streakReminderDayOffsets = <int>[
  0, 1, 2, 3, 4, 5, 6, // first week: every evening
  13, 20, 27, // then weekly, hard stop after 4 weeks
];

/// ID base: ID = base + (calendar day mod [streakReminderHorizonDays]), i.e.
/// 700..727. Deterministic per day, and since the horizon spans no more days,
/// two specs of one run cannot collide, so a re-schedule overwrites. Must
/// stay inside the nudge range reminder paths cancel ([reminderNudgeIdCount]
/// ids from [reminderNudgeIdFirst]); the weigh-in reminder follows at 728.
const int _streakReminderIdBase = reminderNudgeIdFirst;

/// Fixed reference point of the ID arithmetic: arbitrary but immutable.
final DateTime _idEpoch = DateTime(2000, 1, 1);

/// Builds the reminder specs for the coming days, one per
/// [streakReminderDayOffsets] entry at [time] local (default 20:00). Already
/// tracked, or at or past that time, starts tomorrow — planning into the past
/// fires immediately.
///
/// Only the FIRST day may name the streak number: it fires within ~24 h and
/// every log re-plans, while later slots prove the user did not log.
///
/// A half-logged today (2026-10-19): with [todayIntake] below the
/// complete-day rule ([isCompleteDay]), today's slot stays and asks
/// whether something is missing, naming the kcal logged so far; the streak
/// line moves to tomorrow's slot, since today already keeps the chain.
/// Local notifications are planned ahead and never run code when they fire,
/// so the text is the state at PLANNING time: the store re-plans whenever
/// today's entries change, on start and on resume, and a slot whose day got
/// complete meanwhile is replaced.
///
/// Reminders speak the language at PLANNING time; [l10n] defaults to German.
/// A tap opens Food's add sheet ([AppEntry.logMeal]): the text asks for an
/// entry, so the tap leads to one.
List<NotificationSpec> planStreakReminders(
  DateTime now,
  LifetimeStats stats, [
  AppLocalizations? l10n,
  ReminderTime time = ReminderTime.standard,
  ({int kcal, int goalKcal})? todayIntake,
]) {
  final t = l10n ?? deL10n;
  final today = startOfDay(now);

  final last = stats.lastTrackedDate;
  final trackedToday = last != null && startOfDay(last) == today;
  final beforeTodaysSlot = now.isBefore(_slotOn(today, 0, time));
  final intake = todayIntake;
  final halfToday =
      trackedToday &&
      beforeTodaysSlot &&
      intake != null &&
      !isCompleteDay(intakeKcal: intake.kcal, goalKcal: intake.goalKcal);

  final skipToday = (trackedToday && !halfToday) || !beforeTodaysSlot;
  final firstOffset = skipToday ? 1 : 0;
  // The slot that may name the streak: the first one, or tomorrow's after
  // a half-logged today.
  final streakIndex = halfToday ? 1 : 0;
  final streakSlot = _slotOn(
    today,
    firstOffset + streakReminderDayOffsets[streakIndex],
    time,
  );

  // The streak as it stands when that slot fires, not now: past the time
  // without a log today, tomorrow's slot finds yesterday's chain broken.
  final streak = stats.effectiveStreakOn(streakSlot);

  final specs = <NotificationSpec>[];
  for (var i = 0; i < streakReminderDayOffsets.length; i++) {
    final when =
        _slotOn(today, firstOffset + streakReminderDayOffsets[i], time);

    final String title;
    final String body;
    if (i == 0 && halfToday) {
      title = t.reminderHalfDayTitle;
      body = t.reminderHalfDayBody(intake.kcal);
    } else if (i == streakIndex && streak >= 1) {
      title = t.notifStreakSaveTitle;
      body = t.notifStreakSaveBody(streak);
    } else {
      title = t.notifStreakStartTitle;
      body = t.notifStreakStartBody;
    }

    specs.add(NotificationSpec(
      id: _streakReminderIdBase +
          daysBetween(when, _idEpoch) % streakReminderHorizonDays,
      title: title,
      body: body,
      scheduledFor: when,
      payload: AppEntry.logMeal.id,
    ));
  }
  return specs;
}

/// [day] shifted by [offset] calendar days, at [time] local.
///
/// Calendar arithmetic via the constructor's day overflow, not Duration, so
/// the wall-clock time holds across DST (see day_math.dart). Built from the
/// date parts for every slot: on a day where [time] falls into a DST gap the
/// constructor moves that one slot, and the next slot is back on [time]
/// instead of inheriting the shift.
DateTime _slotOn(DateTime day, int offset, ReminderTime time) =>
    DateTime(day.year, day.month, day.day + offset, time.hour, time.minute);
