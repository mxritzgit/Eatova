import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart' show ReminderState;
import 'package:eatova/src/models/user_profile.dart';
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
        'Aktiv. Jeden Abend um 20 Uhr, wenn du noch nichts geloggt hast.',
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

  testWidgets('blocked: der Schalter laesst sich nicht erneut umlegen',
      (tester) async {
    await openSettings(tester, reminderState: ReminderState.blocked);

    // Android 13+ shows no dialog after two denials — the switch would snap
    // straight back.
    expect(reminderSwitch(tester).enabled, isFalse);

    // And it really does not react: a tap must not flip the state.
    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-notifications')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-notifications')));
    await tester.pumpAndSettle();
    expect(reminderSwitch(tester).value, isFalse);
  });

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
        'Aktiv. Jeden Abend um 20 Uhr, wenn du noch nichts geloggt hast.',
      ),
      findsOneWidget,
    );
  });
}
