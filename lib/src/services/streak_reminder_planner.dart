import '../l10n/l10n.dart';
import '../models/lifetime_stats.dart';
import 'day_math.dart';
import 'notification_service.dart';

/// Plans the evening streak-saver reminders (PROD-1, purely local).
///
/// PURE: (now, stats) yields a deterministic spec list for
/// [NotificationService.scheduleAll], which is cancel-first.

/// Wall-clock hour the evening reminder fires at (20:00 local).
const int streakReminderHour = 20;

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
/// two specs of one run cannot collide, so a re-schedule overwrites.
const int _streakReminderIdBase = 700;

/// Fixed reference point of the ID arithmetic: arbitrary but immutable.
final DateTime _idEpoch = DateTime(2000, 1, 1);

/// Builds the reminder specs for the coming evenings, one per
/// [streakReminderDayOffsets] entry at [streakReminderHour]:00 local. Already
/// tracked, or past the hour, starts tomorrow — planning into the past fires
/// immediately.
///
/// Only the FIRST day may name the streak number: it fires within ~24 h and
/// every log re-plans, while later slots prove the user did not log.
///
/// Reminders speak the language at PLANNING time; [l10n] defaults to German.
List<NotificationSpec> planStreakReminders(
  DateTime now,
  LifetimeStats stats, [
  AppLocalizations? l10n,
]) {
  final t = l10n ?? deL10n;
  final today = startOfDay(now);

  final last = stats.lastTrackedDate;
  final trackedToday = last != null && startOfDay(last) == today;

  final slotToday = DateTime(
    today.year,
    today.month,
    today.day,
    streakReminderHour,
  );
  final skipToday = trackedToday || !now.isBefore(slotToday);
  // Calendar arithmetic via addDays, not Duration: 20:00 stays 20:00 across
  // any DST edge (see day_math.dart).
  final firstSlot = addDays(slotToday, skipToday ? 1 : 0);

  final streak = stats.effectiveStreakOn(now);

  final specs = <NotificationSpec>[];
  for (var i = 0; i < streakReminderDayOffsets.length; i++) {
    final when = addDays(firstSlot, streakReminderDayOffsets[i]);

    final String title;
    final String body;
    if (i == 0 && streak >= 1) {
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
    ));
  }
  return specs;
}
