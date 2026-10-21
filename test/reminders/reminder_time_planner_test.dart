import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/reminder_time.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/streak_reminder_planner.dart';

// C4: the reminder time is the user's choice now. The planner stays pure and
// takes it as a parameter; the #151 rules (first slot names the streak as it
// stands when it fires, dated one-shots, D10 horizon, IDs per calendar day)
// hold relative to the chosen time instead of 20:00.

void main() {
  const halfTen = ReminderTime(21, 30);

  LifetimeStats lastTracked(DateTime day, {int streak = 3}) =>
      LifetimeStats(currentStreak: streak, lastTrackedDate: day);

  group('Uhrzeit als Parameter', () {
    test('ohne Uhrzeit bleibt es bei 20:00', () {
      final specs = planStreakReminders(
        DateTime(2026, 7, 15, 9, 30),
        LifetimeStats(),
      );
      expect(specs.first.scheduledFor, DateTime(2026, 7, 15, 20));
      expect(ReminderTime.standard, const ReminderTime(20, 0));
    });

    test('alle Slots liegen auf der gewaehlten Stunde und Minute', () {
      final specs = planStreakReminders(
        DateTime(2026, 7, 15, 9, 30),
        LifetimeStats(),
        null,
        halfTen,
      );
      expect(specs, hasLength(streakReminderDayOffsets.length));
      for (final spec in specs) {
        expect(spec.scheduledFor.hour, 21);
        expect(spec.scheduledFor.minute, 30);
        expect(spec.scheduledFor.second, 0);
      }
      expect(specs.first.scheduledFor, DateTime(2026, 7, 15, 21, 30));
    });

    test('der erste Slot: vor der Uhrzeit heute, ab der Uhrzeit morgen', () {
      // (now, chosen time, first slot, second slot)
      for (final (now, time, first, second) in <(
        DateTime,
        ReminderTime,
        DateTime,
        DateTime,
      )>[
        // One minute before: today is still in.
        (
          DateTime(2026, 7, 15, 21, 29),
          halfTen,
          DateTime(2026, 7, 15, 21, 30),
          DateTime(2026, 7, 16, 21, 30),
        ),
        // Exactly at the time: today counts as past, never into the past.
        (
          DateTime(2026, 7, 15, 21, 30),
          halfTen,
          DateTime(2026, 7, 16, 21, 30),
          DateTime(2026, 7, 17, 21, 30),
        ),
        // 20:00 would still plan today; 07:15 is past in the evening.
        (
          DateTime(2026, 7, 15, 19),
          const ReminderTime(7, 15),
          DateTime(2026, 7, 16, 7, 15),
          DateTime(2026, 7, 17, 7, 15),
        ),
        // 00:00 in the morning: the next slot is the coming night.
        (
          DateTime(2026, 7, 15, 9, 30),
          const ReminderTime(0, 0),
          DateTime(2026, 7, 16),
          DateTime(2026, 7, 17),
        ),
        // 23:59 one minute before, across the month boundary.
        (
          DateTime(2026, 7, 31, 23, 58),
          const ReminderTime(23, 59),
          DateTime(2026, 7, 31, 23, 59),
          DateTime(2026, 8, 1, 23, 59),
        ),
      ]) {
        final specs = planStreakReminders(now, LifetimeStats(), null, time);
        expect(specs.first.scheduledFor, first, reason: '$now $time');
        expect(specs[1].scheduledFor, second, reason: '$now $time');
      }
    });

    test('heute schon eingetragen: Start morgen zur gewaehlten Zeit', () {
      final specs = planStreakReminders(
        DateTime(2026, 7, 15, 9),
        lastTracked(DateTime(2026, 7, 15)),
        null,
        halfTen,
      );
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 21, 30));
    });
  });

  group('Serie nach der gewaehlten Uhrzeit (#151)', () {
    test('nach der Zeit, gestern zuletzt eingetragen: Start-Text morgen', () {
      // 08:00 is past 07:15: the first slot is tomorrow, when yesterday's
      // chain is already broken.
      final specs = planStreakReminders(
        DateTime(2026, 7, 15, 8),
        lastTracked(DateTime(2026, 7, 14), streak: 5),
        null,
        const ReminderTime(7, 15),
      );
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 7, 15));
      expect(specs.first.title, 'Serie starten');
      expect(specs.first.body, isNot(contains('5')));
    });

    test(
      'vor der Zeit, gestern zuletzt eingetragen: die Serie ist zu retten',
      () {
        // At 20:00 this would be the same; at 07:15 tonight's slot does not
        // exist, but before it the chain is still alive.
        final specs = planStreakReminders(
          DateTime(2026, 7, 15, 6),
          lastTracked(DateTime(2026, 7, 14), streak: 5),
          null,
          const ReminderTime(7, 15),
        );
        expect(specs.first.scheduledFor, DateTime(2026, 7, 15, 7, 15));
        expect(specs.first.title, 'Serie retten');
        expect(specs.first.body, contains('5-Tage-Serie'));
      },
    );
  });

  group('IDs und Horizont', () {
    test('ein Kalendertag behaelt seine ID, egal zu welcher Zeit', () {
      // A time change must overwrite the pending slots, not add to them.
      final atEight = planStreakReminders(
        DateTime(2026, 7, 15, 9),
        LifetimeStats(),
      );
      final atHalfTen = planStreakReminders(
        DateTime(2026, 7, 15, 9),
        LifetimeStats(),
        null,
        halfTen,
      );
      expect(
        atHalfTen.map((s) => s.id).toList(),
        atEight.map((s) => s.id).toList(),
      );
      expect(atHalfTen.map((s) => s.id).toSet(), hasLength(atHalfTen.length));
    });

    test('der Horizont bleibt unter vier Wochen, auch um 23:59', () {
      final now = DateTime(2026, 7, 15, 9);
      final specs = planStreakReminders(
        now,
        LifetimeStats(),
        null,
        const ReminderTime(23, 59),
      );
      expect(
        daysBetween(specs.last.scheduledFor, now),
        lessThan(streakReminderHorizonDays),
      );
    });
  });

  group('Zeitumstellung (lokale Wandzeit)', () {
    test('21:30 bleibt 21:30 ueber beide Umstellungen 2026', () {
      for (final start in [
        DateTime(2026, 3, 25, 9),
        DateTime(2026, 10, 21, 9),
      ]) {
        final specs = planStreakReminders(
          start,
          LifetimeStats(),
          null,
          halfTen,
        );
        for (var i = 0; i < 7; i++) {
          final when = specs[i].scheduledFor;
          expect(daysBetween(when, start), i, reason: '$start slot $i');
          expect((when.hour, when.minute), (21, 30), reason: '$when');
        }
      }
    });

    // Holds in every zone, and detects slots chained by a day's duration
    // only where the local zone skips 02:00-03:00 on 2026-03-29 (Europe/Berlin
    // and its neighbours), like the test above. It never skips: the CI
    // contract rejects skipped tests, and a UTC runner still checks the rest.
    test(
      'eine Zeit in der Sommerzeit-Luecke verschiebt nur diesen einen Tag',
      () {
        final specs = planStreakReminders(
          DateTime(2026, 3, 29, 0, 10),
          LifetimeStats(),
          null,
          const ReminderTime(2, 30),
        );
        expect(specs.first.scheduledFor.day, 29);
        for (final spec in specs.skip(1)) {
          expect(
            (spec.scheduledFor.hour, spec.scheduledFor.minute),
            (2, 30),
            reason: 'the shifted gap slot must not carry over: $spec',
          );
        }
      },
    );
  });

  group('ReminderTime', () {
    test('tryParse nimmt nur echte Uhrzeiten', () {
      expect(ReminderTime.tryParse(21, 30), halfTen);
      expect(ReminderTime.tryParse(0, 0), const ReminderTime(0, 0));
      expect(ReminderTime.tryParse(23, 59), const ReminderTime(23, 59));
      expect(ReminderTime.tryParse(24, 0), isNull);
      expect(ReminderTime.tryParse(-1, 0), isNull);
      expect(ReminderTime.tryParse(20, 60), isNull);
      expect(ReminderTime.tryParse('20', 0), isNull);
      expect(ReminderTime.tryParse(20.5, 0), isNull);
      expect(ReminderTime.tryParse(null, null), isNull);
    });
  });
}
