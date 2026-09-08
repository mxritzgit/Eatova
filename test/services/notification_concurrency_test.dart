import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

class _DelayedGateway implements NotificationPluginGateway {
  final entered = Completer<void>();
  final release = Completer<void>();
  final pending = <int>{};
  bool _firstSchedule = true;

  @override
  Future<void> initialize(InitializationSettings settings) async {}

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
  }) async {
    if (_firstSchedule) {
      _firstSchedule = false;
      entered.complete();
      await release.future;
    }
    pending.add(id);
  }

  @override
  Future<void> cancelAll() async => pending.clear();
}

class _DelayedPermissionService
    implements NotificationService, NotificationPermissionProbe {
  Completer<bool>? probe;
  Completer<bool>? request;
  Completer<void>? entered;
  int schedules = 0;
  int cancellations = 0;

  @override
  Future<void> init() async {}

  @override
  Future<bool> hasPermission() async {
    entered?.complete();
    return probe == null ? true : await probe!.future;
  }

  @override
  Future<bool> requestPermission() async {
    entered?.complete();
    return request == null ? true : await request!.future;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async => schedules++;

  @override
  Future<void> cancelAll() async => cancellations++;
}

void _ignoreSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

HomeStore _store(LocalCache cache, NotificationService service) {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: service,
    initialUserName: 'Test',
    emitSnack: _ignoreSnack,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return store;
}

NotificationSpec _spec(int id) => NotificationSpec(
  id: id,
  title: 'Reminder',
  body: 'Test',
  // Safely future without depending on the test runner's current date.
  scheduledFor: DateTime.utc(2099, 1, 1, 20),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final replacement in [false, true]) {
    test(
      replacement
          ? 'a newer plan replaces every pending item of a delayed older plan'
          : 'cancellation wins over an already running delayed plan',
      () async {
        final gateway = _DelayedGateway();
        final service = LocalNotificationService(
          gateway: gateway,
          platform: NotificationPlatform.android,
          localTimezoneName: () async => 'UTC',
        );
        final oldPlan = service.scheduleAll([_spec(1), _spec(2)]);
        await gateway.entered.future;
        final newer = replacement
            ? service.scheduleAll([_spec(3)])
            : service.cancelAll();
        // Let the later operation run while the first native call is held.
        await Future<void>.delayed(Duration.zero);
        gateway.release.complete();
        await oldPlan;
        await newer;

        expect(gateway.pending, replacement ? {3} : isEmpty);
      },
    );
  }

  for (final delayedOptIn in [false, true]) {
    test(
      delayedOptIn
          ? 'a delayed opt-in cannot override a later explicit opt-out'
          : 'a delayed resume probe cannot override a later explicit opt-out',
      () async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'notification-race');
        final service = _DelayedPermissionService();
        final store = _store(cache, service);
        if (!delayedOptIn) await store.setNotificationsEnabled(true);

        final answer = Completer<bool>();
        service.entered = Completer<void>();
        if (delayedOptIn) {
          service.request = answer;
        } else {
          service.probe = answer;
        }
        final oldOperation = delayedOptIn
            ? store.setNotificationsEnabled(true)
            : store.refreshNotificationPermission();
        await service.entered!.future;

        await store.setNotificationsEnabled(false);
        final schedulesAfterOptOut = service.schedules;
        answer.complete(true);
        await oldOperation;

        expect(store.reminderState, ReminderState.off);
        expect(await cache.readNotificationsEnabled(), isFalse);
        expect(service.schedules, schedulesAfterOptOut);
      },
    );
  }

  for (final deleteAccount in [false, true]) {
    test(
      deleteAccount
          ? 'a delayed permission probe cannot schedule after account deletion'
          : 'a delayed permission probe cannot schedule after sign-out cleanup',
      () async {
        final cache = LocalCache(
          InMemoryKeyValueStore(),
          'notification-logout',
        );
        final service = _DelayedPermissionService();
        final store = _store(cache, service);
        await store.setNotificationsEnabled(true);
        service.probe = Completer<bool>();
        service.entered = Completer<void>();
        final probe = store.refreshNotificationPermission();
        await service.entered!.future;

        if (deleteAccount) {
          expect(await store.deleteAccount(), isTrue);
        } else {
          await store.signOutCleanup();
        }
        final schedulesAfterCleanup = service.schedules;
        service.probe!.complete(true);
        await probe;

        expect(service.schedules, schedulesAfterCleanup);
        expect(await cache.readNotificationsEnabled(), isNull);
      },
    );
  }

  test(
    'late cache initialization does not invalidate an explicit opt-in',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'notification-boot');
      final service = _DelayedPermissionService()
        ..request = Completer<bool>()
        ..entered = Completer<void>();
      final store = _store(cache, service);
      final optIn = store.setNotificationsEnabled(true);
      await service.entered!.future;

      await store.initNotificationsFromCache();
      service.request!.complete(true);
      await optIn;

      expect(store.reminderState, ReminderState.active);
      expect(await cache.readNotificationsEnabled(), isTrue);
      expect(service.schedules, 1);
    },
  );

  test('explicit opt-in still works after an earlier opt-out', () async {
    final cache = LocalCache(InMemoryKeyValueStore(), 'notification-reenable');
    final service = _DelayedPermissionService();
    final store = _store(cache, service);

    await store.setNotificationsEnabled(true);
    await store.setNotificationsEnabled(false);
    await store.setNotificationsEnabled(true);

    expect(store.reminderState, ReminderState.active);
    expect(await cache.readNotificationsEnabled(), isTrue);
    expect(service.schedules, 2);
    expect(service.cancellations, 1);
  });

  test(
    'resume does not supersede an explicit pending permission request',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'notification-prompt');
      final service = _DelayedPermissionService()
        ..request = (Completer<bool>()..complete(false));
      final store = _store(cache, service);
      await store.setNotificationsEnabled(true);
      expect(store.reminderState, ReminderState.blocked);

      service.request = Completer<bool>();
      service.entered = Completer<void>();
      final optIn = store.setNotificationsEnabled(true);
      await service.entered!.future;

      // The permission sheet can resume the app before its Future completes.
      // A passive OS read may still report the previous denial at this point.
      service.entered = null;
      service.probe = Completer<bool>()..complete(false);
      await store.refreshNotificationPermission();
      service.request!.complete(true);
      await optIn;

      expect(store.reminderState, ReminderState.active);
      expect(await cache.readNotificationsEnabled(), isTrue);
      expect(service.schedules, 1);
    },
  );
}
