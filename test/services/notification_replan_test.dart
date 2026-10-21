import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/reminder_time.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/streak_reminder_planner.dart';

// Every app resume and every meal logged today re-plans the streak nudges.
// Each re-plan cost 28 cancels plus one schedule per spec, all platform
// calls, even when the plan was the one already pending. A changed plan (a
// new text, a new reminder time) still replaces every pending nudge.
class _CountingGateway implements NotificationPluginGateway {
  int cancels = 0;
  int schedules = 0;
  int cancelAlls = 0;
  bool failInit = false;
  final List<String> log = <String>[];
  final List<tz.TZDateTime> scheduledAt = <tz.TZDateTime>[];
  final List<String?> payloads = <String?>[];

  int get calls => cancels + schedules + cancelAlls;

  @override
  Future<void> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onResponse,
  }) async {
    if (failInit) throw StateError('plugin down');
  }

  @override
  Future<void> createAndroidChannel(AndroidNotificationChannel channel) async {}

  @override
  Future<bool?> requestIosPermissions() async => true;

  @override
  Future<bool?> requestAndroidPermission() async => true;

  @override
  Future<bool?> iosPermissionGranted() async => true;

  @override
  Future<bool?> androidNotificationsEnabled() async => true;

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails details,
    String? payload,
  }) async {
    schedules++;
    log.add('schedule');
    scheduledAt.add(scheduledDate);
    payloads.add(payload);
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
    String? payload,
  }) async {}

  @override
  Future<void> cancel(int id) async {
    cancels++;
    log.add('cancel');
  }

  @override
  Future<void> cancelAll() async {
    cancelAlls++;
    log.add('cancelAll');
  }

  @override
  Future<NotificationAppLaunchDetails?> launchDetails() async => null;
}

List<NotificationSpec> _plan(String body) => [
  for (var i = 0; i < 3; i++)
    NotificationSpec(
      id: reminderNudgeIdFirst + i,
      title: 'Streak',
      body: body,
      scheduledFor: DateTime(2099, 1, 1 + i, 20),
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingGateway gateway;
  late LocalNotificationService service;
  setUp(() {
    gateway = _CountingGateway();
    service = LocalNotificationService(
      gateway: gateway,
      platform: NotificationPlatform.android,
      localTimezoneName: () async => 'Europe/Berlin',
    );
  });

  test('ein unveränderter Plan ruft das Plugin nicht erneut', () async {
    await service.scheduleAll(_plan('a'));
    expect(gateway.cancels, reminderNudgeIdCount);
    expect(gateway.schedules, 3);

    final before = gateway.calls;
    await service.scheduleAll(_plan('a'));
    expect(gateway.calls, before);
  });

  test('eine neue Uhrzeit: erst alle Nudges weg, dann der neue Plan', () async {
    // Far ahead, so the service's "never into the past" guard keeps all slots.
    final now = DateTime(2099, 7, 15, 9);
    List<NotificationSpec> plan(ReminderTime time) =>
        planStreakReminders(now, LifetimeStats(), null, time);
    await service.scheduleAll(plan(const ReminderTime(21, 30)));
    gateway.log.clear();
    gateway.scheduledAt.clear();

    // Both times are still ahead today: the same day ids and texts, only the
    // instants differ — the plan must not count as unchanged.
    await service.scheduleAll(plan(const ReminderTime(22, 45)));

    expect(
      gateway.log.where((e) => e == 'cancel'),
      hasLength(reminderNudgeIdCount),
    );
    expect(
      gateway.log.indexOf('schedule'),
      reminderNudgeIdCount,
      reason: 'cancel-first, so no slot of the old time survives',
    );
    // Instants, not wall-clock parts: the tz database and the host zone may
    // disagree on DST that far ahead.
    expect(
      gateway.scheduledAt.map((when) => when.millisecondsSinceEpoch),
      plan(
        const ReminderTime(22, 45),
      ).map((spec) => spec.scheduledFor.millisecondsSinceEpoch),
    );
  });

  test('die Nutzlast jeder Erinnerung erreicht das Plugin, und eine neue '
      'Nutzlast ist ein neuer Plan', () async {
    List<NotificationSpec> plan(String payload) => [
      for (final spec in _plan('a'))
        NotificationSpec(
          id: spec.id,
          title: spec.title,
          body: spec.body,
          scheduledFor: spec.scheduledFor,
          payload: payload,
        ),
    ];
    await service.scheduleAll(plan('log-meal'));
    expect(gateway.payloads, List.filled(3, 'log-meal'));

    await service.scheduleAll(plan('weigh-in'));
    expect(gateway.payloads.skip(3), List.filled(3, 'weigh-in'));
  });

  test('nach einem Abbestellen wird derselbe Plan neu gesetzt', () async {
    await service.scheduleAll(_plan('a'));
    await service.cancelNudges();
    final afterOptOut = gateway.schedules;
    await service.scheduleAll(_plan('a'));
    expect(gateway.schedules - afterOptOut, 3);

    await service.cancelAll();
    final afterSignOut = gateway.schedules;
    await service.scheduleAll(_plan('a'));
    expect(gateway.schedules - afterSignOut, 3);

    await service.cancelStaleSchedules();
    final afterBackstop = gateway.schedules;
    await service.scheduleAll(_plan('a'));
    expect(gateway.schedules - afterBackstop, 3);
  });

  test('ein Abmelde-Cancel bei kaputtem Init läuft beim nächsten Init nach',
      () async {
    // Cold start with the previous account's nudges pending; the plugin
    // fails to come up when the user signs out.
    gateway.failInit = true;
    await service.cancelAll();
    expect(gateway.cancelAlls, 0, reason: 'precondition: never reached');

    gateway.failInit = false;
    await service.scheduleAll(_plan('b'));
    expect(gateway.log.first, 'cancelAll',
        reason: 'the deferred cancel runs before the new plan');
    expect(gateway.schedules, 3);

    await service.cancelNudges();
    await service.scheduleAll(_plan('b'));
    expect(gateway.cancelAlls, 1, reason: 'run once, not on every init');
  });
}
