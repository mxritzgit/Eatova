import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// B4 (2026-08-08): the store had no day rollover, so a meal logged after an
// overnight background stint landed on yesterday, skipped the streak and left
// dailyConsumedKcal on the old day — the very field ProfileScreen and the
// coach read.
//
// The fix is [HomeStore.maybeRollOverToToday], armed by a timer on the next
// local midnight AND on resume. The store reads `clock.now()`, so these tests
// pin the day with withClock and let the clock run on.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// [autoDispose] false when the test disposes itself; a second teardown call
/// would fail on the ChangeNotifier.
HomeStore _store({bool autoDispose = true}) {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
  );
  if (autoDispose) addTearDown(store.dispose);
  return store;
}

/// Store WITH sync: only that path arms the midnight timer.
HomeStore _syncedStore({bool autoDispose = true}) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) async {
      if (req.method == 'GET') {
        return http.Response(jsonEncode(const <dynamic>[]), 200,
            headers: const {'Content-Type': 'application/json'}, request: req);
      }
      return http.Response('', 201, request: req);
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-rollover'),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
    debugCache: LocalCache(InMemoryKeyValueStore(), 'user-rollover'),
  );
  if (autoDispose) addTearDown(store.dispose);
  return store;
}

MealAnalysisResult _meal(String name, {int kcal = 300}) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 300,
      kcalPer100G: kcal / 3,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

