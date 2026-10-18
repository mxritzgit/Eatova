import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/reminder_time.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/streak_reminder_planner.dart';

// C4 on the plugin layer: the #151 skip of an identical plan still holds for
// a chosen time, and a new time is a new plan — cancel first, then the
// dated one-shots at the new time.

class _Gateway implements NotificationPluginGateway {
  final List<String> log = <String>[];
  final List<tz.TZDateTime> scheduledAt = <tz.TZDateTime>[];

  int get calls => log.length;

  @override
  Future<void> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onResponse,
  }) async {}

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
    log.add('schedule');
    scheduledAt.add(scheduledDate);
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
  Future<void> cancel(int id) async => log.add('cancel');

  @override
  Future<void> cancelAll() async => log.add('cancelAll');

  @override
  Future<NotificationAppLaunchDetails?> launchDetails() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Far ahead, so the service's "never into the past" guard keeps all slots.
  final now = DateTime(2099, 7, 15, 9);
  List<NotificationSpec> plan(ReminderTime time) =>
      planStreakReminders(now, LifetimeStats(), null, time);

  late _Gateway gateway;
  late LocalNotificationService service;
  setUp(() {
    gateway = _Gateway();
    service = LocalNotificationService(
      gateway: gateway,
      platform: NotificationPlatform.android,
      localTimezoneName: () async => 'Europe/Berlin',
    );
  });

  test(
    'derselbe Plan zur gewaehlten Zeit ruft das Plugin nicht erneut',
    () async {
      await service.scheduleAll(plan(const ReminderTime(21, 30)));
      final before = gateway.calls;

      await service.scheduleAll(plan(const ReminderTime(21, 30)));

      expect(gateway.calls, before);
    },
  );

  test('eine neue Uhrzeit: erst alle Nudges weg, dann der neue Plan', () async {
    await service.scheduleAll(plan(const ReminderTime(21, 30)));
    gateway.log.clear();
    gateway.scheduledAt.clear();

    await service.scheduleAll(plan(const ReminderTime(6, 45)));

    final cancels = gateway.log.where((e) => e == 'cancel').length;
    expect(cancels, reminderNudgeIdCount);
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
        const ReminderTime(6, 45),
      ).map((spec) => spec.scheduledFor.millisecondsSinceEpoch),
    );
  });
}
