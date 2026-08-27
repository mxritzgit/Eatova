// Resume hook of the shell (`didChangeAppLifecycleState`) — W3-01. Four store
// capabilities are inert without this one caller:
//
//  * B4  — `maybeRollOverToToday()`: a suspended app gets no midnight tick.
//  * B3  — the resume refresh was gated on `granted`, so `unverified` could
//          never heal after the user allowed access in the iOS settings.
//  * D11 — `refreshNotificationPermission()` gets the user out of
//          `ReminderState.blocked`; nobody called it.
//  * B3b — across midnight with the app open, the rollover keeps YESTERDAY's
//          step count (deliberately, see home_store.dart) while it still feeds
//          burnedKcal/adjustedGoal, so the shell pulls one health refresh per
//          calendar day.
//
// The lifecycle callback is invoked directly on the state — what
// WidgetsBinding does, without replaying the state-machine prelude.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';

import 'support/harness.dart';

/// Health double with a countable read path. [authState] moves on EVERY
/// `readSnapshot()`, exactly as in the real AppleHealthService — that is what
/// lets a refresh heal out of `unverified`/`denied`.
class _FakeHealth implements HealthService {
  _FakeHealth({
    this.initial = HealthAuthState.unverified,
    this.afterRefresh,
    this.steps = 4200,
  });

  final HealthAuthState initial;

  /// State a `readSnapshot()` leaves behind (null keeps [initial]).
  final HealthAuthState? afterRefresh;
  final int steps;

  int snapshotCalls = 0;
  int authorizationCalls = 0;
  late HealthAuthState _state = initial;

  @override
  HealthAuthState get authState => _state;

  @override
  Future<HealthAuthState> requestAuthorization() async {
    authorizationCalls++;
    return _state;
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    snapshotCalls++;
    if (afterRefresh != null) _state = afterRefresh!;
    if (_state != HealthAuthState.granted) return null;
    return HealthSnapshot(stepsToday: steps, fetchedAt: clock.now());
  }

  @override
  void reset() => _state = initial;

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      const <WeightSample>[];

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;
}

/// Notification double with a switchable OS layer (D11). Implements
/// [NotificationPermissionProbe]; otherwise the service counts as always
/// allowed.
class _FakeNotifications
    implements NotificationService, NotificationPermissionProbe {
  _FakeNotifications({this.osAllows = false});

  bool osAllows;
  int scheduleAllCalls = 0;
  int cancelAllCalls = 0;

  @override
  Future<bool> hasPermission() async => osAllows;

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => osAllows;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {
    scheduleAllCalls++;
  }

  @override
  Future<void> cancelAll() async => cancelAllCalls++;
}

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

void _resume(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as WidgetsBindingObserver)
        .didChangeAppLifecycleState(AppLifecycleState.resumed);

Future<void> _pumpHome(
  WidgetTester tester, {
  HealthService? health,
  NotificationService? notifications,
  LocalCache? cache,
}) async {
  await pumpLocalized(
    tester,
    EatovaHomePage(
      healthService: health,
      notificationService: notifications ?? const NoopNotificationService(),
      debugCache: cache,
    ),
    // The shell brings its own Scaffold and safe-area handling.
    scaffold: false,
    safeArea: false,
  );
  await tester.pump();
}

final _montagAbend = DateTime(2026, 6, 1, 21, 0);
final _dienstagFrueh = DateTime(2026, 6, 2, 8, 0);
final _dienstag = DateTime(2026, 6, 2);

