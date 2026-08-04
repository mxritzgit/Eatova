import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/streak_reminder_planner.dart';

// Streak-Retter-Planner: pure Funktion (now, stats) -> Specs fuer die
// naechsten 7 Abende um 20:00. Kernfaelle: heute-schon-getrackt und
// nach-20-Uhr lassen den heutigen Slot aus (nie in die Vergangenheit
// planen), IDs sind pro Wochentag deterministisch (Re-Schedule ohne
// Duplikate), und die konkrete Streak-Zahl steht NUR im ersten Body
// (danach waere sie stale).

void main() {
  // Mittwoch, 15.07.2026 — Vormittag bzw. Abend als Referenz-Zeitpunkte.
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

    test('immer genau 7 Specs, alle um 20:00 an aufeinanderfolgenden Tagen',
        () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      expect(specs, hasLength(7));
      for (var i = 0; i < specs.length; i++) {
        expect(specs[i].scheduledFor, DateTime(2026, 7, 15 + i, 20));
      }
    });
  });

  group('planStreakReminders — IDs', () {
    test('deterministisch: zwei Aufrufe mit gleicher Eingabe -> gleiche IDs',
        () {
      final stats = statsWithStreak(lastTracked: DateTime(2026, 7, 14));
      final a = planStreakReminders(wedMorning, stats);
      final b = planStreakReminders(wedMorning, stats);
      expect(a.map((s) => s.id).toList(), b.map((s) => s.id).toList());
    });

    test('IDs sind pro Wochentag stabil und innerhalb eines Laufs eindeutig',
        () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      final ids = specs.map((s) => s.id).toSet();
      // 7 aufeinanderfolgende Tage -> 7 verschiedene Wochentage -> 7 IDs.
      expect(ids, hasLength(7));
      for (final spec in specs) {
        expect(spec.id, 700 + spec.scheduledFor.weekday);
      }
    });

    test('Wochentags-ID haengt am Kalendertag, nicht an der Listenposition',
        () {
      // Heute getrackt vs. nicht getrackt verschiebt das Fenster um einen
      // Tag — derselbe Kalendertag behaelt trotzdem dieselbe ID, damit ein
      // Re-Schedule alte Eintraege ueberschreibt statt zu duplizieren.
      final untracked = planStreakReminders(
        wedMorning,
        statsWithStreak(lastTracked: DateTime(2026, 7, 14)),
      );
      final tracked = planStreakReminders(
        wedMorning,
        statsWithStreak(lastTracked: DateTime(2026, 7, 15)),
      );
      // Donnerstag 16.07. ist in beiden Laeufen geplant — gleiche ID.
      final thuA =
          untracked.firstWhere((s) => s.scheduledFor.day == 16);
      final thuB = tracked.firstWhere((s) => s.scheduledFor.day == 16);
      expect(thuA.id, thuB.id);
    });
  });

  group('planStreakReminders — Texte', () {
    test('lebende Streak: konkrete Zahl NUR im ersten Body', () {
      final stats = statsWithStreak(
        lastTracked: DateTime(2026, 7, 14),
        days: 5,
      );
      final specs = planStreakReminders(wedMorning, stats);
      expect(specs.first.body, contains('5-Tage-Serie'));
      for (final spec in specs.skip(1)) {
        expect(spec.body, isNot(contains('5')));
        expect(spec.body, 'Heute schon geloggt? Deine Streak wartet.');
      }
    });

    test('gerissene Kette (effectiveStreak 0) -> sanfter Start-Text ohne Zahl',
        () {
      // Zuletzt vorgestern getrackt: currentStreak steht noch auf 3, aber
      // die Anzeige-Streak ist 0 — der Planner darf nicht "3 retten" sagen.
      final stats = statsWithStreak(
        lastTracked: DateTime(2026, 7, 13),
        days: 3,
      );
      final specs = planStreakReminders(wedMorning, stats);
      for (final spec in specs) {
        expect(spec.title, 'Streak starten');
        expect(spec.body, 'Ein Log genügt, um deine Serie zu starten.');
      }
    });

    test('nie getrackt -> Start-Text', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      expect(specs.first.body, 'Ein Log genügt, um deine Serie zu starten.');
    });

    test('heute getrackt: erster geplanter Tag (morgen) traegt die Zahl', () {
      final stats = statsWithStreak(
        lastTracked: DateTime(2026, 7, 15),
        days: 4,
      );
      final specs = planStreakReminders(wedMorning, stats);
      expect(specs.first.title, 'Streak retten');
      expect(specs.first.body, contains('4-Tage-Serie'));
    });
  });
}