/// Monday 21:00 and Tuesday 08:00, inside a plain month; DST has its own
/// cases below.
final _montagAbend = DateTime(2026, 6, 1, 21, 0);
final _dienstagFrueh = DateTime(2026, 6, 2, 8, 0);
final _montag = DateTime(2026, 6, 1);
final _dienstag = DateTime(2026, 6, 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('durationUntilNextLocalMidnight', () {
    test('landet exakt auf dem Beginn des Folgetages (zonenunabhaengig)', () {
      for (final now in <DateTime>[
        DateTime(2026, 6, 1, 21, 0),
        DateTime(2026, 3, 28, 23, 30),
        DateTime(2026, 3, 29, 0, 30), // Umstellungstag, 23 Stunden
        DateTime(2026, 3, 29, 12, 0),
        DateTime(2026, 10, 25, 12, 0), // Herbst, 25 Stunden
        DateTime(2026, 10, 25, 23, 30),
        DateTime(2026, 12, 31, 23, 59),
      ]) {
        final ziel = now.add(durationUntilNextLocalMidnight(now));
        expect(
          (ziel.year, ziel.month, ziel.day),
          (addDays(now, 1).year, addDays(now, 1).month, addDays(now, 1).day),
          reason: 'von $now aus ist die naechste Mitternacht der Folgetag',
        );
        expect(startOfDay(ziel), ziel,
            reason: 'von $now aus wird nicht exakt Mitternacht getroffen');
      }
    });

    test('ist nie <= 0 (sonst laeuft der Timer heiss)', () {
      // Old bug: adding a Duration across the autumn DST switch lands at 23:00
      // the same day, so the self-rearming timer spun in a loop.
      var cursor = DateTime.utc(2025, 1, 1);
      final ende = DateTime.utc(2030, 12, 31);
      while (!cursor.isAfter(ende)) {
        for (final stunde in const [0, 1, 2, 12, 22, 23]) {
          final now =
              DateTime(cursor.year, cursor.month, cursor.day, stunde, 30);
          expect(durationUntilNextLocalMidnight(now), greaterThan(Duration.zero),
              reason: 'nicht-positive Restdauer bei $now');
          expect(durationUntilNextLocalMidnight(now),
              lessThanOrEqualTo(const Duration(hours: 25)));
        }
        cursor = cursor.add(const Duration(days: 1));
      }
    });
  });

  group('maybeRollOverToToday', () {
    test(
        'B4-Szenario: nach dem Tageswechsel landet das Fruehstueck auf HEUTE, '
        'die Streak zaehlt heute und die Tageswerte sind heutige', () {
      late HomeStore store;
      withClock(Clock.fixed(_montagAbend), () {
        store = _store();
        store.addResultToDailyTotal(_meal('Abendessen', kcal: 2100));
        // Monday evening state, as backgrounding freezes it.
        expect(store.selectedFoodDate, _montag);
        expect(store.dailyConsumedKcal, 2100);
        expect(store.lifetimeStats.currentStreak, 1);
      });

      withClock(Clock.fixed(_dienstagFrueh), () {
        // Without the rollover the store would still hold Monday.
        final gewechselt = store.maybeRollOverToToday();

        expect(gewechselt, isTrue);
        expect(store.selectedFoodDate, _dienstag);
        expect(store.dailyConsumedKcal, 0,
            reason: 'Dienstag ist noch ungeloggt — Montags 2100 sind weg');
        expect(store.macroProgress, MacroProgress.empty);

        final id = store.addResultToDailyTotal(_meal('Fruehstueck', kcal: 400));
        final gebucht = store.loggedMeals.firstWhere((m) => m.id == id);

        expect(gebucht.effectiveLocalDay, localDayKey(_dienstag),
            reason: 'Dienstags Fruehstueck darf nicht auf Montag landen');
        expect(store.dailyConsumedKcal, 400);
        expect(store.lifetimeStats.currentStreak, 2,
            reason: 'Montag + Dienstag geloggt -> Streak 2, nicht gerissen');
        expect(store.lifetimeStats.lastTrackedDate, _dienstag);
        // Coach context and its own food list no longer contradict.
        expect(store.coachContext, contains('Heute gegessen: 400'));
        expect(store.coachContext, contains('Fruehstueck'));
      });
    });

    test('bewusst gewaehlter Archivtag springt NICHT weg', () {
      final archiv = DateTime(2026, 5, 12);
      late HomeStore store;
      withClock(Clock.fixed(_montagAbend), () {
        store = _store();
        store.addResultToDailyTotal(_meal('Abendessen', kcal: 2100));
        store.setFoodDate(archiv); // user browses the archive
        expect(store.selectedFoodDate, archiv);
      });

      withClock(Clock.fixed(_dienstagFrueh), () {
        final gewechselt = store.maybeRollOverToToday();

        expect(gewechselt, isTrue, reason: 'der Kalendertag hat gewechselt');
        expect(store.selectedFoodDate, archiv,
            reason: 'die bewusste Auswahl bleibt stehen');
        // The day values always describe today, not selectedFoodDate.
        expect(store.dailyConsumedKcal, 0);
        expect(store.macroProgress, MacroProgress.empty);
      });
    });

    test('„Heute"-Tap zaehlt als aktueller Tag und wandert wieder mit', () {
      late HomeStore store;
      withClock(Clock.fixed(_montagAbend), () {
        store = _store();
        store.setFoodDate(DateTime(2026, 5, 12)); // Archiv
        store.setFoodDate(_montagAbend); // back to "today"
      });

      withClock(Clock.fixed(_dienstagFrueh), () {
        expect(store.maybeRollOverToToday(), isTrue);
        expect(store.selectedFoodDate, _dienstag);
      });
    });

    test('mehrtaegiger Hintergrund-Aufenthalt springt direkt auf heute', () {
      late HomeStore store;
      withClock(Clock.fixed(_montagAbend), () {
        store = _store();
        store.addResultToDailyTotal(_meal('Abendessen', kcal: 2100));
      });

      withClock(Clock.fixed(DateTime(2026, 6, 9, 10)), () {
        expect(store.maybeRollOverToToday(), isTrue);
        expect(store.selectedFoodDate, DateTime(2026, 6, 9));
        expect(store.dailyConsumedKcal, 0);
      });
    });

    test('kein Tageswechsel -> No-op ohne notifyListeners', () {
      withClock(Clock.fixed(_montagAbend), () {
        final store = _store();
        var notifies = 0;
        store.addListener(() => notifies++);

        expect(store.maybeRollOverToToday(), isFalse);
        expect(notifies, 0);
      });
    });

    test('Tageswechsel benachrichtigt die UI genau einmal, danach No-op', () {
      late HomeStore store;
      withClock(Clock.fixed(_montagAbend), () => store = _store());

      withClock(Clock.fixed(_dienstagFrueh), () {
        var notifies = 0;
        store.addListener(() => notifies++);

        expect(store.maybeRollOverToToday(), isTrue);
        expect(notifies, 1);

        // Idempotent: a second resume on the same day changes nothing.
        expect(store.maybeRollOverToToday(), isFalse);
        expect(notifies, 1);
      });
    });

    test('dailySteps bleibt unangetastet (Health-Zustaendigkeit, B3)', () {
      // Unverified readSnapshot() returns null, not 0 steps; the rollover must
      // not cement a zero.
      late HomeStore store;
      withClock(Clock.fixed(_montagAbend), () {
        store = _store();
        store.dailySteps = 8421;
      });
      withClock(Clock.fixed(_dienstagFrueh), () {
        expect(store.maybeRollOverToToday(), isTrue);
        expect(store.dailySteps, 8421);
      });
    });

    test('nach dispose ist der Rollover ein No-op', () {
      late HomeStore store;
      withClock(
          Clock.fixed(_montagAbend), () => store = _store(autoDispose: false));
      store.dispose();

      withClock(Clock.fixed(_dienstagFrueh), () {
        expect(store.maybeRollOverToToday(), isFalse);
        expect(store.selectedFoodDate, _montag);
      });
    });
  });

  group('Mitternachts-Timer', () {
    test('start() armiert genau einen Timer, dispose() raeumt ihn ab',
        () async {
      final store = _syncedStore(autoDispose: false);
      expect(store.debugMidnightTimerIsActive, isFalse);

      store.start();
      await store.profileReady;

      expect(store.debugMidnightTimerIsActive, isTrue);

      store.dispose();
      expect(store.debugMidnightTimerIsActive, isFalse);
    });

    test('ein verarbeiteter Tageswechsel setzt den Timer neu', () async {
      final store = _syncedStore();
      store.start();
      await store.profileReady;
      expect(store.debugMidnightTimerIsActive, isTrue);

      // Resume the next day: the timer did not fire while suspended and must
      // rearm for the coming midnight.
      withClock(Clock.fixed(addDays(clock.now(), 1)), () {
        expect(store.maybeRollOverToToday(), isTrue);
      });
      expect(store.debugMidnightTimerIsActive, isTrue);
    });

    test('ohne Sync (Preview/Test) laeuft kein Timer, der Resume greift aber',
        () {
      late HomeStore store;
      withClock(Clock.fixed(_montagAbend), () {
        store = _store();
        store.start();
        expect(store.debugMidnightTimerIsActive, isFalse);
      });
      withClock(Clock.fixed(_dienstagFrueh), () {
        expect(store.maybeRollOverToToday(), isTrue);
        expect(store.selectedFoodDate, _dienstag);
        expect(store.debugMidnightTimerIsActive, isFalse);
      });
    });
  });

  group('B5 — Tageswechsel ueber die Fruehjahrsumstellung 29.03.2026', () {
    test('vom 29.03. (23-Stunden-Tag) auf den 30.03.', () {
      late HomeStore store;
      withClock(Clock.fixed(DateTime(2026, 3, 29, 21)), () {
        store = _store();
        store.addResultToDailyTotal(_meal('Abendessen', kcal: 2100));
        expect(store.lifetimeStats.currentStreak, 1);
      });

      withClock(Clock.fixed(DateTime(2026, 3, 30, 8)), () {
        expect(store.maybeRollOverToToday(), isTrue);
        expect(store.selectedFoodDate, DateTime(2026, 3, 30));
        expect(store.dailyConsumedKcal, 0);

        store.addResultToDailyTotal(_meal('Fruehstueck', kcal: 400));
        // The old absolute-time check counted this day as already tracked.
        expect(store.lifetimeStats.currentStreak, 2);
        expect(store.lifetimeStats.lastTrackedDate, DateTime(2026, 3, 30));
      });
    });
  });
}
