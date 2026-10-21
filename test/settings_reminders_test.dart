import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import 'support/harness.dart';

// D11 — the permission switch only knew on/off and therefore lied: denying the
// system dialog still showed "active" while nothing ever arrived. The store
// carries three states (ReminderState); the page must show all three.
//
// The switch is an [AppToggle], whose `onChanged` is non-nullable and which
// expresses the lock via `enabled`; the assertions are unchanged.
//
// The last group opens the page from the app shell: a permission change on
// resume reaches the open page without costing the user's unsaved input.

class _Notifications
    implements NotificationService, NotificationPermissionProbe {
  bool allowed = false;
  int scheduled = 0;

  @override
  Future<void> init() async {}
  @override
  Future<bool> hasPermission() async => allowed;
  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async => scheduled++;
  @override
  Future<void> cancelAll() async => scheduled = 0;
}

void main() {
  Future<Future<SettingsResult?>> openSettings(
    WidgetTester tester, {
    ReminderState? reminderState,
    bool notificationsEnabled = false,
    VoidCallback? onOpenSystemSettings,
  }) async {
    pinPhoneViewport(tester);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    late Future<SettingsResult?> result;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open-settings'),
            onPressed: () {
              result = Navigator.of(context).push<SettingsResult>(
                MaterialPageRoute<SettingsResult>(
                  builder: (_) => GoalsScreen(
                    profile: const UserProfile(),
                    notificationsEnabled: notificationsEnabled,
                    reminderState: reminderState,
                    onOpenSystemSettings: onOpenSystemSettings,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
      brightness: Brightness.light,
      // Motion as before the migration.
      reducedMotion: false,
      safeArea: false,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    return result;
  }

  AppToggle reminderSwitch(WidgetTester tester) => tester
      .widget<AppToggle>(find.byKey(const ValueKey('settings-notifications')));

  testWidgets('off: Schalter aus, Einladung zum Einschalten', (tester) async {
    await openSettings(tester, reminderState: ReminderState.off);

    expect(reminderSwitch(tester).value, isFalse);
    expect(reminderSwitch(tester).enabled, isTrue);
    expect(
      find.text(
        'Aus. Schalter umlegen, um lokale Erinnerungen zu aktivieren.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('active: Schalter an, konkrete Zusage', (tester) async {
    await openSettings(tester, reminderState: ReminderState.active);

    expect(reminderSwitch(tester).value, isTrue);
    expect(
      find.text(
        'Aktiv. Täglich um 20:00, wenn du noch nichts eingetragen hast.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('blocked: Schalter AUS, ehrlicher Text, kein „Fehler"',
      (tester) async {
    await openSettings(tester, reminderState: ReminderState.blocked);

    expect(reminderSwitch(tester).value, isFalse);
    expect(
      find.text(
        'Vom System blockiert. Eatova darf keine Mitteilungen senden — '
        'erlaube sie in den Systemeinstellungen.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Fehler'), findsNothing);
  });

  // That a blocked switch does not flip — by itself or through its row — is
  // pinned in test/widgets/design/toggle_tap_target_test.dart.

  testWidgets('blocked: Button in die Systemeinstellungen, wenn verdrahtet',
      (tester) async {
    var geoeffnet = 0;
    await openSettings(
      tester,
      reminderState: ReminderState.blocked,
      onOpenSystemSettings: () => geoeffnet++,
    );

    final button = find.byKey(const ValueKey('settings-open-system-settings'));
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(geoeffnet, 1);
  });

  testWidgets('ohne verdrahteten Weg gibt es keinen toten Button',
      (tester) async {
    await openSettings(tester, reminderState: ReminderState.blocked);

    expect(find.byKey(const ValueKey('settings-open-system-settings')),
        findsNothing);
  });

  testWidgets('blocked meldet dem Aufrufer weiterhin „aus"', (tester) async {
    final resultFuture =
        await openSettings(tester, reminderState: ReminderState.blocked);

    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    expect((await resultFuture)!.notificationsEnabled, isFalse);
  });

  testWidgets('altes bool-API bleibt gueltig (kein reminderState uebergeben)',
      (tester) async {
    await openSettings(tester, notificationsEnabled: true);

    expect(reminderSwitch(tester).value, isTrue);
    expect(
      find.text(
        'Aktiv. Täglich um 20:00, wenn du noch nichts eingetragen hast.',
      ),
      findsOneWidget,
    );
  });

  group('offen, waehrend sich die Berechtigung aendert (App-Geruest)', () {
    Future<void> tap(WidgetTester tester, String key) async {
      final finder = find.byKey(ValueKey(key));
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<HomeStore> openGoals(
      WidgetTester tester,
      _Notifications notifications,
    ) async {
      pinPhoneViewport(tester);
      final cache = LocalCache(InMemoryKeyValueStore(), 'ui-review');
      await cache.writeNotificationsEnabled(true);
      await pumpLocalized(
        tester,
        EatovaHomePage(notificationService: notifications, debugCache: cache),
        scaffold: false,
        safeArea: false,
      );
      final store =
          (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
              .debugStore;
      await store.initNotificationsFromCache();
      await tester.pumpAndSettle();
      await tap(tester, 'today-profile');
      await tap(tester, 'profile-goalplan-edit');
      return store;
    }

    Future<void> resume(WidgetTester tester) async {
      (tester.state(find.byType(EatovaHomePage, skipOffstage: false))
              as WidgetsBindingObserver)
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    testWidgets('eine erteilte Berechtigung schaltet frei und behaelt den '
        'Entwurf', (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 8, 12)), () async {
        final notifications = _Notifications();
        final store = await openGoals(tester, notifications);
        expect(reminderSwitch(tester).enabled, isFalse);
        await tester.enterText(
          find.byKey(const ValueKey('settings-weight')),
          '82',
        );
        notifications.allowed = true;
        await resume(tester);
        expect(store.reminderState, ReminderState.active);
        expect(reminderSwitch(tester).value, isTrue);
        expect(reminderSwitch(tester).enabled, isTrue);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('settings-weight')))
              .controller!
              .text,
          '82',
        );
        await tap(tester, 'settings-save');
        expect(store.profile.weightKg, 82);
        expect(store.reminderState, ReminderState.active);
        expect(notifications.scheduled, greaterThan(0));
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    testWidgets('ein ungespeichertes Ausschalten ueberlebt den Refresh', (
      tester,
    ) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 8, 12)), () async {
        final notifications = _Notifications()..allowed = true;
        final store = await openGoals(tester, notifications);
        await tap(tester, 'settings-notifications');
        expect(reminderSwitch(tester).value, isFalse);
        notifications.allowed = false;
        await resume(tester);
        notifications.allowed = true;
        await resume(tester);
        expect(store.reminderState, ReminderState.active);
        expect(reminderSwitch(tester).value, isFalse);
        await tap(tester, 'settings-save');
        expect(store.reminderState, ReminderState.off);
        expect(notifications.scheduled, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });
  });
}
