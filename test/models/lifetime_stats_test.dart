import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/day_math.dart';

// TEST-7: LifetimeStats.recordTrackedDay — Streak-Uebergaenge.
// logic_test.dart deckt die Basisfaelle (erster Tag / gestern / idempotent /
// Luecke) ab; hier die zusaetzlichen Uebergaenge: Mehrtages-Kette,
// Datums-Normalisierung (Uhrzeit wird gestrippt), longestStreak-Monotonie
// ueber einen Reset hinweg, Zukunftsdatum als Luecke, Rueckdatierung als
// No-op (Food-Kalender!), die Reparatur des currentStreak==0-Startzustands
// und effectiveStreakOn (Anzeige-Streak: gerissene Kette -> 0).
//
// B5 (2026-08-08): Beide Streak-Rechnungen liefen ueber
// `today.difference(last).inDays` — Absolutzeit statt Kalenderarithmetik.
// Ueber die Fruehjahrsumstellung (Europe/Berlin, Sonntag 29.03.2026, ein
// 23-Stunden-Tag) misst das 23h und meldet 0 Tage. Folge: die Streak steht am
// 30.03. still, und am 31.03. (47h -> 1) zeigt effectiveStreakOn eine laengst
// gerissene Kette noch als lebendig an.
//
// Zonen-Unabhaengigkeit (Technik aus test/services/day_math_test.dart): die
// Beleg-Tests unten sind auf einer Maschine MIT Fruehjahrsumstellung am
// 29.03.2026 rot und auf einer UTC-Maschine (CI) gruen — dort gibt es den
// 23-Stunden-Tag schlicht nicht. Aussagekraeftig sind sie trotzdem ueberall,
// weil sie zusaetzlich als Property gegen ein UTC-Orakel laufen: `addDays`
// aus day_math.dart ist die zonenunabhaengig korrekte Kalenderverschiebung,
// und der Folgetag MUSS in jeder Zone die Streak fortfuehren.

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

  group('B5 — Fruehjahrsumstellung 29.03.2026 (23-Stunden-Tag)', () {
    /// Streak-Stand am Vorabend der Umstellung: 11 Tage in Folge, zuletzt
    /// getrackt am Sonntag 29.03. (dem Tag mit nur 23 Stunden).
    LifetimeStats amUmstellungstag() => LifetimeStats(
          currentStreak: 11,
          longestStreak: 11,
          lastTrackedDate: DateTime(2026, 3, 29),
        );

    test('Montag 30.03. ist der Folgetag — die Streak zaehlt auf 12 hoch', () {
      // Altcode: `.difference(...).inDays` misst 23h -> 0 -> der Tag gilt als
      // „schon gezaehlt", die Streak steht still auf 11.
      final next = amUmstellungstag().recordTrackedDay(DateTime(2026, 3, 30));

      expect(next.currentStreak, 12);
      expect(next.longestStreak, 12);
      expect(next.lastTrackedDate, DateTime(2026, 3, 30));
    });

    test('Dienstag 31.03. ohne Log am 30.03. reisst die Kette — Reset auf 1',
        () {
      // Altcode: 47h -> 1 -> „Folgetag" -> 12 statt 1.
      final next = amUmstellungstag().recordTrackedDay(DateTime(2026, 3, 31));

      expect(next.currentStreak, 1);
      expect(next.longestStreak, 11, reason: 'Highscore bleibt stehen');
      expect(next.lastTrackedDate, DateTime(2026, 3, 31));
    });

    test(
        'effectiveStreakOn: am 30.03. Gnadenfrist (11), am 31.03. gerissen (0)',
        () {
      final s = amUmstellungstag();

      expect(s.effectiveStreakOn(DateTime(2026, 3, 29)), 11);
      expect(s.effectiveStreakOn(DateTime(2026, 3, 30)), 11);
      // Altcode: 47h -> inDays 1 -> `<= 1` -> zeigt weiter 11 an. Die Kette
      // ist aber gerissen; der naechste Log laesst sie sichtbar von 11 auf
      // 12 auf 1 springen.
      expect(s.effectiveStreakOn(DateTime(2026, 3, 31)), 0);
      expect(s.effectiveStreakOn(DateTime(2026, 4, 1)), 0);
    });

    test('Herbstumstellung 25.10.2026 (25-Stunden-Tag) rechnet ebenfalls', () {
      final s = LifetimeStats(
        currentStreak: 3,
        longestStreak: 3,
        lastTrackedDate: DateTime(2026, 10, 25),
      );

      expect(s.recordTrackedDay(DateTime(2026, 10, 26)).currentStreak, 4);
      expect(s.effectiveStreakOn(DateTime(2026, 10, 26)), 3);
      expect(s.effectiveStreakOn(DateTime(2026, 10, 27)), 0);
    });
  });

  // C7-Nebenbefund (2026-08-08): incrementWorkouts() hatte seit dem
  // Training-Tab-Aus (a267e15) keinen Aufrufer mehr, addWater()/addSteps()
  // seit dem Aus der Heute-Tab-Kacheln ebenfalls nicht. Die drei Mutatoren
  // sind entfernt.
  //
  // Die FELDER bleiben: workouts_completed / water_total_ml / steps_recorded
  // sind `not null`-Spalten mit `>= 0`-Check in public.lifetime_stats, stehen
  // im expliziten select von LifetimeStatsSync.load, in den Parametern der
  // increment_lifetime_stats-RPC UND im LocalCache-JSON bestehender
  // Installationen. Sie aus dem Wire-Format zu streichen wuerde gecachte
  // Eintraege und die Tabelle brechen — sie laufen deshalb als eingefrorener
  // Durchreicher weiter. Diese Tests halten genau das fest.
  group('C7 — eingefrorene Legacy-Zaehler bleiben wire-kompatibel', () {
    test('fromRow -> toRow reicht die Legacy-Spalten unveraendert durch', () {
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

      final zurueck = LifetimeStats.fromRow(row).toRow();

      expect(zurueck['workouts_completed'], 42);
      expect(zurueck['water_total_ml'], 12000);
      expect(zurueck['steps_recorded'], 310000);
      expect(zurueck['meals_logged'], 7);
      expect(zurueck['weight_logs'], 3);
      expect(zurueck['last_workout_date'], '2026-06-04');
    });

    test('toRow traegt weiterhin alle Spalten der Tabelle', () {
      expect(
        LifetimeStats().toRow().keys.toSet(),
        {
          'workouts_completed',
          'meals_logged',
          'water_total_ml',
          'steps_recorded',
          'weight_logs',
          'current_streak',
          'longest_streak',
          'last_workout_date',
        },
      );
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
    // `addDays` aus day_math.dart ist die zonenunabhaengig korrekte
    // Kalenderverschiebung (dort selbst gegen ein UTC-Orakel gesichert).
    // Beide Streak-Rechnungen muessen ihr an JEDEM Tag folgen — auf einer
    // UTC-Maschine ebenso wie in einer DST-Zone.
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
}
