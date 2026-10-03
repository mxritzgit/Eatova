import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:eatova/src/app/auth_gate.dart' show cancelDeviceSchedules;
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/rest_alerts.dart';
import 'package:eatova/src/services/streak_reminder_planner.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Spec A5: rest/interval alerts live next to the reminder nudges in the same
// plugin. Before this change every reminder path (re-plan, opt-out) called
// cancelAll and silently removed a running rest alert. Only a session end and
// the cold-start backstop may clear everything, and a session end also fences
// the ended session's later requests.

class _Scheduled {
  const _Scheduled(this.when, this.details, this.payload);

  final tz.TZDateTime when;
  final NotificationDetails details;
  final String? payload;
}

class _FakeGateway implements NotificationPluginGateway {
  final Map<int, _Scheduled> pending = <int, _Scheduled>{};
  final List<String> calls = <String>[];
  final List<AndroidNotificationChannel> channels =
      <AndroidNotificationChannel>[];
  DidReceiveNotificationResponseCallback? onResponse;
  NotificationAppLaunchDetails? launch;
  int launchCalls = 0;
  bool osAllows = true;
  bool grantOnRequest = true;
  int permissionRequests = 0;

  /// Holds every zonedSchedule until completed (slow native call).
  Completer<void>? hold;
  Completer<void>? holdEntered;

  @override
  Future<void> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onResponse,
  }) async {
    this.onResponse = onResponse;
  }

  @override
  Future<void> createAndroidChannel(AndroidNotificationChannel channel) async =>
      channels.add(channel);

  Future<bool> _ask() async {
    permissionRequests++;
    osAllows = grantOnRequest;
    return grantOnRequest;
  }

  @override
  Future<bool?> requestIosPermissions() => _ask();

  @override
  Future<bool?> requestAndroidPermission() => _ask();

  @override
  Future<bool?> iosPermissionGranted() async => osAllows;

  @override
  Future<bool?> androidNotificationsEnabled() async => osAllows;

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails details,
    String? payload,
  }) async {
    final gate = hold;
    if (gate != null) {
      holdEntered?.complete();
      await gate.future;
    }
    calls.add('schedule $id');
    pending[id] = _Scheduled(scheduledDate, details, payload);
  }

  @override
  Future<void> cancel(int id) async {
    calls.add('cancel $id');
    pending.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    calls.add('cancelAll');
    pending.clear();
  }

  @override
  Future<NotificationAppLaunchDetails?> launchDetails() async {
    launchCalls++;
    return launch;
  }
}

final DateTime _now = DateTime.utc(2030, 1, 7, 9);
const Duration _rest = Duration(seconds: 90);

/// Runs [body] with the wall clock frozen at [_now].
Future<T> _frozen<T>(Future<T> Function() body) =>
    withClock(Clock.fixed(_now), body);

LocalNotificationService _service(
  _FakeGateway gateway, {
  NotificationPlatform platform = NotificationPlatform.android,
}) => LocalNotificationService(
  gateway: gateway,
  platform: platform,
  localTimezoneName: () async => 'UTC',
);

final int _restId = restAlertIdForSession(
  '0b7c9f0e-4d2a-4f53-9a51-3c1e2d4b5a69',
);
final int _otherRestId = restAlertIdForSession(
  '5e2f6a1b-8c3d-4e9f-a0b1-c2d3e4f5a6b7',
);

Future<void> _scheduleRest(LocalNotificationService service, [int? id]) =>
    service.scheduleRestAlert(
      id: id ?? _restId,
      at: clock.now().add(_rest),
      title: 'Rest over',
      body: 'Time for your next set.',
    );

List<NotificationSpec> _nudges() =>
    planStreakReminders(clock.now(), LifetimeStats(), enL10n);

