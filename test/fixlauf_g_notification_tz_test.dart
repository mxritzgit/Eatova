import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// F7-04: scheduleAll built TZDateTime(tz.local, y, m, d, 20, 0) from the
// wall-clock PARTS of a local DateTime. With the UTC fallback (flutter_timezone
// failing) a Berlin 20:00 became 20:00 UTC = 22:00 local — into iOS Focus.
// The instant is now converted (TZDateTime.from) and the fallback is
// reported instead of swallowed.
//
// F7-12 / F1-09: a PlatformException from initialize/createNotificationChannel
// escaped as a zone error on every cold start; the service now reports it
// and stays "not available", the store lands in blocked.
//
// LocalNotificationService was never instantiated in a test before: the
// NotificationPluginGateway seam makes the plugin-backed paths runnable here.

class _FakeGateway implements NotificationPluginGateway {
  bool failInit = false;
  bool? androidEnabled = true;
  int initCalls = 0;
  int cancelAllCalls = 0;
  final List<tz.TZDateTime> scheduled = <tz.TZDateTime>[];

  @override
  Future<void> initialize(InitializationSettings settings) async {
    initCalls++;
    if (failInit) {
      throw PlatformException(code: 'init', message: 'plugin kaputt');
    }
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
  Future<bool?> androidNotificationsEnabled() async => androidEnabled;

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails details,
  }) async =>
      scheduled.add(scheduledDate);

  @override
  Future<void> cancelAll() async => cancelAllCalls++;
}

/// Tomorrow 20:00 local wall clock — what the streak planner emits.
DateTime _morgen20Uhr() {
  final jetzt = DateTime.now();
  return DateTime(jetzt.year, jetzt.month, jetzt.day + 1, 20);
}

NotificationSpec _spec(DateTime wann) => NotificationSpec(
      id: 7,
      title: 'Streak',
      body: 'retten',
      scheduledFor: wann,
    );

LocalNotificationService _service(
  _FakeGateway gateway, {
  Future<String> Function()? zone,
}) =>
    LocalNotificationService(
      gateway: gateway,
      platform: NotificationPlatform.android,
      localTimezoneName: zone ?? () async => 'UTC',
    );

List<String?> _contexts() {
  final gesehen = <String?>[];
  CrashReporter.debugSentrySink = (_, __, context) => gesehen.add(context);
  addTearDown(() => CrashReporter.debugSentrySink = null);
  return gesehen;
}

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Service whose init throws — the F1-09 cold start.
class _KaputterService
    implements NotificationService, NotificationPermissionProbe {
  @override
  Future<void> init() async =>
      throw PlatformException(code: 'init', message: 'kaputt');

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {}

  @override
  Future<void> cancelAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('scheduleAll plant den INSTANT, nicht die Wandzeit-Teile (F7-04)', () {
    for (final zone in const ['UTC', 'Europe/Berlin', 'America/New_York']) {
      test('tz.local = $zone: lokales 20:00 bleibt derselbe Zeitpunkt',
          () async {
        final gateway = _FakeGateway();
        final service = _service(gateway, zone: () async => zone);
        final wann = _morgen20Uhr();

        await service.scheduleAll([_spec(wann)]);

        expect(service.isAvailable, isTrue);
        expect(gateway.cancelAllCalls, 1, reason: 'cancel-first');
        expect(gateway.scheduled, hasLength(1));
        final geplant = gateway.scheduled.single;
        expect(geplant.location.name, zone);
        expect(geplant.millisecondsSinceEpoch, wann.millisecondsSinceEpoch,
            reason: 'frueher: TZDateTime($zone, …, 20, 0) — 20:00 in $zone '
                'statt 20:00 lokal');
      });
    }

    test('Vergangenheit wird uebersprungen', () async {
      final gateway = _FakeGateway();
      final service = _service(gateway);
      await service.scheduleAll([
        _spec(DateTime.now().subtract(const Duration(hours: 1))),
      ]);
      expect(gateway.scheduled, isEmpty);
    });

    test('Zeitzonen-Fallback wird gemeldet, plant aber weiter korrekt',
        () async {
      final gesehen = _contexts();
      final gateway = _FakeGateway();
      final service = _service(
        gateway,
        zone: () async => throw MissingPluginException('flutter_timezone'),
      );
      final wann = _morgen20Uhr();

      await service.scheduleAll([_spec(wann)]);

      expect(gesehen, contains('notification-timezone'),
          reason: 'still auf UTC zu fallen hat den Fehler wochenlang versteckt');
      expect(gateway.scheduled.single.millisecondsSinceEpoch,
          wann.millisecondsSinceEpoch);
    });
  });

  group('init/hasPermission sind eingezaeunt (F7-12 / F1-09)', () {
    test('initialize wirft -> gemeldet, nicht verfuegbar, kein Wurf', () async {
      final gesehen = _contexts();
      final gateway = _FakeGateway()..failInit = true;
      final service = _service(gateway);

      await service.init();
      expect(service.isAvailable, isFalse);
      expect(gesehen, contains('notification-init'));

      // Every other call answers honestly instead of throwing.
      expect(await service.hasPermission(), isFalse);
      expect(await service.requestPermission(), isFalse);
      await service.scheduleAll([_spec(_morgen20Uhr())]);
      expect(gateway.scheduled, isEmpty);

      // Every call retried the init (4 attempts so far) — a transient plugin
      // error may recover, and the 5th attempt does.
      gateway.failInit = false;
      await service.init();
      expect(service.isAvailable, isTrue);
      expect(gateway.initCalls, 5);
    });

    test('hasPermission: Plattformfehler -> false statt Zone-Error', () async {
      final gesehen = _contexts();
      final gateway = _FakeGateway();
      final service = _service(gateway);
      await service.init();
      gateway.androidEnabled = null;
      expect(await service.hasPermission(), isFalse);

      // Failing init inside hasPermission is inside the same fence.
      final kaputt = _FakeGateway()..failInit = true;
      expect(await _service(kaputt).hasPermission(), isFalse);
      expect(gesehen, contains('notification-init'));
    });

    test('unsupported Plattform: alles no-op, nichts wird angefasst', () async {
      final gateway = _FakeGateway();
      final service = LocalNotificationService(
        gateway: gateway,
        platform: NotificationPlatform.unsupported,
        localTimezoneName: () async => 'UTC',
      );
      await service.init();
      expect(service.isAvailable, isFalse);
      expect(await service.hasPermission(), isFalse);
      expect(gateway.initCalls, 0);
    });

    test('Kaltstart: init wirft -> Store meldet blocked, kein Zone-Error',
        () async {
      final gesehen = _contexts();
      final cache = LocalCache(InMemoryKeyValueStore(), 'user-g');
      await cache.writeNotificationsEnabled(true);
      final store = HomeStore(
        sync: null,
        health: const NoopHealthService(),
        notificationService: _KaputterService(),
        initialUserName: 'Test',
        emitSnack: _noopSnack,
        debugCache: cache,
      );
      addTearDown(store.dispose);

      await store.initNotificationsFromCache();

      expect(store.reminderState, ReminderState.blocked);
      expect(store.notificationsEnabled, isFalse);
      expect(gesehen, contains('notifications-cold-start'));
      // Opt-in untouched: nothing was proven either way.
      expect(await cache.readNotificationsEnabled(), isTrue);

      // The refresh path (resume) is fenced the same way.
      await store.refreshNotificationPermission();
      expect(store.reminderState, ReminderState.blocked);
      expect(gesehen, contains('notifications-refresh'));
    });
  });
}
