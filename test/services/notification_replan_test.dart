import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:eatova/src/services/notification_service.dart';

// Every app resume and every meal logged today re-plans the streak nudges.
// Each re-plan cost 28 cancels plus one schedule per spec, all platform
// calls, even when the plan was the one already pending.
class _CountingGateway implements NotificationPluginGateway {
  int cancels = 0;
  int schedules = 0;
  int cancelAlls = 0;
  bool failInit = false;
  final List<String> log = <String>[];

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
  Future<void> cancel(int id) async => cancels++;

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

  test('ein geänderter Plan wird ersetzt', () async {
    await service.scheduleAll(_plan('a'));
    final before = gateway.calls;
    await service.scheduleAll(_plan('b'));
    expect(gateway.calls - before, reminderNudgeIdCount + 3);
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
