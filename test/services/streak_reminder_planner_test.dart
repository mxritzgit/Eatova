import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/streak_reminder_planner.dart';

// Streak-Retter-Planner: pure Funktion (now, stats) -> Specs fuer die
// kommenden Abende um 20:00. Kernfaelle: heute-schon-getrackt und
// nach-20-Uhr lassen den heutigen Slot aus (nie in die Vergangenheit
// planen), IDs sind pro Kalendertag deterministisch (Re-Schedule ohne
// Duplikate), und die konkrete Streak-Zahl steht NUR im ersten Body
// (danach waere sie stale).
//
// D10 (Review 2026-08-08): Der Horizont lag bei 7 Tagen und wurde nur bei
// Kaltstart oder Mahlzeit-Log nachgefuellt. Wer eine Woche weder loggt noch
// die App oeffnet, verlor genau die Erinnerung, die ihn zurueckholen sollte.
// Der Horizont reicht jetzt vier Wochen (erste Woche taeglich, danach
// woechentlich) und endet dort bewusst — siehe streak_reminder_planner.dart.

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

    test('die ersten sieben Specs liegen an aufeinanderfolgenden Tagen um 20:00',
        () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      for (var i = 0; i < 7; i++) {
        expect(specs[i].scheduledFor, DateTime(2026, 7, 15 + i, 20));
      }
    });

    test('alle Specs liegen um exakt 20:00 lokaler Wandzeit', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      for (final spec in specs) {
        expect(spec.scheduledFor.hour, streakReminderHour);
        expect(spec.scheduledFor.minute, 0);
        expect(spec.scheduledFor.second, 0);
      }
    });
  });

  group('D10 — Horizont ueberlebt eine Woche ohne App-Oeffnung', () {
    test('es wird ueber Tag 7 hinaus geplant', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      // Der alte 7-Tage-Horizont endete am 21.07. Wer bis dahin weder loggt
      // noch die App oeffnet, bekam ab dem 22.07. nichts mehr.
      final beyondWeek = specs
          .where((s) => s.scheduledFor.isAfter(DateTime(2026, 7, 21, 20)))
          .toList();
      expect(beyondWeek, isNotEmpty,
          reason: 'genau die Vernachlaessigung, die den Reminder noetig macht, '
              'hat ihn bisher abgeschaltet');
    });

    test('am achten Abend ohne App-Oeffnung liegt noch ein Reminder vor', () {
      // Simuliert den Nutzer, der am 15.07. zuletzt geplant hat und danach
      // eine Woche verschwindet: am 23.07. muss noch etwas ausstehen.
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      final stillPending = specs
          .where((s) => !s.scheduledFor.isBefore(DateTime(2026, 7, 23)))
          .toList();
      expect(stillPending, isNotEmpty);
    });

    test('Obergrenze: nichts liegt weiter als der Horizont in der Zukunft', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      final last = specs.last.scheduledFor;
      expect(
        daysBetween(last, wedMorning),
        lessThan(streakReminderHorizonDays),
        reason: 'wer seit Wochen weg ist, soll nicht ewig genudged werden',
      );
      expect(daysBetween(last, wedMorning), greaterThanOrEqualTo(21),
          reason: 'der Ausstieg darf nicht vor einem Monat greifen');
    });

    test('Taper: erste Woche taeglich, danach hoechstens woechentlich', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      final offsets = specs
          .map((s) => daysBetween(s.scheduledFor, specs.first.scheduledFor))
          .toList();
      expect(offsets.take(7).toList(), <int>[0, 1, 2, 3, 4, 5, 6]);
      for (var i = 7; i < offsets.length; i++) {
        expect(offsets[i] - offsets[i - 1], greaterThanOrEqualTo(7),
            reason: 'nach der ersten Woche nur noch ein sanfter Anker');
      }
    });

    test('die Liste bleibt klein genug fuer das iOS-64-Pending-Limit', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      expect(specs.length, lessThanOrEqualTo(64));
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

    test('IDs sind innerhalb eines Laufs eindeutig', () {
      final specs = planStreakReminders(wedMorning, LifetimeStats());
      final ids = specs.map((s) => s.id).toSet();
      expect(ids, hasLength(specs.length));
    });

    test('ID haengt am Kalendertag, nicht an der Listenposition', () {
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
      }
    });

    test(
        'D10: ab dem zweiten Abend behauptet KEIN Text mehr, es gaebe eine '
        'laufende Serie', () {
      // Feuert Spec i>=1, dann hat der Nutzer seit der Planung nicht geloggt
      // (jeder Log plant neu) — die Serie ist zu diesem Zeitpunkt beweisbar
      // gerissen. Ein Text wie „Deine Streak wartet" waere dauerhaft falsch,
      // und je weiter hinten im Horizont, desto falscher.
      final stats = statsWithStreak(
        lastTracked: DateTime(2026, 7, 14),
        days: 12,
      );
      final specs = planStreakReminders(wedMorning, stats);
      for (final spec in specs.skip(1)) {
        expect(spec.title, 'Streak starten');
        expect(spec.body, 'Ein Log genügt, um deine Serie zu starten.');
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
