// Ways in from outside the app (review 2026-10-22), mounted as the real home
// page: a tapped reminder leads where its text points (Food's add sheet for
// the current meal, the weigh-in sheet), on a warm tap and on a cold start,
// and the app-icon shortcuts appear only for an onboarded account, in the app
// language, and take the same way in.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/app_entry.dart';
import 'package:eatova/src/services/app_shortcuts.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/rest_alerts.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import '../support/fixlauf_a_helpers.dart';
import '../support/harness.dart';
import 'flow_test_helpers.dart' show pumpUntil, settleFrames, storeOf;

/// Saturday 2026-10-03, 18:00 local: dinner.
final DateTime _now = DateTime(2026, 10, 3, 18);

/// Notifications whose taps the test fires by hand.
class _TapNotifications extends NoopNotificationService
    implements NotificationTapSource {
  _TapNotifications({this.launch});

  final String? launch;
  final StreamController<String> controller =
      StreamController<String>.broadcast();

  @override
  Stream<String> get taps => controller.stream;

  @override
  Future<String?> launchPayload() async => launch;
}

class _Shortcuts extends NoopAppShortcuts {
  final StreamController<AppEntry> controller =
      StreamController<AppEntry>.broadcast();
  final List<List<AppShortcut>> shown = <List<AppShortcut>>[];

  @override
  Stream<AppEntry> get picks => controller.stream;

  @override
  Future<void> show(List<AppShortcut> shortcuts) async => shown.add(shortcuts);
}

class _Camera implements MealCameraLauncher {
  int launches = 0;

  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) async {
    launches++;
    return null;
  }
}

Future<HomeStore> _pumpShell(
  WidgetTester tester, {
  NotificationService notifications = const NoopNotificationService(),
  AppShortcuts shortcuts = const NoopAppShortcuts(),
  MealCameraLauncher? camera,
  EatovaSync? sync,
}) async {
  await pumpLocalized(
    tester,
    EatovaHomePage(
      notificationService: notifications,
      appShortcuts: shortcuts,
      mealCameraLauncher: camera,
      sync: sync,
      debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
    ),
    locale: const Locale('en'),
    surfaceSize: const Size(390, 844),
    scaffold: false,
    safeArea: false,
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'the shell is ready',
  );
  return storeOf(tester);
}

AddMealSheet? _addSheet(WidgetTester tester) {
  final sheets = find.byType(AddMealSheet).evaluate();
  return sheets.isEmpty ? null : sheets.single.widget as AddMealSheet;
}

void main() {
  testWidgets('eine getippte Erinnerung oeffnet das Hinzufuegen fuer die '
      'aktuelle Mahlzeit auf heute, warm und beim Kaltstart', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final notifications = _TapNotifications();
      final store = await _pumpShell(tester, notifications: notifications);
      store.setFoodDate(addDays(_now, -1));
      store.setTab(2);
      await settleFrames(tester);

      notifications.controller.add(AppEntry.logMeal.id);
      await pumpUntil(tester, () => _addSheet(tester) != null, 'the sheet');

      expect(store.selectedTab, 1);
      expect(store.selectedFoodDate, startOfDay(_now));
      expect(_addSheet(tester)!.slot, currentMealSlot());
      expect(_addSheet(tester)!.foodDate, startOfDay(_now));

      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpShell(
        tester,
        notifications: _TapNotifications(launch: AppEntry.logMeal.id),
      );
      await pumpUntil(tester, () => _addSheet(tester) != null, 'cold start');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('die Wiege-Erinnerung oeffnet das Wiege-Blatt', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final notifications = _TapNotifications();
      final store = await _pumpShell(tester, notifications: notifications);
      store.setTab(3);
      await settleFrames(tester);

      notifications.controller.add(AppEntry.weighIn.id);
      final input = find.byKey(const ValueKey('profile-weight-input'));
      await pumpUntil(tester, () => input.evaluate().isNotEmpty, 'the sheet');
      expect(store.selectedTab, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('Kurzbefehle erst nach dem Onboarding, in der App-Sprache; '
      'ein frueher Tipp wartet, Foto startet den KI-Scan des Food-Tabs', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final server = FixlaufServer()
        ..profileRow = serverProfileRow(const UserProfile());
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: server.client(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final shortcuts = _Shortcuts();
      final camera = _Camera();
      final store = await _pumpShell(
        tester,
        shortcuts: shortcuts,
        camera: camera,
        sync: EatovaSync.forUser(client, kFixlaufUser),
      );
      await pumpUntil(tester, () => store.needsOnboarding, 'the onboarding');
      final weightSheet = find.byKey(const ValueKey('profile-weight-input'));

      shortcuts.controller.add(AppEntry.weighIn);
      await settleFrames(tester);
      expect(shortcuts.shown, isEmpty, reason: 'not before the onboarding');
      expect(weightSheet, findsNothing, reason: 'nothing opens over it');

      await store.completeOnboarding(completedProfile);
      await pumpUntil(
        tester,
        () => weightSheet.evaluate().isNotEmpty,
        'the pick waited',
      );
      expect(shortcuts.shown.single.map((s) => s.title), [
        'Photo',
        'Barcode',
        'Describe',
        'Log weight',
      ]);

      await tester.tapAt(const Offset(195, 40));
      await settleFrames(tester);
      expect(weightSheet, findsNothing);
      shortcuts.controller.add(AppEntry.photo);
      await pumpUntil(tester, () => camera.launches == 1, 'the camera');
      expect(store.selectedTab, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
