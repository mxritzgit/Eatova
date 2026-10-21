import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/app_entry.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/streak_reminder_planner.dart';

// Streak rescue planner: pure (now, stats) -> specs for the coming evenings
// at 20:00. Already tracked today and after 20:00 both skip today's slot, IDs
// are deterministic per calendar day so a re-schedule does not duplicate, and
// the streak number is in the FIRST body only. D10 (Review 2026-08-08): the
// 7-day horizon was refilled only on cold start or meal log, losing the
// reminder meant to bring an inactive user back. Now four weeks.

void main() {
  // Wednesday 2026-07-15, morning and evening as reference points.
  final wedMorning = DateTime(2026, 7, 15, 9, 30);
  final wedEvening = DateTime(2026, 7, 15, 21, 10);

  LifetimeStats statsWithStreak({required DateTime lastTracked, int days = 3}) =>
      LifetimeStats(currentStreak: days, lastTrackedDate: lastTracked);

  group('planStreakReminders — Tagesauswahl', () {
    test('vor 20:00, heute noch nicht getrackt -> heutiger Abend ist dabei',
        () {
      final stats = statsWithStreak(lastTracked: DateTime(2026, 7, 14));
      final specs = planStreakReminders(wedMorning, stats);
      expect(specs.first.scheduledFor, DateTime(2026, 7, 15, 20));
    });

    test('heute schon getrackt -> heutiger Reminder faellt aus, Start morgen',
        () {
      final stats = statsWithStreak(lastTracked: DateTime(2026, 7, 15));
      final specs = planStreakReminders(wedMorning, stats);
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 20));
    });

    test('nach 20:00, nicht getrackt -> heutiger faellt aus (nie Vergangenheit)',
        () {
      final stats = statsWithStreak(lastTracked: DateTime(2026, 7, 14));
      final specs = planStreakReminders(wedEvening, stats);
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 20));
    });

    test('exakt 20:00 zaehlt als vorbei (Slot waere nicht mehr in der Zukunft)',
        () {
      final specs = planStreakReminders(
        DateTime(2026, 7, 15, 20),
        LifetimeStats(),
      );
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 20));
    });

    test('erste Woche jeden Abend, danach woechentlich, immer um 20:00', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      for (var i = 0; i < 7; i++) {
        expect(specs[i].scheduledFor, DateTime(2026, 7, 15 + i, 20));
      }
      for (final spec in specs) {
        expect(spec.scheduledFor.hour, streakReminderHour);
        expect(spec.scheduledFor.minute, 0);
        expect(spec.scheduledFor.second, 0);
      }
      final offsets = specs
          .map((s) => daysBetween(s.scheduledFor, specs.first.scheduledFor))
          .toList();
      for (var i = 7; i < offsets.length; i++) {
        expect(offsets[i] - offsets[i - 1], greaterThanOrEqualTo(7),
            reason: 'nach der ersten Woche nur noch ein sanfter Anker');
      }
    });
  });

  group('D10 — Horizont ueberlebt eine Woche ohne App-Oeffnung', () {
    test('ueber den achten Abend hinaus, aber unter vier Wochen und dem '
        'iOS-64-Pending-Limit', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      // Last planned 07-15, gone a week: 07-23 must still have something.
      // The old 7-day horizon ended on 07-21 and left 07-22 on empty.
      expect(
        specs.where((s) => !s.scheduledFor.isBefore(DateTime(2026, 7, 23))),
        isNotEmpty,
        reason: 'genau die Vernachlaessigung, die den Reminder noetig macht, '
            'hat ihn bisher abgeschaltet',
      );
      final last = specs.last.scheduledFor;
      expect(
        daysBetween(last, wedMorning),
        lessThan(streakReminderHorizonDays),
        reason: 'wer seit Wochen weg ist, soll nicht ewig genudged werden',
      );
      expect(daysBetween(last, wedMorning), greaterThanOrEqualTo(21),
          reason: 'der Ausstieg darf nicht vor einem Monat greifen');
      expect(specs.length, lessThanOrEqualTo(64));
    });
  });

  test('ein Tipp auf jede Erinnerung oeffnet das Eintragen', () {
    final specs = planStreakReminders(
      wedMorning,
      statsWithStreak(lastTracked: DateTime(2026, 7, 14)),
    );
    expect(specs.map((s) => s.payload).toSet(), {AppEntry.logMeal.id});
  });

  group('planStreakReminders — IDs', () {
    test('IDs sind innerhalb eines Laufs eindeutig', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      final ids = specs.map((s) => s.id).toSet();
      expect(ids, hasLength(specs.length));
    });

    test('ID haengt am Kalendertag, nicht an der Listenposition', () {
      // Tracked vs. not shifts the window a day, yet a calendar day keeps
      // its ID, so a re-schedule overwrites rather than duplicates.
      final untracked = planStreakReminders(
        wedMorning,
        statsWithStreak(lastTracked: DateTime(2026, 7, 14)),
      );
      final tracked = planStreakReminders(
        wedMorning,
        statsWithStreak(lastTracked: DateTime(2026, 7, 15)),
      );
      // Thursday 07-16 is planned in both runs, so same ID.
      final thuA =
          untracked.firstWhere((s) => s.scheduledFor.day == 16);
      final thuB = tracked.firstWhere((s) => s.scheduledFor.day == 16);
      expect(thuA.id, thuB.id);
    });
  });

  group('planStreakReminders — Texte', () {
    test(
        'lebende Streak: die Zahl nur im ersten Body; ab dem zweiten Abend '
        'behauptet KEIN Text mehr eine laufende Serie (D10)', () {
      // If spec i>=1 fires the user has not logged since planning (every log
      // re-plans), so the streak is provably broken.
      final stats = statsWithStreak(
        lastTracked: DateTime(2026, 7, 14),
        days: 12,
      );
      final specs = planStreakReminders(wedMorning, stats);
      expect(specs.first.body, contains('12-Tage-Serie'));
      for (final spec in specs.skip(1)) {
        expect(spec.title, 'Serie starten');
        expect(spec.body, 'Ein Eintrag genügt, um deine Serie zu starten.');
      }
    });

    test('gerissene oder nie begonnene Kette -> sanfter Start-Text ohne Zahl',
        () {
      // Last tracked two days ago: currentStreak still reads 3 while the
      // displayed streak is 0, so the planner must not say 3.
      final stats = statsWithStreak(
        lastTracked: DateTime(2026, 7, 13),
        days: 3,
      );
      final specs = planStreakReminders(wedMorning, stats);
      for (final spec in specs) {
        expect(spec.title, 'Serie starten');
        expect(spec.body, 'Ein Eintrag genügt, um deine Serie zu starten.');
      }
      // Never tracked reads the same.
      expect(
        planStreakReminders(wedMorning, LifetimeStats()).first.body,
        'Ein Eintrag genügt, um deine Serie zu starten.',
      );
    });

    test(
        'nach 20:00, gestern zuletzt getrackt: morgen ist die Kette gerissen '
        '-> Start-Text statt "rette deine Serie"', () {
      // Planned tonight (resume or cold start after the reminder): the first
      // slot is tomorrow, when yesterday's 5-day chain no longer exists.
      final stats = statsWithStreak(
        lastTracked: DateTime(2026, 7, 14),
        days: 5,
      );
      final specs = planStreakReminders(wedEvening, stats);
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 20));
      expect(specs.first.title, 'Serie starten');
      expect(specs.first.body, 'Ein Eintrag genügt, um deine Serie zu starten.');
    });

    test('heute getrackt: erster geplanter Tag (morgen) traegt die Zahl', () {
      final stats = statsWithStreak(
        lastTracked: DateTime(2026, 7, 15),
        days: 4,
      );
      final specs = planStreakReminders(wedMorning, stats);
      expect(specs.first.title, 'Serie retten');
      expect(specs.first.body, contains('4-Tage-Serie'));
    });
  });
}