Iterable<int> _nudgeIds(_FakeGateway gateway) => gateway.pending.keys.where(
  (id) =>
      id >= reminderNudgeIdFirst &&
      id < reminderNudgeIdFirst + reminderNudgeIdCount,
);

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('restAlertIdForSession', () {
    test('ist deterministisch und ueber Prozesse stabil (kein hashCode)', () {
      const session = '0b7c9f0e-4d2a-4f53-9a51-3c1e2d4b5a69';
      expect(restAlertIdForSession(session), restAlertIdForSession(session));
      // Pinned: a recovered session must cancel what its previous process
      // scheduled, so the mapping may never drift between runs or versions.
      expect(restAlertIdForSession(session), 2000796619);
      expect(restAlertIdForSession('a'), 2000002220);
    });

    test('liegt im reservierten Bereich, weit weg von den Nudges', () {
      final seen = <int>{};
      for (var i = 0; i < 2000; i++) {
        final id = restAlertIdForSession(
          '${i.toRadixString(16).padLeft(8, '0')}-4d2a-4f53-9a51-3c1e2d4b5a69',
        );
        expect(id, inInclusiveRange(2000000000, 2000999999));
        expect(isRestAlertId(id), isTrue);
        seen.add(id);
      }
      expect(seen.length, greaterThan(1990), reason: 'ids spread out');
      for (
        var id = reminderNudgeIdFirst;
        id < reminderNudgeIdFirst + reminderNudgeIdCount;
        id++
      ) {
        expect(isRestAlertId(id), isFalse);
      }
    });

    test(
      'der Streak-Planer bleibt im Nudge-Bereich (jeder Tag, jede Uhrzeit)',
      () {
        for (var day = 0; day < 60; day++) {
          for (final hour in const [6, 19, 21]) {
            final now = DateTime(2030, 1, 1 + day, hour);
            for (final spec in planStreakReminders(now, LifetimeStats())) {
              expect(
                spec.id,
                inInclusiveRange(
                  reminderNudgeIdFirst,
                  reminderNudgeIdFirst + reminderNudgeIdCount - 1,
                ),
              );
            }
          }
        }
      },
    );
  });

  group('Rest-Alert am Plugin', () {
    test(
      'Android: reservierte Id, Kanal eatova_training, Payload training-rest',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway)..setLocalizations(enL10n);

        await _scheduleRest(service);

        final scheduled = gateway.pending[_restId];
        expect(scheduled, isNotNull);
        expect(scheduled!.payload, trainingRestNotificationPayload);
        expect(scheduled.payload, 'training-rest');
        expect(
          scheduled.when.millisecondsSinceEpoch,
          _now.add(_rest).millisecondsSinceEpoch,
        );
        final android = scheduled.details.android!;
        expect(android.channelId, 'eatova_training');
        expect(android.channelName, enL10n.trainingRestChannelName);
        final channel = gateway.channels.singleWhere(
          (c) => c.id == 'eatova_training',
        );
        expect(channel.name, enL10n.trainingRestChannelName);
        expect(channel.description, enL10n.trainingRestChannelDescription);
        // The reminder channel stays as it was.
        expect(
          gateway.channels.map((c) => c.id),
          containsAll(<String>['eatova_nudges', 'eatova_training']),
        );
      }),
    );

    test(
      'iOS: im Vordergrund nur Ton, kein Banner, keine Liste',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway, platform: NotificationPlatform.ios);

        await _scheduleRest(service);

        final ios = gateway.pending[_restId]!.details.iOS!;
        expect(ios.presentSound, isTrue);
        expect(ios.presentBanner, isFalse);
        expect(ios.presentList, isFalse);
        expect(ios.presentAlert, isFalse);
        expect(ios.presentBadge, isFalse);
        expect(gateway.channels, isEmpty, reason: 'no channels on iOS');
      }),
    );

    test(
      'cancelRestAlert ruft nur cancel(id) auf',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await service.scheduleAll(_nudges());
        await _scheduleRest(service);
        gateway.calls.clear();

        await service.cancelRestAlert(_restId);

        expect(gateway.calls, ['cancel $_restId']);
        expect(gateway.pending.containsKey(_restId), isFalse);
        expect(_nudgeIds(gateway), hasLength(10), reason: 'nudges untouched');
      }),
    );

    test(
      'eine abgelaufene Frist wird nicht geplant und raeumt die alte',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        // -15 s pulled the deadline into the past: the alert for the
        // earlier deadline must not fire later.
        await _scheduleRest(service);

        await service.scheduleRestAlert(
          id: _restId,
          at: clock.now().subtract(const Duration(seconds: 1)),
          title: 'Rest over',
          body: 'Time for your next set.',
        );

        expect(gateway.pending, isEmpty);
        expect(gateway.calls, ['schedule $_restId', 'cancel $_restId']);
      }),
    );

    test(
      'Ids ausserhalb des Rest-Bereichs werden ignoriert (Nudges bleiben)',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await service.scheduleAll(_nudges());
        final nudge = _nudgeIds(gateway).first;
        gateway.calls.clear();

        await _scheduleRest(service, nudge);
        await service.cancelRestAlert(nudge);

        expect(gateway.calls, isEmpty);
        expect(gateway.pending.containsKey(nudge), isTrue);
      }),
    );

    test(
      'nicht unterstuetzte Plattform: no-op',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(
          gateway,
          platform: NotificationPlatform.unsupported,
        );
        await _scheduleRest(service);
        await service.cancelRestAlert(_restId);
        expect(gateway.calls, isEmpty);
      }),
    );
  });

  group('Erinnerungs-Pfade lassen den Rest-Alert stehen', () {
    test(
      'scheduleAll(nudges) storniert die Rest-Id nicht mehr (R/G)',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await _scheduleRest(service);

        await service.scheduleAll(_nudges());

        expect(
          gateway.pending.containsKey(_restId),
          isTrue,
          reason: 'frueher: cancelAll vor jeder Neuplanung',
        );
        expect(gateway.calls, isNot(contains('cancelAll')));
        expect(_nudgeIds(gateway), hasLength(10));
      }),
    );

    test(
      'scheduleAll ersetzt weiterhin alle frueheren Nudges',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await service.scheduleAll(_nudges());
        final before = _nudgeIds(gateway).toSet();
        expect(before, hasLength(10));

        // The next evening: a re-plan yields partly different day ids.
        await withClock(
          Clock.fixed(_now.add(const Duration(days: 3))),
          () => service.scheduleAll(
            planStreakReminders(clock.now(), LifetimeStats(), enL10n),
          ),
        );

        final after = _nudgeIds(gateway).toSet();
        expect(after, hasLength(10), reason: 'no orphans from the old plan');
        expect(after, isNot(before));
        for (
          var id = reminderNudgeIdFirst;
          id < reminderNudgeIdFirst + reminderNudgeIdCount;
          id++
        ) {
          expect(gateway.calls, contains('cancel $id'));
        }
      }),
    );

    test(
      'Erinnerungen aus: der laufende Rest-Alert bleibt (R/G)',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        final store = _store(
          LocalCache(InMemoryKeyValueStore(), 'rest-reminders-off'),
          service,
        );
        await store.setNotificationsEnabled(true);
        expect(_nudgeIds(gateway), isNotEmpty);
        await _scheduleRest(service);

        await store.setNotificationsEnabled(false);

        expect(store.reminderState, ReminderState.off);
        expect(_nudgeIds(gateway), isEmpty);
        expect(gateway.pending.keys, [_restId]);
      }),
    );

    test(
      'OS entzieht die Erlaubnis: blocked raeumt nur die Nudges',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        final store = _store(
          LocalCache(InMemoryKeyValueStore(), 'rest-reminders-blocked'),
          service,
        );
        await store.setNotificationsEnabled(true);
        await _scheduleRest(service);

        gateway.osAllows = false;
        await store.refreshNotificationPermission();

        expect(store.reminderState, ReminderState.blocked);
        expect(_nudgeIds(gateway), isEmpty);
        expect(gateway.pending.keys, [_restId]);
      }),
    );

    test(
      'Kaltstart-Backstop raeumt Altlasten, behaelt aber den Rest-Alert '
      'dieser Sitzung',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        final store = _store(
          LocalCache(InMemoryKeyValueStore(), 'rest-backstop'),
          service,
        );
        // Left behind by an earlier process or account.
        final stale = _Scheduled(
          tz.TZDateTime.from(_now.add(_rest), tz.UTC),
          const NotificationDetails(),
          trainingRestNotificationPayload,
        );
        gateway.pending[_otherRestId] = stale;
        gateway.pending[reminderNudgeIdFirst] = stale;
        // The current session resumed its rest before boot reached the backstop.
        await _scheduleRest(service);

        await store.initNotificationsFromCache();

        expect(
          gateway.calls,
          contains('cancelAll'),
          reason: 'the backstop still clears everything left behind',
        );
        expect(gateway.pending.keys, [_restId]);
        expect(
          gateway.pending[_restId]!.when.millisecondsSinceEpoch,
          _now.add(_rest).millisecondsSinceEpoch,
        );
      }),
    );

    test(
      'Kaltstart-Backstop plant eine bereits abgelaufene Pause nicht neu',
      () async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        final store = _store(
          LocalCache(InMemoryKeyValueStore(), 'rest-backstop-expired'),
          service,
        );
        await _frozen(() => _scheduleRest(service));

        // Boot reaches the backstop after the rest deadline.
        await withClock(
          Clock.fixed(_now.add(_rest).add(const Duration(seconds: 1))),
          store.initNotificationsFromCache,
        );

        expect(gateway.pending, isEmpty);
      },
    );
  });

  group('Sitzungsende', () {
    test(
      'cancelAll ueber das Auth-Gate entfernt den Rest-Alert',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await _scheduleRest(service);

        await cancelDeviceSchedules(notifications: service);

        expect(gateway.pending, isEmpty);
      }),
    );

    test(
      'ein Rest-Alert der beendeten Sitzung wird danach ignoriert',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await _scheduleRest(service);
        await cancelDeviceSchedules(notifications: service);
        gateway.calls.clear();

        // A late continuation of the signed-out player.
        await _scheduleRest(service);

        expect(gateway.pending, isEmpty);
        expect(gateway.calls, isEmpty);
      }),
    );

    test(
      'auch eine Anfrage, die vor der Ausfuehrung des Cancels kommt',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await service.cancelRestAlert(_restId);

        // Neither call is awaited: the request follows the session end.
        final end = cancelDeviceSchedules(notifications: service);
        final late = _scheduleRest(service);
        await Future.wait([end, late]);

        expect(gateway.pending, isEmpty);
        expect(gateway.calls, isNot(contains('schedule $_restId')));
      }),
    );

    test(
      'ein langsamer Plattform-Aufruf landet nicht nach dem Sitzungsende',
      () => _frozen(() async {
        final gateway = _FakeGateway()
          ..hold = Completer<void>()
          ..holdEntered = Completer<void>();
        final service = _service(gateway);
        final scheduling = _scheduleRest(service);
        await gateway.holdEntered!.future;

        final end = cancelDeviceSchedules(notifications: service);
        await Future<void>.delayed(Duration.zero);
        gateway.hold!.complete();
        await scheduling;
        await end;

        expect(
          gateway.pending,
          isEmpty,
          reason: 'FIFO: the cancel waits for the schedule',
        );
      }),
    );

    test(
      'die naechste Sitzung plant ihre eigenen Rest-Alerts',
      () => _frozen(() async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await _scheduleRest(service);
        await cancelDeviceSchedules(notifications: service);

        await _scheduleRest(service, _otherRestId);

        expect(gateway.pending.keys, [_otherRestId]);
      }),
    );
  });

  group('RestAlertPermissionGate', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('notAsked, solange das Geraete-Flag fehlt', () async {
      final gateway = _FakeGateway()..osAllows = false;
      final service = _service(gateway);

      expect(await service.state(), RestAlertPermission.notAsked);
      expect(gateway.permissionRequests, 0, reason: 'state() never prompts');
    });

    test('request() setzt das Flag und fragt das System', () async {
      final gateway = _FakeGateway()
        ..osAllows = false
        ..grantOnRequest = false;
      final service = _service(gateway);

      expect(await service.request(), isFalse);

      expect(gateway.permissionRequests, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(LocalNotificationService.restAlertsAskedKey),
        isTrue,
      );
      expect(await service.state(), RestAlertPermission.denied);
    });

    test('granted, sobald das System zustellt (auch ohne Flag)', () async {
      final service = _service(_FakeGateway()..osAllows = true);
      expect(await service.state(), RestAlertPermission.granted);

      final asked = _FakeGateway()
        ..osAllows = false
        ..grantOnRequest = true;
      final askedService = _service(asked);
      expect(await askedService.request(), isTrue);
      expect(await askedService.state(), RestAlertPermission.granted);
    });
  });

  group('NotificationTapSource', () {
    test(
      'taps liefert den Payload aus onDidReceiveNotificationResponse',
      () async {
        final gateway = _FakeGateway();
        final service = _service(gateway);
        await service.init();
        final taps = expectLater(
          service.taps,
          emitsInOrder(<String>['training-rest']),
        );

        // A reminder tap carries no payload and only opens the app.
        gateway.onResponse!(
          const NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
          ),
        );
        gateway.onResponse!(
          const NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
            payload: trainingRestNotificationPayload,
          ),
        );

        await taps;
      },
    );

    test(
      'launchPayload liest getNotificationAppLaunchDetails genau einmal',
      () async {
        final gateway = _FakeGateway()
          ..launch = const NotificationAppLaunchDetails(
            true,
            notificationResponse: NotificationResponse(
              notificationResponseType:
                  NotificationResponseType.selectedNotification,
              payload: trainingRestNotificationPayload,
            ),
          );
        final service = _service(gateway);

        expect(await service.launchPayload(), 'training-rest');
        expect(
          await service.launchPayload(),
          isNull,
          reason: 'a later home page must not replay the launch tap',
        );
        expect(gateway.launchCalls, 1);
      },
    );

    test('ohne Notification-Start: kein Payload', () async {
      final gateway = _FakeGateway()
        ..launch = const NotificationAppLaunchDetails(false);
      expect(await _service(gateway).launchPayload(), isNull);
    });
  });
}
