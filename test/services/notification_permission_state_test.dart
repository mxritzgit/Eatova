import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// D11 (Review 2026-08-08): the permission switch used to lie — the flag was
// persisted before the system dialog was answered, so a denial left the switch
// on forever. Hence three states, not two: off, active (the OS delivers) and
// blocked (the user wants reminders, the OS refuses). Cold start may only
// CHECK (`hasPermission`), never REQUEST (`requestPermission`).

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Test double with separate switches for "dialog answer" and "OS truth" —
/// exactly the two things production used to conflate.
class _FakeNotificationService
    implements NotificationService, NotificationPermissionProbe {
  _FakeNotificationService({bool grantOnRequest = true, bool? osAllows})
      : _grantOnRequest = grantOnRequest,
        _osAllows = osAllows ?? grantOnRequest;

  bool _grantOnRequest;
  bool _osAllows;

  int initCalls = 0;
  int requestCalls = 0;
  int hasPermissionCalls = 0;
  int cancelAllCalls = 0;
  final List<List<NotificationSpec>> scheduled = <List<NotificationSpec>>[];

  /// Simulates the user granting or revoking the permission in the system
  /// settings while the app is not running.
  void setOsPermission(bool allowed) {
    _osAllows = allowed;
    _grantOnRequest = allowed;
  }

  @override
  Future<void> init() async => initCalls++;

  @override
  Future<bool> requestPermission() async {
    requestCalls++;
    return _grantOnRequest;
  }

  @override
  Future<bool> hasPermission() async {
    hasPermissionCalls++;
    return _osAllows;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async =>
      scheduled.add(specs);

  @override
  Future<void> cancelAll() async => cancelAllCalls++;
}

/// Plugin layer that is unusable right now (F7-12): `init()` throws the way
/// flutter_local_notifications does when the Android channel is missing.
class _ExplodingNotificationService extends _FakeNotificationService {
  @override
  Future<void> init() async {
    initCalls++;
    throw PlatformException(code: 'channel_error', message: 'kein Kanal');
  }
}

const MealAnalysisResult _mahlzeit = MealAnalysisResult(
  mealName: 'Linsensuppe',
  caloriesKcal: 420,
  estimatedGrams: 350,
  kcalPer100G: 120,
  protein: '20 g',
  carbs: '50 g',
  fat: '10 g',
  confidence: 'Hoch',
  portionNotes: '',
);

HomeStore _storeWith(LocalCache cache, NotificationService notifications) =>
    HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: notifications,
      initialUserName: 'Test',
      emitSnack: _noopSnack,
      debugCache: cache,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LocalCache newCache() => LocalCache(InMemoryKeyValueStore(), 'user-d11');

  group('D11 — Einschalten (Systemdialog)', () {
    test(
        'abgelehnt: das persistierte Flag ist NICHT true und der Zustand ist '
        'blockiert, nicht aus', () async {
      final cache = newCache();
      final svc = _FakeNotificationService(grantOnRequest: false);

      await _storeWith(cache, svc).setNotificationsEnabled(true);

      expect(await cache.readNotificationsEnabled() ?? false, isFalse,
          reason: 'nichts erlaubt -> nichts als „aktiv" persistieren');
      expect(svc.scheduled, isEmpty);
    });

    test('abgelehnt: der Store meldet blocked (dritter Zustand)', () async {
      final svc = _FakeNotificationService(grantOnRequest: false);
      final store = _storeWith(newCache(), svc);

      await store.setNotificationsEnabled(true);

      expect(store.reminderState, ReminderState.blocked);
      expect(store.notificationsEnabled, isFalse,
          reason: 'blockiert heisst: es wird nichts ausgeliefert');
    });

    test('erlaubt: Flag persistiert, Zustand aktiv, Reminder geplant',
        () async {
      final cache = newCache();
      final svc = _FakeNotificationService(grantOnRequest: true);
      final store = _storeWith(cache, svc);

      await store.setNotificationsEnabled(true);

      expect(await cache.readNotificationsEnabled(), isTrue);
      expect(store.reminderState, ReminderState.active);
      expect(store.notificationsEnabled, isTrue);
      expect(svc.scheduled, hasLength(1));
      expect(svc.scheduled.single, isNotEmpty);
    });

    test('ausschalten: Zustand aus, Flag false, alles verworfen', () async {
      final cache = newCache();
      final svc = _FakeNotificationService(grantOnRequest: true);
      final store = _storeWith(cache, svc);
      await store.setNotificationsEnabled(true);

      await store.setNotificationsEnabled(false);

      expect(store.reminderState, ReminderState.off);
      expect(await cache.readNotificationsEnabled(), isFalse);
      expect(svc.cancelAllCalls, 1);
    });
  });

  group('D11 — Kaltstart', () {
    test(
        'Cache sagt true, das OS hat die Berechtigung entzogen: Zustand wird '
        'korrigiert und NICHTS geplant', () async {
      final cache = newCache();
      await cache.writeNotificationsEnabled(true);
      final svc = _FakeNotificationService(osAllows: false);
      final store = _storeWith(cache, svc);

      await store.initNotificationsFromCache();

      expect(store.reminderState, ReminderState.blocked);
      expect(svc.scheduled, isEmpty,
          reason: 'ohne Berechtigung liefe zonedSchedule ins Leere');
      expect(await cache.readNotificationsEnabled() ?? false, isFalse,
          reason: 'das persistierte „aktiv" war nachweislich falsch');
    });

    test('Kaltstart PRUEFT, er FRAGT nicht — kein Systemdialog beim Boot',
        () async {
      final cache = newCache();
      await cache.writeNotificationsEnabled(true);
      final svc = _FakeNotificationService(osAllows: false);

      await _storeWith(cache, svc).initNotificationsFromCache();

      expect(svc.requestCalls, 0,
          reason: 'ein Systemdialog beim Kaltstart ueberfaellt den Nutzer');
      expect(svc.hasPermissionCalls, 1);
    });

    test('Cache true + Berechtigung da: Zustand aktiv, Reminder geplant',
        () async {
      final cache = newCache();
      await cache.writeNotificationsEnabled(true);
      final svc = _FakeNotificationService(osAllows: true);
      final store = _storeWith(cache, svc);

      await store.initNotificationsFromCache();

      expect(store.reminderState, ReminderState.active);
      expect(svc.requestCalls, 0);
      expect(svc.scheduled, hasLength(1));
    });

    test('Cache leer/false: nichts geplant, das OS wird gar nicht gefragt',
        () async {
      final cache = newCache();
      final svc = _FakeNotificationService(osAllows: true);
      final store = _storeWith(cache, svc);

      await store.initNotificationsFromCache();

      expect(store.reminderState, ReminderState.off);
      expect(svc.hasPermissionCalls, 0);
      expect(svc.scheduled, isEmpty);
    });

    test('wirft die Plugin-Schicht, landet der Nutzer in blocked — nicht in '
        'off und nicht in einem Zonenfehler', () async {
      // F7-12/F1-09: a PlatformException from `init()` used to escape as an
      // unhandled zone error on EVERY cold start. The fence is a bare `catch`
      // whose only visible effect is the resulting state, so nothing held it
      // to `blocked`: `off` would silently disown an opt-in the user made.
      final cache = newCache();
      await cache.writeNotificationsEnabled(true);
      final svc = _ExplodingNotificationService();
      final store = _storeWith(cache, svc);

      await store.initNotificationsFromCache();

      expect(store.reminderState, ReminderState.blocked);
      expect(store.notificationsEnabled, isFalse);
      expect(svc.scheduled, isEmpty);
      expect(await cache.readNotificationsEnabled(), isTrue,
          reason: 'nichts bewiesen -> das Opt-in bleibt unangetastet');
    });
  });

  group('D11 — Planen ist an die Berechtigung gebunden', () {
    test('eine Mahlzeit im Zustand off plant keinen Reminder', () async {
      // The reminder replan hangs off meal logging, and that path knows
      // nothing about the permission — only the guard inside the planner call
      // does. Every other test here enters through the notification API, where
      // the state is already `active`, so the guard could be deleted without
      // a red test while the app scheduled notifications nobody allowed.
      final cache = newCache();
      final svc = _FakeNotificationService(osAllows: true);
      final store = _storeWith(cache, svc);

      await store.initNotificationsFromCache(); // no opt-in -> off
      expect(store.reminderState, ReminderState.off);

      store.addResultToDailyTotal(_mahlzeit);
      await Future<void>.delayed(Duration.zero);

      expect(svc.scheduled, isEmpty);
    });

    test('dieselbe Mahlzeit im Zustand active plant sehr wohl', () async {
      final cache = newCache();
      await cache.writeNotificationsEnabled(true);
      final svc = _FakeNotificationService(osAllows: true);
      final store = _storeWith(cache, svc);
      await store.initNotificationsFromCache();
      expect(store.reminderState, ReminderState.active);
      final vorher = svc.scheduled.length;

      store.addResultToDailyTotal(_mahlzeit);
      await Future<void>.delayed(Duration.zero);

      expect(svc.scheduled.length, vorher + 1);
    });
  });

  group('D11 — Nachtraeglicher Wechsel in den Systemeinstellungen', () {
    test('blockiert -> erlaubt: refresh holt den Nutzer zurueck in aktiv',
        () async {
      final cache = newCache();
      final svc = _FakeNotificationService(grantOnRequest: false);
      final store = _storeWith(cache, svc);
      await store.setNotificationsEnabled(true);
      expect(store.reminderState, ReminderState.blocked);

      // User opens the system settings and allows it.
      svc.setOsPermission(true);
      await store.refreshNotificationPermission();

      expect(store.reminderState, ReminderState.active);
      expect(await cache.readNotificationsEnabled(), isTrue);
      expect(svc.scheduled, hasLength(1));
      expect(svc.requestCalls, 1,
          reason: 'der Refresh prueft nur, er fragt nicht erneut');
    });

    test('aktiv -> entzogen: refresh faellt auf blockiert und raeumt auf',
        () async {
      final cache = newCache();
      final svc = _FakeNotificationService(grantOnRequest: true);
      final store = _storeWith(cache, svc);
      await store.setNotificationsEnabled(true);

      svc.setOsPermission(false);
      await store.refreshNotificationPermission();

      expect(store.reminderState, ReminderState.blocked);
      expect(await cache.readNotificationsEnabled() ?? false, isFalse);
      expect(svc.cancelAllCalls, greaterThanOrEqualTo(1));
    });

    test('aus bleibt aus: der Refresh fragt das OS gar nicht erst', () async {
      final svc = _FakeNotificationService(osAllows: true);
      final store = _storeWith(newCache(), svc);

      await store.refreshNotificationPermission();

      expect(store.reminderState, ReminderState.off);
      expect(svc.hasPermissionCalls, 0);
      expect(svc.scheduled, isEmpty);
    });
  });

  group('D11 — Service-Naht', () {
    test('NoopNotificationService meldet ehrlich „keine Berechtigung"',
        () async {
      const noop = NoopNotificationService();
      expect(await noop.hasPermission(), isFalse);
    });

    test(
        'ein Dienst OHNE Probe: Kaltstart laeuft durch, behauptet aber nichts '
        'und entwertet nichts', () async {
      // Contract for "cannot be determined": claim NOTHING (no active),
      // schedule NOTHING, and invalidate NOTHING — the persisted opt-in stays
      // so the next boot with a probe-capable service can restore the real
      // state. No cancelAll out of ignorance.
      final cache = newCache();
      await cache.writeNotificationsEnabled(true);
      final svc = _ProbelessNotificationService();
      final store = _storeWith(cache, svc);

      await expectLater(store.initNotificationsFromCache(), completes);
      expect(store.reminderState, isNot(ReminderState.active),
          reason: 'aus „ich weiss es nicht" darf kein „aktiv" werden');
      expect(await cache.readNotificationsEnabled(), isTrue,
          reason: 'der Opt-in des Nutzers wird nicht aus Unwissen geloescht');
      expect(svc.scheduled, isEmpty,
          reason: 'geplant wird nur im belegten active-Zustand');
      expect(svc.cancelAllCalls, 0,
          reason: 'Bestehendes wird nicht aus Unwissen verworfen');
    });
  });
}

/// Implements ONLY the base interface (no probe), like the other test doubles
/// in this project.
class _ProbelessNotificationService implements NotificationService {
  int cancelAllCalls = 0;
  final List<List<NotificationSpec>> scheduled = <List<NotificationSpec>>[];

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async =>
      scheduled.add(specs);

  @override
  Future<void> cancelAll() async => cancelAllCalls++;
}
