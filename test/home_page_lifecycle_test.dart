// Resume-Hook der Schale (`didChangeAppLifecycleState`) — W3-01.
//
// Vier Uebergaben aus Welle 2 haengen alle an dieser einen Stelle. Der Store
// bringt die Faehigkeiten mit, aber ohne Aufrufer sind sie inert:
//
//  * B4  — `maybeRollOverToToday()`: eine suspendierte App bekommt keinen
//          Mitternachts-Timer-Tick, der Tageswechsel faellt ohne den Resume
//          komplett aus.
//  * B3  — der Resume-Refresh war auf `HealthAuthState.granted` gegatet. Der
//          seit Welle 2 existierende Zustand `unverified` konnte damit nie
//          heilen: Nutzer gibt in den iOS-Einstellungen frei, kommt zurueck,
//          und niemand prueft nach.
//  * D11 — `refreshNotificationPermission()` holt den Nutzer aus
//          `ReminderState.blocked` zurueck. Es rief niemand auf.
//  * B3b — liegt die App ueber Mitternacht offen, laesst der Rollover den
//          Schrittstand von GESTERN stehen (bewusst, s. home_store.dart) — er
//          speist aber weiter burnedKcal/adjustedGoal. Die Schale zieht
//          deshalb pro Kalendertag genau einen Health-Refresh nach.
//
// Der Lifecycle-Callback wird direkt auf dem State aufgerufen: genau das macht
// die WidgetsBinding auch, nur ohne die Zustandsautomat-Vorgeschichte
// (resumed -> inactive -> hidden -> paused -> ... -> resumed) nachstellen zu
// muessen.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Health-Double mit zaehlbarem Lesepfad. [authState] wandert genau wie beim
/// echten AppleHealthService bei JEDEM `readSnapshot()` mit (dort ueber den
/// HealthAuthVerifier, apple_health_service.dart:319-334) — deshalb kann ein
/// Refresh aus `unverified`/`denied` heraus ueberhaupt heilen.
class _FakeHealth implements HealthService {
  _FakeHealth({
    this.initial = HealthAuthState.unverified,
    this.afterRefresh,
    this.steps = 4200,
  });

  final HealthAuthState initial;

  /// Zustand, den ein `readSnapshot()` hinterlaesst (null = [initial] bleibt).
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
}

/// Notification-Double mit umlegbarer OS-Ebene (D11). Implementiert die
/// [NotificationPermissionProbe], sonst gilt der Dienst als „darf immer".
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
  await tester.pumpWidget(
    MaterialApp(
      // Design-Refactor 2026-08: die Schale liest Farben ueber `context.t`
      // (AppTokens als ThemeExtension). `AppTokens.of` wirft absichtlich, wenn
      // die Extension fehlt — ohne `theme:` scheitert schon der erste Build.
      theme: buildEatovaTheme(Brightness.dark),
      // _navItems() liest jetzt context.l10n (Spec §4) — ohne diese
      // Lokalisierung wirft AppLocalizations.of() beim Bau der Bottom-Nav.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: EatovaHomePage(
        healthService: health,
        notificationService:
            notifications ?? const NoopNotificationService(),
        debugCache: cache,
      ),
    ),
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
      // Reihenfolge: erst den Tag vorruecken, dann flushen — ein durch den
      // Flush ausgeloester Refresh traegt sonst noch den alten Tag.
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
      // Nutzer hat in den iOS-Einstellungen freigeschaltet und kommt zurueck.
      final health = _FakeHealth(
        initial: HealthAuthState.unverified,
        afterRefresh: HealthAuthState.granted,
      );
      await _pumpHome(tester, health: health);
      await tester.pump();

      // connectHealth() im initState refresht nur bei `granted` — hier nicht.
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
      // readSnapshot() zeigt keinen Dialog (es liest nur Signale gegen), der
      // Weg zurueck aus `denied` ist also gefahrlos.
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

      // Kaltstart-Pfad: Opt-in im Cache, OS verweigert -> blocked.
      await store.initNotificationsFromCache();
      await tester.pump();
      expect(store.reminderState, ReminderState.blocked);
      expect(notifications.scheduleAllCalls, 0);

      // Nutzer war in den Systemeinstellungen und kommt zurueck.
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
      // Wer keine Erinnerungen will, bekommt durch eine Systemeinstellung
      // keine — refreshNotificationPermission() haelt bei `off` an.
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

      // Mitternachts-Timer des Stores feuert, die App liegt offen. Der
      // Rollover laesst dailySteps bewusst stehen (Health-Zustaendigkeit) —
      // die Schale muss den Nachzug ausloesen.
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
