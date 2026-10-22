// The weigh-in reminder (review 2026-10-22): an opt-in of its own next to
// the evening reminder. Monday and Thursday at 07:30, at most two extra
// notifications a week, inside the reminder id range the opt-out and the
// session end cancel, the Monday text naming the weekly check, a tap opening
// the weigh-in sheet. Both reminders ride on one OS permission.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/app_entry.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/weigh_in_reminder_planner.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

class _Notifications
    implements
        NotificationService,
        NotificationPermissionProbe,
        NotificationScopedCancel {
  bool grant = true;
  int requests = 0;
  int nudgeCancels = 0;
  final List<List<NotificationSpec>> scheduled = <List<NotificationSpec>>[];

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async {
    requests++;
    return grant;
  }

  @override
  Future<bool> hasPermission() async => grant;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async =>
      scheduled.add(specs);

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> cancelNudges() async => nudgeCancels++;

  @override
  Future<void> cancelStaleSchedules({restore = const []}) async {}
}

HomeStore _store(LocalCache cache, NotificationService notifications) =>
    HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: notifications,
      initialUserName: 'Test',
      emitSnack: _noopSnack,
      debugCache: cache,
    );

bool _weighIn(NotificationSpec spec) => spec.payload == AppEntry.weighIn.id;

/// Wednesday 2026-07-15, 09:00.
final DateTime _wednesday = DateTime(2026, 7, 15, 9);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Montag und Donnerstag um 07:30, hoechstens zwei pro Woche, im '
      'Erinnerungsbereich, ein Tipp oeffnet das Wiegen', () {
    final specs = planWeighInReminders(_wednesday);

    expect(specs, hasLength(8), reason: 'four weeks, both weekdays');
    final perWeek = <int, int>{};
    for (final spec in specs) {
      final when = spec.scheduledFor;
      expect(
        [DateTime.monday, DateTime.thursday],
        contains(when.weekday),
        reason: '$when',
      );
      expect((when.hour, when.minute), (7, 30));
      final week = daysBetween(when, DateTime(2026, 7, 13)) ~/ 7;
      perWeek[week] = (perWeek[week] ?? 0) + 1;
      expect(spec.payload, AppEntry.weighIn.id);
      // Past the streak reminders' 28 ids, still inside what is cancelled.
      expect(
        spec.id,
        inInclusiveRange(
          reminderNudgeIdFirst + 28,
          reminderNudgeIdFirst + reminderNudgeIdCount - 1,
        ),
      );
    }
    expect(perWeek.values.every((count) => count <= 2), isTrue);
    expect(specs.map((s) => s.id).toSet(), hasLength(specs.length));
    expect(
      specs.firstWhere((s) => s.scheduledFor.weekday == DateTime.monday).body,
      contains('Wochen-Check'),
    );

    // A re-plan keeps a slot's id, so it overwrites instead of duplicating.
    final thursday = DateTime(2026, 7, 16, 7, 30);
    final later = planWeighInReminders(DateTime(2026, 7, 16, 6));
    expect(
      later.firstWhere((s) => s.scheduledFor == thursday).id,
      specs.firstWhere((s) => s.scheduledFor == thursday).id,
    );
  });

  test('heute: nur vor 07:30 und nur ohne Wiegung', () {
    final monday = DateTime(2026, 7, 20);
    final slot = DateTime(2026, 7, 20, 7, 30);
    for (final (why, now, weighed, planned)
        in <(String, DateTime, bool, bool)>[
          ('before 07:30', monday.add(const Duration(hours: 6)), false, true),
          ('at 07:30', slot, false, false),
          ('already weighed', monday.add(const Duration(hours: 6)), true,
              false),
        ]) {
      final specs = planWeighInReminders(now, weighedToday: weighed);
      expect(specs.any((s) => s.scheduledFor == slot), planned, reason: why);
    }
  });

  group('im Store', () {
    test(
      'an: fragt das System und plant neben der Abend-Erinnerung; ein Aus '
      'der einen laesst die andere stehen',
      () => withClock(Clock.fixed(_wednesday), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        final notifications = _Notifications();
        final store = _store(cache, notifications);
        await store.setNotificationsEnabled(true);

        await store.setWeighInReminderEnabled(true);

        expect(store.weighInReminderState, ReminderState.active);
        expect(notifications.requests, 2);
        expect(await cache.readWeighInReminderEnabled(), isTrue);
        final both = notifications.scheduled.last;
        expect(both.where(_weighIn), hasLength(8));
        expect(both.where((s) => !_weighIn(s)), isNotEmpty);

        await store.setNotificationsEnabled(false);
        expect(
          notifications.scheduled.last.every(_weighIn),
          isTrue,
          reason: 'the evening opt-out keeps the weigh-in plan',
        );
        expect(notifications.nudgeCancels, 0);

        await store.setWeighInReminderEnabled(false);
        expect(store.weighInReminderState, ReminderState.off);
        expect(notifications.nudgeCancels, 1);
        expect(await cache.readWeighInReminderEnabled(), isFalse);
      }),
    );

    test(
      'blockiert: nichts geplant; Kaltstart bringt sie zurueck, ein '
      'entzogenes Recht blockiert sie wieder',
      () => withClock(Clock.fixed(_wednesday), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        final refused = _Notifications()..grant = false;
        final store = _store(cache, refused);

        await store.setWeighInReminderEnabled(true);

        expect(store.weighInReminderState, ReminderState.blocked);
        expect(refused.scheduled, isEmpty);

        // Allowed in the system settings; the next start restores it from
        // this account's cache without the evening reminder.
        await cache.writeWeighInReminderEnabled(true);
        final notifications = _Notifications();
        final restarted = _store(cache, notifications);
        await restarted.initNotificationsFromCache();
        expect(restarted.weighInReminderState, ReminderState.active);
        expect(restarted.reminderState, ReminderState.off);
        expect(notifications.requests, 0, reason: 'a cold start never asks');
        expect(notifications.scheduled.last.every(_weighIn), isTrue);

        notifications.grant = false;
        await restarted.refreshNotificationPermission();
        expect(restarted.weighInReminderState, ReminderState.blocked);
        expect(notifications.nudgeCancels, 1);
      }),
    );

    test(
      'eine Wiegung vor 07:30 streicht die heutige Erinnerung sofort',
      // Monday 06:50.
      () => withClock(Clock.fixed(DateTime(2026, 7, 13, 6, 50)), () async {
        final notifications = _Notifications();
        final store = _store(
          LocalCache(InMemoryKeyValueStore(), 'user-a'),
          notifications,
        );
        await store.setWeighInReminderEnabled(true);
        bool today(NotificationSpec spec) =>
            _weighIn(spec) &&
            startOfDay(spec.scheduledFor) == startOfDay(clock.now());
        expect(notifications.scheduled.last.where(today), hasLength(1));

        await store.logWeight(80);
        await pumpEventQueue();

        expect(notifications.scheduled.last.where(_weighIn), isNotEmpty);
        expect(notifications.scheduled.last.where(today), isEmpty);
      }),
    );

    test(
      'eine Freigabe gilt fuer beide: die blockierte Erinnerung wird wieder '
      'aktiv und geplant',
      () => withClock(Clock.fixed(_wednesday), () async {
        for (final weighInFirst in [true, false]) {
          final notifications = _Notifications()..grant = false;
          final store = _store(
            LocalCache(InMemoryKeyValueStore(), 'user-a'),
            notifications,
          );
          Future<void> blocked() => weighInFirst
              ? store.setWeighInReminderEnabled(true)
              : store.setNotificationsEnabled(true);
          Future<void> granted() => weighInFirst
              ? store.setNotificationsEnabled(true)
              : store.setWeighInReminderEnabled(true);

          await blocked();
          notifications.grant = true;
          await granted();

          final why = weighInFirst ? 'weigh-in first' : 'evening first';
          expect(store.reminderState, ReminderState.active, reason: why);
          expect(store.weighInReminderState, ReminderState.active, reason: why);
          expect(
            notifications.scheduled.last.where(_weighIn),
            hasLength(8),
            reason: why,
          );
        }
      }),
    );
  });
}
