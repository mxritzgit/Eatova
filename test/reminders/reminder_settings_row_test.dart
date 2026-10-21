import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/reminder_time.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/harness.dart';

// C4: the reminder has its own row in the settings (switch and time), and
// "Profil & Ziele" names the same time from the same store state.

class _Notifications
    implements NotificationService, NotificationPermissionProbe {
  bool grant = true;
  int requests = 0;
  final List<List<NotificationSpec>> scheduled = <List<NotificationSpec>>[];

  @override
  Future<void> init() async {}
  @override
  Future<bool> hasPermission() async => grant;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return grant;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async =>
      scheduled.add(specs);
  @override
  Future<void> cancelAll() async {}
}

AppToggle _toggle(WidgetTester tester) => tester.widget<AppToggle>(
  find.byKey(const ValueKey('settings-reminder-toggle')),
);

String _status(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('settings-reminder-status')))
    .data!;

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('Zeile in den Einstellungen', () {
    late List<bool> toggled;
    late List<ReminderTime> times;
    late List<bool> weighInToggled;
    late int systemSettingsOpened;

    setUp(() {
      toggled = <bool>[];
      times = <ReminderTime>[];
      weighInToggled = <bool>[];
      systemSettingsOpened = 0;
    });

    Widget settings({
      ReminderState state = ReminderState.off,
      ReminderState weighIn = ReminderState.off,
      ReminderTime time = ReminderTime.standard,
      bool alwaysUse24h = false,
    }) => Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(alwaysUse24HourFormat: alwaysUse24h),
        child: SettingsScreen(
          reminderState: state,
          reminderTime: time,
          onReminderEnabledChanged: toggled.add,
          onReminderTimeChanged: times.add,
          weighInReminderState: weighIn,
          onWeighInReminderChanged: weighInToggled.add,
          onOpenNotificationSettings: () => systemSettingsOpened++,
        ),
      ),
    );

    const Key openSystemSettings = ValueKey(
      'settings-reminder-open-system-settings',
    );
    const Key weighInOpenSystemSettings = ValueKey(
      'settings-weigh-in-open-system-settings',
    );

    testWidgets('aus: eigene Zeile mit Schalter und Uhrzeit', (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(tester, settings(time: const ReminderTime(21, 30)));

      expect(find.byKey(const ValueKey('settings-reminder')), findsOneWidget);
      expect(find.text('Erinnerung'), findsOneWidget);
      expect(find.text('21:30'), findsOneWidget);
      expect(_toggle(tester).value, isFalse);
      expect(
        _status(tester),
        'Aus. Schalter umlegen, um lokale Erinnerungen zu aktivieren.',
      );
      // The page and the goals row both name the reminder now.
      expect(
        find.text('Konto, Darstellung, Erinnerung und Datenschutz'),
        findsOneWidget,
      );

      await _tap(
        tester,
        find.byKey(const ValueKey('settings-reminder-toggle')),
      );
      expect(toggled, <bool>[true]);
    });

    testWidgets('aktiv: der Satz nennt die gewaehlte Uhrzeit', (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        settings(state: ReminderState.active, time: const ReminderTime(6, 45)),
      );

      expect(_toggle(tester).value, isTrue);
      expect(
        _status(tester),
        'Aktiv. Täglich um 06:45, wenn du noch nichts eingetragen hast.',
      );
      await _tap(tester, find.text('Erinnerung'));
      expect(toggled, <bool>[false], reason: 'the row is the switch target');
    });

    testWidgets('blockiert: Schalter gesperrt, ein Knopf in die '
        'Systemeinstellungen, die Uhrzeit bleibt waehlbar', (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(tester, settings());
      expect(find.byKey(openSystemSettings), findsNothing);

      await pumpLocalized(tester, settings(state: ReminderState.blocked));

      expect(_toggle(tester).enabled, isFalse);
      expect(_status(tester), startsWith('Vom System blockiert.'));
      await _tap(
        tester,
        find.byKey(const ValueKey('settings-reminder-toggle')),
      );
      await _tap(tester, find.text('Erinnerung'));
      expect(toggled, isEmpty, reason: 'D11: no back door through the row');

      await _tap(tester, find.byKey(openSystemSettings));
      expect(systemSettingsOpened, 1);

      await _tap(tester, find.byKey(const ValueKey('settings-reminder-time')));
      expect(find.byType(TimePickerDialog), findsOneWidget);
    });

    testWidgets('Wiege-Erinnerung: eigener Schalter; blockiert mit Knopf, '
        'aber nur einer, wenn beide blockiert sind', (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(tester, settings(state: ReminderState.active));
      final toggle = find.byKey(
        const ValueKey('settings-weigh-in-reminder-toggle'),
      );
      await _tap(tester, toggle);
      expect(weighInToggled, <bool>[true]);
      expect(toggled, isEmpty, reason: 'its own switch');

      await pumpLocalized(
        tester,
        settings(state: ReminderState.active, weighIn: ReminderState.blocked),
      );
      expect(tester.widget<AppToggle>(toggle).enabled, isFalse);
      await _tap(tester, find.byKey(weighInOpenSystemSettings));
      expect(systemSettingsOpened, 1);

      await pumpLocalized(
        tester,
        settings(state: ReminderState.blocked, weighIn: ReminderState.blocked),
      );
      expect(find.byKey(openSystemSettings), findsOneWidget);
      expect(find.byKey(weighInOpenSystemSettings), findsNothing);
    });

    testWidgets('Material-Timepicker: die gewaehlte Zeit geht an den Store', (
      tester,
    ) async {
      pinPhoneViewport(tester);
      await pumpLocalized(tester, settings());

      await _tap(tester, find.byKey(const ValueKey('settings-reminder-time')));
      expect(find.byType(TimePickerDialog), findsOneWidget);
      expect(find.text('Uhrzeit der Erinnerung'), findsOneWidget);

      // Keyboard entry instead of the dial.
      await _tap(tester, find.byIcon(Icons.keyboard_outlined));
      final fields = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '7');
      await tester.enterText(fields.at(1), '15');
      await _tap(tester, find.text('OK'));

      expect(times, const <ReminderTime>[ReminderTime(7, 15)]);
    });

    testWidgets('Abbrechen im Timepicker aendert nichts', (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(tester, settings());

      await _tap(tester, find.byKey(const ValueKey('settings-reminder-time')));
      await _tap(tester, find.text('Abbrechen'));

      expect(times, isEmpty);
      expect(find.byType(TimePickerDialog), findsNothing);
    });

    testWidgets('12 h im Englischen, 24 h wenn das System es verlangt', (
      tester,
    ) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        settings(state: ReminderState.active, time: const ReminderTime(21, 30)),
        locale: const Locale('en'),
      );
      expect(find.text('9:30 PM'), findsOneWidget);
      expect(
        _status(tester),
        "Active. Daily at 9:30 PM if you haven't logged anything yet.",
      );

      await pumpLocalized(
        tester,
        settings(
          state: ReminderState.active,
          time: const ReminderTime(21, 30),
          alwaysUse24h: true,
        ),
        locale: const Locale('en'),
      );
      expect(find.text('21:30'), findsOneWidget);
    });

    testWidgets('ohne Store-Anbindung faellt die Zeile weg', (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(tester, const SettingsScreen());
      expect(find.byKey(const ValueKey('settings-reminder')), findsNothing);
    });

    testWidgets('doppelte Schrift bei 320 px laeuft in keinem Zustand ueber', (
      tester,
    ) async {
      for (final state in ReminderState.values) {
        await pumpLocalized(
          tester,
          settings(state: state, weighIn: state),
          textScale: 2.0,
          surfaceSize: const Size(320, 1400),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$state');
        expect(find.byKey(const ValueKey('settings-reminder')), findsOneWidget);
      }
    });
  });

  group('Profil & Ziele', () {
    testWidgets('der Schalter nennt die gewaehlte Uhrzeit', (tester) async {
      pinPhoneViewport(tester);
      final prior = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception.toString().contains('overflowed')) return;
        prior?.call(details);
      };
      addTearDown(() => FlutterError.onError = prior);

      await pumpLocalized(
        tester,
        const GoalsScreen(
          profile: UserProfile(),
          reminderState: ReminderState.active,
          reminderTime: ReminderTime(21, 30),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Aktiv. Täglich um 21:30, wenn du noch nichts eingetragen hast.',
        ),
        findsOneWidget,
      );
    });
  });

  group('dieselbe Quelle im App-Geruest', () {
    testWidgets(
      'Schalter und Uhrzeit in den Einstellungen wirken sofort, Profil & '
      'Ziele zeigt dieselbe Zeit',
      (tester) async {
        await withClock(Clock.fixed(DateTime(2026, 9, 8, 12)), () async {
          pinPhoneViewport(tester);
          final notifications = _Notifications();
          final cache = LocalCache(InMemoryKeyValueStore(), 'settings-row');
          await pumpLocalized(
            tester,
            EatovaHomePage(
              notificationService: notifications,
              debugCache: cache,
            ),
            scaffold: false,
            safeArea: false,
          );
          final store =
              (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
                  .debugStore;
          await store.initNotificationsFromCache();
          await tester.pumpAndSettle();

          await _tap(tester, find.byKey(const ValueKey('today-profile')));
          await _tap(
            tester,
            find.byKey(const ValueKey('profile-open-settings')),
          );
          await _tap(
            tester,
            find.byKey(const ValueKey('settings-reminder-toggle')),
          );
          expect(store.reminderState, ReminderState.active);
          expect(notifications.requests, 1);
          expect(_toggle(tester).value, isTrue);

          await store.setReminderTime(const ReminderTime(21, 30));
          await tester.pumpAndSettle();
          expect(find.text('21:30'), findsOneWidget);
          expect(
            notifications.scheduled.last.first.scheduledFor,
            DateTime(2026, 9, 8, 21, 30),
          );
          expect(await cache.readReminderTime(), const ReminderTime(21, 30));

          // The settings row says the same sentence, so the text alone would
          // pass without the goals page: read it inside the goals' own note.
          await _tap(tester, find.byKey(const ValueKey('settings-open-goals')));
          expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('settings-reminder-note')),
              matching: find.text(
                'Aktiv. Täglich um 21:30, wenn du noch nichts eingetragen hast.',
              ),
            ),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        });
      },
    );

    testWidgets(
      'blockiert: Einstellungen und Ziele fuehren in die '
      'Mitteilungs-Einstellungen des Systems',
      (tester) async {
        await withClock(Clock.fixed(DateTime(2026, 9, 8, 12)), () async {
          pinPhoneViewport(tester);
          const channel = MethodChannel('com.spencerccf.app_settings/methods');
          final opened = <Object?>[];
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(channel, (call) async {
            opened.add((call.arguments as Map)['type']);
            return null;
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          final notifications = _Notifications()..grant = false;
          await pumpLocalized(
            tester,
            EatovaHomePage(
              notificationService: notifications,
              debugCache: LocalCache(InMemoryKeyValueStore(), 'blocked'),
            ),
            scaffold: false,
            safeArea: false,
          );
          final store =
              (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
                  .debugStore;
          await store.initNotificationsFromCache();
          await tester.pumpAndSettle();

          await _tap(tester, find.byKey(const ValueKey('today-profile')));
          await _tap(
            tester,
            find.byKey(const ValueKey('profile-open-settings')),
          );
          await _tap(
            tester,
            find.byKey(const ValueKey('settings-reminder-toggle')),
          );
          expect(store.reminderState, ReminderState.blocked);

          await _tap(
            tester,
            find.byKey(
              const ValueKey('settings-reminder-open-system-settings'),
            ),
          );
          await _tap(tester, find.byKey(const ValueKey('settings-open-goals')));
          await _tap(
            tester,
            find.byKey(const ValueKey('settings-open-system-settings')),
          );
          expect(opened, <Object?>['notification', 'notification']);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      },
    );
  });
}
