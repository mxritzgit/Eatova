import 'package:flutter_test/flutter_test.dart';

import 'package:shiftfit/src/models/lifetime_stats.dart';

// TEST-7: LifetimeStats.recordTrackedDay — Streak-Uebergaenge.
// logic_test.dart deckt die Basisfaelle (erster Tag / gestern / idempotent /
// Luecke) ab; hier die zusaetzlichen Uebergaenge: Mehrtages-Kette,
// Datums-Normalisierung (Uhrzeit wird gestrippt), longestStreak-Monotonie
// ueber einen Reset hinweg, Zukunftsdatum als Luecke, Rueckdatierung als
// No-op (Food-Kalender!), die Reparatur des currentStreak==0-Startzustands
// und effectiveStreakOn (Anzeige-Streak: gerissene Kette -> 0).

void main() {
  final mon = DateTime(2026, 6, 1);
  final tue = DateTime(2026, 6, 2);
  final wed = DateTime(2026, 6, 3);
  final thu = DateTime(2026, 6, 4);
  final fri = DateTime(2026, 6, 5);

  group('recordTrackedDay', () {
    test('gestern -> +1 (aufeinanderfolgende Tage zaehlen hoch)', () {
      final s = LifetimeStats().recordTrackedDay(mon).recordTrackedDay(tue);
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 2);
      expect(s.lastTrackedDate, tue);
    });

    test('mehrtaegige Kette Mo..Fr -> Streak 5', () {
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(tue)
          .recordTrackedDay(wed)
          .recordTrackedDay(thu)
          .recordTrackedDay(fri);
      expect(s.currentStreak, 5);
      expect(s.longestStreak, 5);
      expect(s.lastTrackedDate, fri);
    });

    test('heute erneut -> idempotent, Streak haelt (kein Doppel-Zaehlen)', () {
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(tue) // Streak 2
          .recordTrackedDay(tue); // selber Tag nochmal
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 2);
    });

    test('idempotent auch bei abweichender Uhrzeit am selben Kalendertag', () {
      final morning = DateTime(2026, 6, 2, 7, 15);
      final evening = DateTime(2026, 6, 2, 22, 45);
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(morning) // Streak 2
          .recordTrackedDay(evening); // gleicher Tag -> haelt
      expect(s.currentStreak, 2);
      // lastTrackedDate ist auf date-only normalisiert (Mitternacht).
      expect(s.lastTrackedDate, DateTime(2026, 6, 2));
    });

    test('lastTrackedDate wird immer auf date-only (00:00) normalisiert', () {
      final s = LifetimeStats().recordTrackedDay(DateTime(2026, 6, 4, 18, 30));
      expect(s.lastTrackedDate, DateTime(2026, 6, 4));
    });

    test('Luecke -> Reset auf 1, longestStreak bleibt der Highscore', () {
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(tue)
          .recordTrackedDay(wed) // Streak 3
          .recordTrackedDay(fri); // do fehlt -> Luecke
      expect(s.currentStreak, 1);
      expect(s.longestStreak, 3);
      expect(s.lastTrackedDate, fri);
    });

    test('Rueckdatierung (Tag VOR lastTrackedDate) ist ein No-op', () {
      // Food-Kalender: Mahlzeit fuer einen vergangenen Tag nachtragen darf
      // die laufende Streak NICHT anfassen (weder Reset noch Fortschritt).
      final s = LifetimeStats()
          .recordTrackedDay(wed)
          .recordTrackedDay(thu) // Streak 2
          .recordTrackedDay(mon); // Nachtrag fuer Montag
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 2);
      expect(s.lastTrackedDate, thu);
    });

    test('longestStreak ist monoton: neuer Lauf uebertrifft alten Highscore', () {
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(tue) // Highscore 2
          .recordTrackedDay(thu) // Reset auf 1 (Luecke)
          .recordTrackedDay(fri); // 2 — gleich, longest bleibt 2
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 2);

      // Noch ein Tag dran -> 3 > alter Highscore 2.
      final s2 = s.recordTrackedDay(DateTime(2026, 6, 6));
      expect(s2.currentStreak, 3);
      expect(s2.longestStreak, 3);
    });

    test('Zukunftsdatum (>1 Tag voraus) wird wie eine Luecke behandelt', () {
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(fri); // 4 Tage voraus
      expect(s.currentStreak, 1);
      expect(s.lastTrackedDate, fri);
    });

    test('aus geladenem Zustand mit currentStreak 0 fortsetzen -> repariert auf >= 1',
        () {
      // Defensive Branch: wenn ein alter/inkonsistenter Datensatz
      // lastTrackedDate gesetzt aber currentStreak 0 hat, darf derselbe Tag
      // nicht 0 lassen.
      final loaded = LifetimeStats(currentStreak: 0, lastTrackedDate: tue);
      final same = loaded.recordTrackedDay(tue); // gleicher Tag
      expect(same.currentStreak, 1);

      final next = loaded.recordTrackedDay(wed); // Folgetag
      expect(next.currentStreak, 1); // 0 + 1
    });

    test('andere Zaehler bleiben unberuehrt', () {
      final s = LifetimeStats(workoutsCompleted: 9, mealsLogged: 40)
          .recordTrackedDay(mon);
      expect(s.workoutsCompleted, 9);
      expect(s.mealsLogged, 40);
      expect(s.currentStreak, 1);
    });
  });

  group('effectiveStreakOn (Anzeige-Streak)', () {
    test('nie getrackt -> 0', () {
      expect(LifetimeStats().effectiveStreakOn(fri), 0);
    });

    test('heute getrackt -> voller Streak', () {
      final s = LifetimeStats().recordTrackedDay(thu).recordTrackedDay(fri);
      expect(s.effectiveStreakOn(fri), 2);
    });

    test('gestern getrackt, heute noch nicht -> Streak haelt (Gnadenfrist)', () {
      final s = LifetimeStats().recordTrackedDay(wed).recordTrackedDay(thu);
      expect(s.effectiveStreakOn(fri), 2);
    });

    test('vorgestern zuletzt getrackt -> Kette gerissen, Anzeige 0', () {
      final s = LifetimeStats().recordTrackedDay(tue).recordTrackedDay(wed);
      expect(s.effectiveStreakOn(fri), 0);
    });

    test('Uhrzeit im now-Argument wird ignoriert (date-only-Vergleich)', () {
      final s = LifetimeStats().recordTrackedDay(thu);
      expect(s.effectiveStreakOn(DateTime(2026, 6, 5, 23, 59)), 1);
      expect(s.effectiveStreakOn(DateTime(2026, 6, 6, 0, 1)), 0);
    });
  });
}
