import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';

import 'support/harness.dart';

// User finding 2026-08-10: "I cannot find the settings". Both screens hung
// on ONE callback, so the gear labelled settings opened the goals — with
// analyzer and suite green, since both routes worked. So these tests check
// not THAT the screens exist but that the UI gets you there. Second job: five
// rows of the dropped "data & account" block now live only in the settings.

void main() {
  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    // EatovaApp() resolves its language from the device list, which the test
    // harness reports as en-US, while this file asserts on German text.
    tester.platformDispatcher.localesTestValue = const [Locale('de')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();
  }

  Future<void> tippe(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> oeffneProfil(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('today-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);
  }

  Future<void> oeffneEinstellungen(WidgetTester tester) async {
    await oeffneProfil(tester);
    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
  }

  testWidgets('das Zahnrad im Profil fuehrt in die EINSTELLUNGEN',
      (tester) async {
    await boot(tester);
    await oeffneProfil(tester);

    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget,
        reason: 'ein Zahnrad mit der Beschriftung „Einstellungen" muss in '
            'die Einstellungen fuehren');
    expect(find.byKey(const ValueKey('screen-goals')), findsNothing);

    // This row hangs on the shell's LocaleScope and disappears SILENTLY if
    // the scope goes, so arriving is not enough.
    expect(find.byKey(const ValueKey('settings-language')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);

    // Same for the auth layer: password change, address change and account
    // deletion all vanish SILENTLY if the shell drops the repository.
    expect(
      find.byKey(const ValueKey('settings-change-password')),
      findsOneWidget,
      reason: 'ohne durchgereichtes AuthRepository entfaellt auch der '
          'Loesch-Block ersatzlos',
    );
  });

  testWidgets('die Bearbeiten-Knoepfe im Profil fuehren auf „Profil & Ziele"',
      (tester) async {
    // Since `profile-action-edit` is gone the path hangs on the edit buttons
    // of the plan and goal cards, so BOTH are checked.
    await boot(tester);

    for (final key in const <String>[
      'profile-goalplan-edit',
      'profile-edit-goals',
    ]) {
      await oeffneProfil(tester);
      await tippe(tester, find.byKey(ValueKey(key)));

      expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget,
          reason: key);
      expect(find.byKey(const ValueKey('screen-settings')), findsNothing);

      // Back to today so the next pass starts clean.
      await tippe(tester, find.byKey(const ValueKey('settings-close')));
      await tippe(tester, find.byKey(const ValueKey('profile-close')));
    }
  });

  testWidgets('auch der Kopf des Food-Tabs fuehrt in die Einstellungen',
      (tester) async {
    await boot(tester);
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
  });

  testWidgets('von den Einstellungen kommt man weiter zu den Zielen',
      (tester) async {
    await boot(tester);
    await oeffneEinstellungen(tester);

    await tippe(tester, find.byKey(const ValueKey('settings-open-goals')));

    expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
  });

  testWidgets('„Über Eatova" ist aus der laufenden App heraus erreichbar',
      (tester) async {
    // The only profile row without a settings counterpart, so it MOVED with
    // its sheet rather than being deleted: the sheet carries the ODbL
    // attribution and the GDPR Art. 13 privacy row.
    await boot(tester);
    await oeffneEinstellungen(tester);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-about')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('screen-settings')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Über Eatova'), findsOneWidget);

    await tippe(tester, find.byKey(const ValueKey('settings-about')));

    expect(find.text('Quellen'), findsOneWidget);
    expect(find.textContaining('OpenFoodFacts'), findsOneWidget,
        reason: 'die Quellennennung ist lizenzrechtlich vorgeschrieben (ODbL)');
    expect(find.byKey(const ValueKey('profile-privacy-link')), findsOneWidget,
        reason: 'Key bleibt Key — er ist mit dem Sheet mitgewandert');
  });

  testWidgets('alle Wege des entfallenen Profil-Blocks stehen im Screen',
      (tester) async {
    // THE guard: export and account deletion hang on the sync, absent in
    // test/preview, so only the FULLY wired screen shows them. The daily-reset
    // action is gone on purpose, asserted in `goals_screen_render_test`.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'jonas@example.com'),
    );
    addTearDown(repo.dispose);

    await pumpLocalized(
      tester,
      SettingsScreen(
        email: 'jonas@example.com',
        authRepository: repo,
        onOpenGoals: () {},
        onSignOut: () async {},
        onDeleteAccount: () async {},
        onExportData: () async => '{}',
      ),
      brightness: Brightness.light,
      scaffold: false,
      safeArea: false,
    );
    await tester.pumpAndSettle();

    final scroller = find.descendant(
      of: find.byKey(const ValueKey('screen-settings')),
      matching: find.byType(Scrollable),
    );

    for (final zeile in const <({String key, String text})>[
      // formerly profile-action-edit
      (key: 'settings-open-goals', text: 'Profil & Ziele'),
      // formerly profile-action-export
      (key: 'settings-export', text: 'Daten exportieren'),
      // formerly profile-action-about
      (key: 'settings-about', text: 'Über Eatova'),
      // formerly profile-action-logout
      (key: 'settings-sign-out', text: 'Ausloggen'),
      // formerly profile-action-delete
      (key: 'settings-delete-account', text: 'Konto löschen'),
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(zeile.key)),
        300,
        scrollable: scroller,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(zeile.key)), findsOneWidget,
          reason: zeile.key);
      expect(find.text(zeile.text), findsOneWidget, reason: zeile.text);
    }
  });
}
