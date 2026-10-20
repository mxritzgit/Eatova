import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/reminder_time.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/streak_reminder_planner.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// 2026-10-19: the evening reminder no longer goes quiet once anything is
// logged. Below the complete-day rule (half the daily goal) today's slot
// stays and asks whether something is missing, with the kcal logged at
// planning time. Local notifications run no code when they fire, so the
// store re-plans whenever today's entries change.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

class _Notifications
    implements NotificationService, NotificationPermissionProbe {
  final List<List<NotificationSpec>> scheduled = <List<NotificationSpec>>[];

  List<NotificationSpec> get last => scheduled.last;

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {
    scheduled.add(specs);
  }

  @override
  Future<void> cancelAll() async {}
}

MealAnalysisResult _meal(int kcal) => MealAnalysisResult(
  mealName: 'Essen $kcal',
  caloriesKcal: kcal,
  estimatedGrams: 300,
  kcalPer100G: 100,
  protein: '20 g',
  carbs: '50 g',
  fat: '10 g',
  confidence: 'Hoch',
  portionNotes: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Wednesday 2026-07-15 and a streak that ended yesterday.
  final morning = DateTime(2026, 7, 15, 9, 30);
  final evening = DateTime(2026, 7, 15, 21);
  final trackedToday = LifetimeStats(
    currentStreak: 4,
    lastTrackedDate: DateTime(2026, 7, 15),
  );

  group('planStreakReminders mit Tagesstand', () {
    test('halber Tag vor 20:00: heute fragt nach, morgen nennt die Serie', () {
      final specs = planStreakReminders(
        morning,
        trackedToday,
        deL10n,
        ReminderTime.standard,
        (kcal: 640, goalKcal: 2200),
      );
      expect(specs, hasLength(streakReminderDayOffsets.length));
      expect(specs.first.scheduledFor, DateTime(2026, 7, 15, 20));
      expect(specs.first.title, 'Tagebuch für heute');
      expect(
        specs.first.body,
        'Heute erst 640 kcal eingetragen – fehlt noch etwas?',
      );
      // Today keeps the chain, so tomorrow's slot may name it.
      expect(specs[1].scheduledFor, DateTime(2026, 7, 16, 20));
      expect(specs[1].body, deL10n.notifStreakSaveBody(4));
      expect(specs[2].body, deL10n.notifStreakStartBody);
      expect(specs.map((s) => s.id).toSet(), hasLength(specs.length));
    });

    test('vollstaendiger Tag: heute bleibt still wie bisher', () {
      final specs = planStreakReminders(
        morning,
        trackedToday,
        deL10n,
        ReminderTime.standard,
        (kcal: 1100, goalKcal: 2200),
      );
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 20));
      expect(specs.first.body, deL10n.notifStreakSaveBody(4));
      expect(
        specs.where((s) => s.title == deL10n.reminderHalfDayTitle),
        isEmpty,
      );
    });

    test('nach der Uhrzeit plant nichts in die Vergangenheit', () {
      final specs = planStreakReminders(
        evening,
        trackedToday,
        deL10n,
        ReminderTime.standard,
        (kcal: 300, goalKcal: 2200),
      );
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 20));
      expect(specs.first.body, deL10n.notifStreakSaveBody(4));
    });

    test('ohne Tagesstand bleibt es beim alten Verhalten', () {
      final specs = planStreakReminders(morning, trackedToday, deL10n);
      expect(specs.first.scheduledFor, DateTime(2026, 7, 16, 20));
    });

    test('ein leerer Tag fragt nicht nach kcal, sondern rettet die Serie', () {
      final stats = LifetimeStats(
        currentStreak: 4,
        lastTrackedDate: DateTime(2026, 7, 14),
      );
      final specs = planStreakReminders(
        morning,
        stats,
        deL10n,
        ReminderTime.standard,
        (kcal: 0, goalKcal: 2200),
      );
      expect(specs.first.scheduledFor, DateTime(2026, 7, 15, 20));
      expect(specs.first.body, deL10n.notifStreakSaveBody(4));
    });

    test('Englisch mit Tausenderpunkt der Sprache', () {
      final specs = planStreakReminders(
        morning,
        trackedToday,
        enL10n,
        const ReminderTime(19, 15),
        (kcal: 1050, goalKcal: 2400),
      );
      expect(specs.first.scheduledFor, DateTime(2026, 7, 15, 19, 15));
      expect(specs.first.title, "Today's diary");
      expect(
        specs.first.body,
        'Only 1,050 kcal logged today – anything missing?',
      );
    });

    test('ueber die Zeitumstellung bleibt der Abend auf 20:00', () {
      // Saturday before the March switch: today and the next days at 20:00.
      final specs = planStreakReminders(
        DateTime(2026, 3, 28, 10),
        LifetimeStats(currentStreak: 2, lastTrackedDate: DateTime(2026, 3, 28)),
        deL10n,
        ReminderTime.standard,
        (kcal: 200, goalKcal: 2000),
      );
      expect(specs.first.scheduledFor, DateTime(2026, 3, 28, 20));
      expect(specs[1].scheduledFor, DateTime(2026, 3, 29, 20));
      expect(specs[2].scheduledFor, DateTime(2026, 3, 30, 20));
    });
  });

  group('HomeStore plant bei jeder Aenderung von heute neu', () {
    test('loggen, loeschen und Portion aendern', () async {
      await withClock(Clock.fixed(morning), () async {
        final notifications = _Notifications();
        final store = HomeStore(
          sync: null,
          health: const NoopHealthService(),
          notificationService: notifications,
          initialUserName: 'Test',
          emitSnack: _noopSnack,
          debugCache: LocalCache(InMemoryKeyValueStore(), 'user-a'),
        );
        addTearDown(store.dispose);
        await store.setNotificationsEnabled(true);
        expect(store.profile.dailyKcalGoal, 2200);

        final first = await store.addResultToDailyTotal(_meal(420));
        await pumpEventQueue();
        expect(notifications.last.first.scheduledFor, DateTime(2026, 7, 15, 20));
        expect(
          notifications.last.first.body,
          'Heute erst 420 kcal eingetragen – fehlt noch etwas?',
        );

        final second = await store.addResultToDailyTotal(_meal(700));
        await pumpEventQueue();
        // 1,120 kcal: complete, today's slot is gone.
        expect(notifications.last.first.scheduledFor, DateTime(2026, 7, 16, 20));

        await store.removeLoggedMeal(second);
        await pumpEventQueue();
        expect(
          notifications.last.first.body,
          'Heute erst 420 kcal eingetragen – fehlt noch etwas?',
        );

        await store.updateLoggedMealDetails(first, result: _meal(1200));
        await pumpEventQueue();
        expect(notifications.last.first.scheduledFor, DateTime(2026, 7, 16, 20));
      });
    });

    test('ein Nachtrag fuer vorgestern plant nicht neu', () async {
      await withClock(Clock.fixed(morning), () async {
        final notifications = _Notifications();
        final store = HomeStore(
          sync: null,
          health: const NoopHealthService(),
          notificationService: notifications,
          initialUserName: 'Test',
          emitSnack: _noopSnack,
          debugCache: LocalCache(InMemoryKeyValueStore(), 'user-a'),
        );
        addTearDown(store.dispose);
        await store.setNotificationsEnabled(true);
        final plans = notifications.scheduled.length;

        final id = await store.addResultToDailyTotal(
          _meal(300),
          foodDate: DateTime(2026, 7, 13),
        );
        await store.removeLoggedMeal(id);
        await pumpEventQueue();
        expect(notifications.scheduled, hasLength(plans));
      });
    });
  });
}