void main() {
  group('B4 — Tageswechsel beim Resume', () {
    testWidgets('der Resume rueckt den Store auf den heutigen Tag vor',
        (tester) async {
      late HomeStore store;
      await withClock(Clock.fixed(_montagAbend), () async {
        await _pumpHome(tester);
        store = _storeOf(tester);
        expect(store.selectedFoodDate, DateTime(2026, 6, 1));
      });

      await withClock(Clock.fixed(_dienstagFrueh), () async {
        _resume(tester);
        await tester.pump();
      });

      expect(store.selectedFoodDate, _dienstag,
          reason: 'ohne maybeRollOverToToday() im Resume bleibt der Montag');
    });

    testWidgets('der Rollover laeuft VOR dem Flush', (tester) async {
      // Order: advance the day first, then flush — a refresh triggered by the
      // flush would otherwise still carry the old day.
      late HomeStore store;
      final reihenfolge = <String>[];
      await withClock(Clock.fixed(_montagAbend), () async {
        await _pumpHome(tester);
        store = _storeOf(tester);
      });

      store.addListener(() => reihenfolge.add('notify:${store.selectedFoodDate}'));

      await withClock(Clock.fixed(_dienstagFrueh), () async {
        _resume(tester);
        await tester.pump();
      });

      expect(reihenfolge.first, 'notify:$_dienstag',
          reason: 'die erste Benachrichtigung des Resumes traegt schon '
              'den neuen Tag');
    });
  });

  group('B3 — Health-Resume-Gate', () {
    testWidgets('unverified heilt beim Resume', (tester) async {
      // The user allowed access in the iOS settings and comes back.
      final health = _FakeHealth(
        initial: HealthAuthState.unverified,
        afterRefresh: HealthAuthState.granted,
      );
      await _pumpHome(tester, health: health);
      await tester.pump();

      // connectHealth() in initState only refreshes on `granted`.
      expect(health.snapshotCalls, 0);
      expect(_storeOf(tester).healthAuthState, HealthAuthState.unverified);

      _resume(tester);
      await tester.pump();

      expect(health.snapshotCalls, 1,
          reason: 'der Gate auf == granted laesst unverified nie heilen');
      expect(_storeOf(tester).healthAuthState, HealthAuthState.granted);
      expect(_storeOf(tester).dailySteps, 4200);
    });

    testWidgets('denied heilt beim Resume ebenfalls', (tester) async {
      // readSnapshot() shows no dialog, so healing out of `denied` is safe.
      final health = _FakeHealth(
        initial: HealthAuthState.denied,
        afterRefresh: HealthAuthState.granted,
      );
      await _pumpHome(tester, health: health);
      await tester.pump();
      expect(health.snapshotCalls, 0);

      _resume(tester);
      await tester.pump();

      expect(health.snapshotCalls, 1);
      expect(_storeOf(tester).healthAuthState, HealthAuthState.granted);
    });

    testWidgets('granted refresht weiterhin', (tester) async {
      final health = _FakeHealth(initial: HealthAuthState.granted);
      await _pumpHome(tester, health: health);
      await tester.pump();
      expect(health.snapshotCalls, 1, reason: 'connectHealth beim Kaltstart');

      _resume(tester);
      await tester.pump();

      expect(health.snapshotCalls, 2);
    });

    testWidgets('unsupported refresht NICHT (kein sinnloses Toggeln)',
        (tester) async {
      final health = _FakeHealth(initial: HealthAuthState.unsupported);
      await _pumpHome(tester, health: health);
      await tester.pump();

      _resume(tester);
      await tester.pump();

      expect(health.snapshotCalls, 0);
    });

    testWidgets('ohne Health-Service passiert am Resume nichts', (tester) async {
      await _pumpHome(tester);
      expect(_storeOf(tester).healthAuthState, HealthAuthState.unknown);

      _resume(tester);
      await tester.pump();

      expect(_storeOf(tester).healthAuthState, HealthAuthState.unknown);
    });
  });

  group('D11 — Berechtigungs-Heilung beim Resume', () {
    testWidgets('blocked wird nach der Freigabe im System wieder active',
        (tester) async {
      final notifications = _FakeNotifications(osAllows: false);
      final cache = LocalCache(InMemoryKeyValueStore(), 'u-d11');
      await cache.writeNotificationsEnabled(true);

      await _pumpHome(tester, notifications: notifications, cache: cache);
      final store = _storeOf(tester);

      // Cold-start path: opt-in in cache, OS refuses -> blocked.
      await store.initNotificationsFromCache();
      await tester.pump();
      expect(store.reminderState, ReminderState.blocked);
      expect(notifications.scheduleAllCalls, 0);

      // The user was in the system settings and comes back.
      notifications.osAllows = true;
      _resume(tester);
      await tester.pump();
      await tester.pump();

      expect(store.reminderState, ReminderState.active,
          reason: 'refreshNotificationPermission() hatte keinen Aufrufer');
      expect(notifications.scheduleAllCalls, 1,
          reason: 'nach der Heilung wird der Streak-Reminder neu geplant');
    });

    testWidgets('ausgeschaltet bleibt ausgeschaltet', (tester) async {
      // A system setting must not turn reminders on for someone who opted
      // out: refreshNotificationPermission() stops at `off`.
      final notifications = _FakeNotifications(osAllows: true);
      final cache = LocalCache(InMemoryKeyValueStore(), 'u-d11-off');

      await _pumpHome(tester, notifications: notifications, cache: cache);
      final store = _storeOf(tester);
      await store.initNotificationsFromCache();
      await tester.pump();
      expect(store.reminderState, ReminderState.off);

      _resume(tester);
      await tester.pump();
      await tester.pump();

      expect(store.reminderState, ReminderState.off);
      expect(notifications.scheduleAllCalls, 0);
    });
  });

  group('B3b — veralteter Schrittstand ueber Mitternacht', () {
    testWidgets('ein Tageswechsel bei offener App zieht die Schritte nach',
        (tester) async {
      final health = _FakeHealth(initial: HealthAuthState.granted, steps: 9000);
      late HomeStore store;
      await withClock(Clock.fixed(_montagAbend), () async {
        await _pumpHome(tester, health: health);
        await tester.pump();
        store = _storeOf(tester);
      });
      expect(health.snapshotCalls, 1, reason: 'Kaltstart');
      expect(store.dailySteps, 9000);

      // The store's midnight timer fires with the app open. The rollover
      // deliberately keeps dailySteps, so the shell must pull the refresh.
      withClock(Clock.fixed(_dienstagFrueh), () {
        expect(store.maybeRollOverToToday(), isTrue);
      });
      await tester.pump();

      expect(health.snapshotCalls, 2,
          reason: 'sonst speist Montags Schrittstand den ganzen Dienstag '
              'burnedKcal und adjustedGoal');
    });

    testWidgets('ohne Tageswechsel loest kein Notify einen Refresh aus',
        (tester) async {
      final health = _FakeHealth(initial: HealthAuthState.granted);
      await _pumpHome(tester, health: health);
      await tester.pump();
      final store = _storeOf(tester);
      expect(health.snapshotCalls, 1);

      for (var i = 0; i < 5; i++) {
        store.setTab(i % 3);
        await tester.pump();
      }

      expect(health.snapshotCalls, 1,
          reason: 'der Nachzug haengt am Kalendertag, nicht an jedem Notify');
    });
  });
}
