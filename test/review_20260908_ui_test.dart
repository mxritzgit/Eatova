import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import 'support/harness.dart';

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

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<HomeStore> _openGoals(
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
  await _tap(tester, 'today-profile');
  await _tap(tester, 'profile-goalplan-edit');
  return store;
}

Future<void> _resume(WidgetTester tester) async {
  (tester.state(find.byType(EatovaHomePage, skipOffstage: false))
          as WidgetsBindingObserver)
      .didChangeAppLifecycleState(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

AppToggle _reminder(WidgetTester tester) => tester.widget<AppToggle>(
  find.byKey(const ValueKey('settings-notifications')),
);

void main() {
  testWidgets('open goals follow granted permission and preserve the draft', (
    tester,
  ) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 8, 12)), () async {
      final notifications = _Notifications();
      final store = await _openGoals(tester, notifications);
      expect(_reminder(tester).enabled, isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('settings-weight')),
        '82',
      );
      notifications.allowed = true;
      await _resume(tester);
      expect(store.reminderState, ReminderState.active);
      expect(_reminder(tester).value, isTrue);
      expect(_reminder(tester).enabled, isTrue);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('settings-weight')))
            .controller!
            .text,
        '82',
      );
      await _tap(tester, 'settings-save');
      expect(store.profile.weightKg, 82);
      expect(store.reminderState, ReminderState.active);
      expect(notifications.scheduled, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('permission refresh preserves an explicit unsaved opt-out', (
    tester,
  ) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 8, 12)), () async {
      final notifications = _Notifications()..allowed = true;
      final store = await _openGoals(tester, notifications);
      await _tap(tester, 'settings-notifications');
      expect(_reminder(tester).value, isFalse);
      notifications.allowed = false;
      await _resume(tester);
      notifications.allowed = true;
      await _resume(tester);
      expect(store.reminderState, ReminderState.active);
      expect(_reminder(tester).value, isFalse);
      await _tap(tester, 'settings-save');
      expect(store.reminderState, ReminderState.off);
      expect(notifications.scheduled, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  for (final sample in <(int, String)>[
    (3000, '+0,75 kg/Woche'),
    (1600, '−0,5 kg/Woche'),
    (2150, 'Gewicht stabil'),
  ]) {
    testWidgets('manual ${sample.$1} kcal determine profile pace', (
      tester,
    ) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        GoalPlanCard(
          profile: UserProfile(
            weightKg: 78,
            heightCm: 178,
            ageYears: 30,
            targetWeightKg: 68,
            weightGoal: WeightGoal.lose1kg,
            manualEnergy: true,
            dailyKcalGoal: sample.$1,
          ),
        ),
        padding: const EdgeInsets.all(20),
      );
      expect(find.text(sample.$2), findsOneWidget);
      expect(find.textContaining('Ziel in ca.'), findsNothing);
      expect(find.textContaining('Ziel frühestens'), findsNothing);
      expect(find.byType(Tooltip), findsNothing);
    });
  }

  testWidgets('weight input can scroll above the keyboard at large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    double? logged;
    await pumpLocalized(
      tester,
      SingleChildScrollView(
        child: WeightCard(
          profile: const UserProfile(),
          log: const WeightLog(),
          onLogWeight: (value) => logged = value,
        ),
      ),
      textScale: 2,
      padding: const EdgeInsets.all(20),
    );
    await _tap(tester, 'profile-log-weight');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-weight-input')),
      '7',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('profile-weight-input')),
      '79,2',
    );
    final save = find.byKey(const ValueKey('profile-weight-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(save).dy, lessThanOrEqualTo(568 - 280));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(logged, 79.2);
  });
}
