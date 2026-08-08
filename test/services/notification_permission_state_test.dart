import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';

// D11 (Review 2026-08-08): Der Berechtigungsschalter luegt.
//
// Vorher setzte `_setNotificationsEnabled(true)` das Flag in State UND Cache,
// BEVOR der Systemdialog beantwortet war. Tippte der Nutzer „Nicht zulassen",
// blieb der Schalter fuer immer auf AN — es kam nur nie etwas. Der Kaltstart
// las dieses `true` und plante ohne jede Pruefung ins Leere; ein spaeterer
// Entzug in den Systemeinstellungen wurde nie bemerkt.
//
// Es gibt drei Zustaende, nicht zwei:
//   off     — der Nutzer will keine Erinnerungen
//   active  — der Nutzer will sie UND das OS liefert sie aus
//   blocked — der Nutzer will sie, das OS verweigert sie
//
// Wichtig ist die Trennung von PRUEFEN und ANFRAGEN: der Kaltstart darf die
// OS-Ebene nur gegenlesen (`hasPermission`), niemals einen Systemdialog
// ausloesen (`requestPermission`).

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  Color accent = const Color(0xFFFFFFFF),
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Test-Double mit getrennten Schaltern fuer „Dialog-Antwort" und
/// „OS-Wahrheit" — genau die beiden Dinge, die die Produktion verwechselt hat.
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

  /// Simuliert den Nutzer, der die Berechtigung in den Systemeinstellungen
  /// nachtraeglich erteilt oder entzieht — ohne dass die App laeuft.
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
  });

  group('D11 — Nachtraeglicher Wechsel in den Systemeinstellungen', () {
    test('blockiert -> erlaubt: refresh holt den Nutzer zurueck in aktiv',
        () async {
      final cache = newCache();
      final svc = _FakeNotificationService(grantOnRequest: false);
      final store = _storeWith(cache, svc);
      await store.setNotificationsEnabled(true);
      expect(store.reminderState, ReminderState.blocked);

      // Nutzer oeffnet die Systemeinstellungen und erlaubt.
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
      // Sentinel-Fund 2 (Nachverifikation 2026-08-08): die erste Fassung
      // dieses Tests schrieb das Raten als Soll fest — „unbekannt" wurde als
      // ReminderState.active behauptet. Genau die Klasse, die D11 gefixt hat:
      // gruener Schalter ohne Beleg, dass je etwas zugestellt wird.
      //
      // Neuer Vertrag fuer „nicht feststellbar": NICHTS behaupten (kein
      // active), NICHTS planen (der active-Pfad waere die einzige Quelle)
      // und NICHTS entwerten — der persistierte Opt-in bleibt stehen, damit
      // der naechste Boot mit einem probe-faehigen Dienst den echten Zustand
      // wiederherstellen kann. Kein cancelAll aus Unwissen.
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

/// Implementiert NUR das Basis-Interface (keine Probe) — so wie es bestehende
/// Test-Doubles im Projekt tun.
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
