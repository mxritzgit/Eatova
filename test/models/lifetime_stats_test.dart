import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/day_math.dart';

// LifetimeStats.recordTrackedDay and effectiveStreakOn: multi-day chains,
// date normalization, longestStreak monotonicity across a reset, back-dating
// as a no-op (food calendar), repair of a currentStreak==0 state, defensive
// row parsing, and the legacy counters that stay wire-compatible.
//
// B5 (2026-08-08): both streak calculations used
// `today.difference(last).inDays` — absolute time, not calendar arithmetic. On
// a 23-hour DST day that reports 0, so the streak stalls, and the day after
// (47h -> 1) effectiveStreakOn still shows a long-broken chain as alive. The
// properties below walk every day of 2024..2032 against `addDays` from
// day_math.dart (the zone-independent calendar shift), so on a machine with a
// DST zone they include both switch days of every year.

void main() {
  final mon = DateTime(2026, 6, 1);
  final tue = DateTime(2026, 6, 2);
  final wed = DateTime(2026, 6, 3);
  final thu = DateTime(2026, 6, 4);
  final fri = DateTime(2026, 6, 5);

  group('recordTrackedDay', () {
    test('Kette Mo..Fr zaehlt jeden Folgetag hoch', () {
      final first = LifetimeStats().recordTrackedDay(mon);
      expect(first.currentStreak, 1);
      expect(first.longestStreak, 1);
      final s = first
          .recordTrackedDay(tue)
          .recordTrackedDay(wed)
          .recordTrackedDay(thu)
          .recordTrackedDay(fri);
      expect(s.currentStreak, 5);
      expect(s.longestStreak, 5);
      expect(s.lastTrackedDate, fri);
    });

    test('idempotent auch bei abweichender Uhrzeit am selben Kalendertag', () {
      final morning = DateTime(2026, 6, 2, 7, 15);
      final evening = DateTime(2026, 6, 2, 22, 45);
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(morning) // streak 2
          .recordTrackedDay(evening); // same day -> holds
      expect(s.currentStreak, 2);
      // lastTrackedDate is normalized to date-only (midnight).
      expect(s.lastTrackedDate, DateTime(2026, 6, 2));
    });

    test('Luecke -> Reset auf 1, longestStreak bleibt der Highscore', () {
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(tue)
          .recordTrackedDay(wed) // streak 3
          .recordTrackedDay(fri); // thu missing -> gap
      expect(s.currentStreak, 1);
      expect(s.longestStreak, 3);
      expect(s.lastTrackedDate, fri);
    });

    test('Rueckdatierung (Tag VOR lastTrackedDate) ist ein No-op', () {
      // Food calendar: logging a meal for a past day must not touch the
      // running streak — neither reset nor advance.
      final s = LifetimeStats()
          .recordTrackedDay(wed)
          .recordTrackedDay(thu) // streak 2
          .recordTrackedDay(mon); // back-dated entry
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 2);
      expect(s.lastTrackedDate, thu);
    });

    test('longestStreak ist monoton: neuer Lauf uebertrifft alten Highscore', () {
      final s = LifetimeStats()
          .recordTrackedDay(mon)
          .recordTrackedDay(tue) // high score 2
          .recordTrackedDay(thu) // reset to 1 (gap)
          .recordTrackedDay(fri); // 2 — equal, longest stays 2
      expect(s.currentStreak, 2);
      expect(s.longestStreak, 2);

      // One more day -> 3 > the old high score of 2.
      final s2 = s.recordTrackedDay(DateTime(2026, 6, 6));
      expect(s2.currentStreak, 3);
      expect(s2.longestStreak, 3);
    });

    test('aus geladenem Zustand mit currentStreak 0 fortsetzen -> repariert auf >= 1',
        () {
      // Defensive branch: an inconsistent record with lastTrackedDate set but
      // currentStreak 0 must not stay at 0 on the same day.
      final loaded = LifetimeStats(currentStreak: 0, lastTrackedDate: tue);
      final same = loaded.recordTrackedDay(tue); // same day
      expect(same.currentStreak, 1);

      final next = loaded.recordTrackedDay(wed); // next day
      expect(next.currentStreak, 1); // 0 + 1
    });
  });

  group('effectiveStreakOn (Anzeige-Streak)', () {
    test('nie getrackt -> 0', () {
      expect(LifetimeStats().effectiveStreakOn(fri), 0);
    });

    test('Uhrzeit im now-Argument wird ignoriert (date-only-Vergleich)', () {
      final s = LifetimeStats().recordTrackedDay(thu);
      expect(s.effectiveStreakOn(DateTime(2026, 6, 5, 23, 59)), 1);
      expect(s.effectiveStreakOn(DateTime(2026, 6, 6, 0, 1)), 0);
    });
  });

  // C7 (2026-08-08): incrementWorkouts(), addWater() and addSteps() lost their
  // callers when the training and today tabs were removed (both later came
  // back without them), so the mutators are gone.
  //
  // The FIELDS stay: workouts_completed / water_total_ml / steps_recorded are
  // `not null` columns in public.lifetime_stats, appear in the explicit select,
  // in the increment_lifetime_stats RPC and in existing LocalCache JSON.
  // Dropping them from the wire format would break cached entries and the
  // table, so they remain frozen pass-throughs. These tests pin that.
  group('C7 — eingefrorene Legacy-Zaehler bleiben wire-kompatibel', () {
    test('fromRow liest die Legacy-Spalten unveraendert ein', () {
      final row = <String, dynamic>{
        'workouts_completed': 42,
        'meals_logged': 7,
        'water_total_ml': 12000,
        'steps_recorded': 310000,
        'weight_logs': 3,
        'current_streak': 5,
        'longest_streak': 9,
        'last_workout_date': '2026-06-04',
      };

      final s = LifetimeStats.fromRow(row);

      expect(s.workoutsCompleted, 42);
      expect(s.waterTotalMl, 12000);
      expect(s.stepsRecorded, 310000);
      expect(s.mealsLogged, 7);
      expect(s.weightLogs, 3);
      expect(s.currentStreak, 5);
      expect(s.longestStreak, 9);
      expect(s.lastTrackedDate, DateTime(2026, 6, 4));
    });

    test('fromRow ist defensiv bei fehlenden und falsch typisierten Spalten',
        () {
      final back = LifetimeStats.fromRow(<String, dynamic>{
        'workouts_completed': '5', // string instead of int
        'meals_logged': null,
      });
      expect(back.workoutsCompleted, 5);
      expect(back.mealsLogged, 0);
      expect(back.currentStreak, 0);
      expect(back.lastTrackedDate, isNull);
    });

    test('lebende Mutatoren lassen die Legacy-Zaehler unberuehrt', () {
      final s = LifetimeStats(
        workoutsCompleted: 42,
        waterTotalMl: 12000,
        stepsRecorded: 310000,
      ).incrementMeals().incrementWeightLogs().recordTrackedDay(mon);

      expect(s.workoutsCompleted, 42);
      expect(s.waterTotalMl, 12000);
      expect(s.stepsRecorded, 310000);
      expect(s.mealsLogged, 1);
      expect(s.weightLogs, 1);
    });
  });

  group('B5 — Property gegen das UTC-Orakel (zonenunabhaengig)', () {
    // `addDays` from day_math.dart is the zone-independent calendar shift
    // (itself pinned against a UTC oracle). Both streak calculations must
    // follow it on every day, in UTC and in a DST zone alike.
    final start = DateTime.utc(2024, 1, 1);
    final ende = DateTime.utc(2032, 12, 31);

    test('recordTrackedDay: der Folgetag zaehlt an jedem Tag +1', () {
      var cursor = start;
      var geprueft = 0;
      while (!cursor.isAfter(ende)) {
        final last = DateTime(cursor.year, cursor.month, cursor.day);
        final s = LifetimeStats(
          currentStreak: 4,
          longestStreak: 9,
          lastTrackedDate: last,
        ).recordTrackedDay(addDays(last, 1));
        expect(s.currentStreak, 5,
            reason: 'Folgetag von $last fuehrt die Streak nicht fort');
        geprueft++;
        cursor = cursor.add(const Duration(days: 1));
      }
      expect(geprueft, greaterThan(3000));
    });

    test('recordTrackedDay: eine Zwei-Tages-Luecke resettet an jedem Tag', () {
      var cursor = start;
      while (!cursor.isAfter(ende)) {
        final last = DateTime(cursor.year, cursor.month, cursor.day);
        final s = LifetimeStats(
          currentStreak: 4,
          longestStreak: 9,
          lastTrackedDate: last,
        ).recordTrackedDay(addDays(last, 2));
        expect(s.currentStreak, 1,
            reason: 'Luecke nach $last gilt faelschlich als Folgetag');
        cursor = cursor.add(const Duration(days: 1));
      }
    });

    test('effectiveStreakOn: haelt +1 Tag, ist ab +2 Tagen 0', () {
      var cursor = start;
      while (!cursor.isAfter(ende)) {
        final last = DateTime(cursor.year, cursor.month, cursor.day);
        final s = LifetimeStats(currentStreak: 7, lastTrackedDate: last);
        expect(s.effectiveStreakOn(last), 7, reason: 'heute, $last');
        expect(s.effectiveStreakOn(addDays(last, 1)), 7,
            reason: 'Gnadenfrist nach $last');
        expect(s.effectiveStreakOn(addDays(last, 2)), 0,
            reason: 'gerissene Kette nach $last wird noch angezeigt');
        cursor = cursor.add(const Duration(days: 1));
      }
    });
  });

  // 2026-10-19: an entry for yesterday tracks yesterday when it continues
  // the chain; the server's record_tracking_day moves the streak the same way.
  group('Nachtrag fuer gestern', () {
    final now = DateTime(2026, 6, 5, 9); // Friday morning

    test('setzt die Kette fort, wenn sie vorgestern endete', () {
      final s = LifetimeStats(currentStreak: 3, lastTrackedDate: wed);
      expect(s.backfillContinuesStreak(thu, now: now), isTrue);
      expect(s.yesterdayRescuesStreak(now), isTrue);
      expect(s.effectiveStreakOn(now), 0, reason: 'shown as broken until then');
      final next = s.recordTrackedDay(thu);
      expect(next.currentStreak, 4);
      expect(next.effectiveStreakOn(now), 4);
    });

    test('gestern schon gezaehlt ist idempotent, rettet aber nichts', () {
      final s = LifetimeStats(currentStreak: 3, lastTrackedDate: thu);
      expect(s.backfillContinuesStreak(thu, now: now), isTrue);
      expect(s.yesterdayRescuesStreak(now), isFalse);
    });

    test('eine laengst gerissene Kette bleibt ein Nachtrag', () {
      final s = LifetimeStats(currentStreak: 3, lastTrackedDate: tue);
      expect(s.backfillContinuesStreak(thu, now: now), isFalse);
      expect(s.yesterdayRescuesStreak(now), isFalse);
    });

    test('nach dem ersten Eintrag heute kann gestern nicht mehr zaehlen', () {
      final s = LifetimeStats(currentStreak: 1, lastTrackedDate: fri);
      expect(s.backfillContinuesStreak(thu, now: now), isFalse);
      expect(s.yesterdayRescuesStreak(now), isFalse);
    });

    test('nur gestern, kein aelterer Tag und ohne Serie keine Rettung', () {
      final s = LifetimeStats(currentStreak: 3, lastTrackedDate: tue);
      expect(s.backfillContinuesStreak(wed, now: now), isFalse);
      expect(LifetimeStats().backfillContinuesStreak(thu, now: now), isFalse);
      expect(
        LifetimeStats(lastTrackedDate: wed).yesterdayRescuesStreak(now),
        isFalse,
      );
    });

    test('jeder Tag eines Jahrzehnts gegen das UTC-Orakel', () {
      var cursor = DateTime.utc(2024, 1, 1);
      while (!cursor.isAfter(DateTime.utc(2032, 12, 31))) {
        final last = DateTime(cursor.year, cursor.month, cursor.day);
        final s = LifetimeStats(currentStreak: 2, lastTrackedDate: last);
        final now = addDays(last, 2);
        expect(
          s.backfillContinuesStreak(addDays(last, 1), now: now),
          isTrue,
          reason: 'yesterday after $last',
        );
        expect(s.yesterdayRescuesStreak(now), isTrue, reason: '$last');
        expect(s.yesterdayRescuesStreak(addDays(last, 3)), isFalse);
        cursor = cursor.add(const Duration(days: 1));
      }
    });
  });
}
