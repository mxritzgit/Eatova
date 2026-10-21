import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';

import 'support/harness.dart';

// The settings page — account, preferences, data, danger zone. Profile &
// goals is its own page; only the row leading there lives here.
//
// This file tests BEHAVIOUR, not geometry:
//
//   1. Every row calls its callback, or it is decoration.
//   2. A MISSING callback hides its row. Deliberately not "disabled": a grey
//      entry claims the path exists and is merely unavailable.
//
// The appearance switch (the only setting this screen writes itself) is
// pinned in `test/settings_theme_mode_test.dart`.
/// Counts route pops, proving the order "close first, then call the
/// callback". The widget tree cannot show it: the popped route is still in it
/// during its fade-out.
class _PopSpion extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
    super.didPop(route, previousRoute);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Pumps the page as a ROUTE above a starter page — the only way to check
  /// that sign-out and delete close it first.
  Future<void> pump(
    WidgetTester tester, {
    String? email = 'jonas@example.com',
    /// The auth layer: password and address change plus the
    /// re-authentication before account deletion. Without it the delete block
    /// disappears entirely.
    AuthRepository? authRepository,
    VoidCallback? onOpenGoals,
    Future<void> Function()? onSignOut,
    int pendingSyncCount = 0,
    int localRecipePhotos = 0,
    Future<void> Function()? onDeleteAccount,
    Future<String> Function()? onExportData,
    Brightness brightness = Brightness.light,
    NavigatorObserver? observer,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    // `localizedApp` instead of `pumpLocalized`: the page is pushed as a route
    // above a starter page, observed by [observer].
    final app = localizedApp(
      Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open-settings'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  email: email,
                  authRepository: authRepository,
                  onOpenGoals: onOpenGoals,
                  onSignOut: onSignOut,
                  pendingSyncCount: pendingSyncCount,
                  localRecipePhotoCount: () => localRecipePhotos,
                  onDeleteAccount: onDeleteAccount == null ? null : (deleteRemote, _) async { await deleteRemote(); await onDeleteAccount(); },
                  onExportData: onExportData,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
      brightness: brightness,
      navigatorObserver: observer,
    );

    await tester.pumpWidget(app);
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
  }

  Future<void> tippe(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Peer for the rows hanging off the auth layer — the same one used in
  /// `test/account_change_flows_test.dart`.
  InMemoryAuthRepository baueRepo() {
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'jonas@example.com'),
    );
    addTearDown(repo.dispose);
    return repo;
  }

  // --- Skeleton -------------------------------------------------------------

  testWidgets('die Seite traegt ihren Schluessel und ihren Titel',
      (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(find.text('Einstellungen'), findsOneWidget);

    // No discard guard: this screen holds no unsaved draft, every row takes
    // effect at once, so back leaves immediately.
    await tippe(tester, find.byKey(const ValueKey('settings-back')));
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  // --- ACCOUNT --------------------------------------------------------------

  testWidgets('die Mailadresse steht in der Kontozeile', (tester) async {
    await pump(tester, email: 'jonas@example.com');

    expect(find.byKey(const ValueKey('settings-email')), findsOneWidget);
    expect(find.text('jonas@example.com'), findsOneWidget);
  });

  testWidgets('ohne Mailadresse entfaellt die KONTO-Gruppe ganz',
      (tester) async {
    await pump(tester, email: null);

    expect(find.byKey(const ValueKey('settings-email')), findsNothing);
    expect(find.text('Konto'), findsNothing);
  });

  // --- PREFERENCES ----------------------------------------------------------

  testWidgets('„Profil & Ziele" ruft onOpenGoals', (tester) async {
    var aufgerufen = 0;
    await pump(tester, onOpenGoals: () => aufgerufen++);

    expect(find.text('Profil & Ziele'), findsOneWidget);
    await tippe(tester, find.byKey(const ValueKey('settings-open-goals')));

    expect(aufgerufen, 1);
  });

  // --- DATA & PRIVACY -------------------------------------------------------

  testWidgets('„Daten exportieren" oeffnet die gegliederte Auskunft',
      (tester) async {
    var aufgerufen = 0;
    await pump(
      tester,
      onExportData: () async {
        aufgerufen++;
        return '{ "logged_meals": [] }';
      },
    );

    await tippe(tester, find.byKey(const ValueKey('settings-export')));

    expect(aufgerufen, 1);
    expect(find.text('Datenauskunft'), findsOneWidget);
    // Sign-out deletes the device-only recipe photos; the export says it
    // does not hold them.
    expect(
      find.byKey(const ValueKey('export-recipe-photos-hint')),
      findsOneWidget,
    );
    expect(find.byType(SelectableText), findsNothing);
    final section = find.byKey(const ValueKey('export-expand-logged_meals'));
    await tester.scrollUntilVisible(section, 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Mahlzeiten'), findsOneWidget);
    // Same copy button as in the profile; there is no second export sheet.
    expect(find.byKey(const ValueKey('profile-export-copy')), findsOneWidget);
  });

  testWidgets('die drei Rechtsseiten stehen als Zeilen mit ihren Schluesseln',
      (tester) async {
    // GDPR Art. 13 / § 5 DDG: reachable after login, not only on the auth
    // screen. The keys are still the ones from [SettingsLegalLinks]. Found
    // before any scrolling: the page builds every row up front, which the
    // behaviour tests rely on.
    await pump(tester);

    expect(find.byKey(const ValueKey('settings-privacy-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-terms-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-imprint-link')), findsOneWidget);
    expect(find.text('Datenschutz'), findsOneWidget);
    expect(find.text('Impressum'), findsOneWidget);
  });

  // --- DANGER ZONE ----------------------------------------------------------

  testWidgets(
      '„Abmelden" fragt nach, nennt Offenes und Rezeptfotos, schliesst erst '
      'die Seite und ruft dann den Callback', (tester) async {
    // The order is deliberate: `AuthGate` claims the session expired if
    // routes are still open during the auth change, which would be wrong
    // after an intentional logout. Measured on the navigator history, not the
    // tree — the route is popped but still fading out.
    final spion = _PopSpion();
    final l10n = deL10n;
    var abgemeldet = 0;
    var popsBeimCallback = -1;
    await pump(
      tester,
      observer: spion,
      pendingSyncCount: 3,
      localRecipePhotos: 2,
      onSignOut: () async {
        abgemeldet++;
        popsBeimCallback = spion.pops;
      },
    );

    // Sign-out deletes the device-only recipe photos; the dialog says so,
    // and that unsent changes wait for the next sign-in.
    await tippe(tester, find.byKey(const ValueKey('settings-sign-out')));
    expect(find.textContaining(l10n.settingsSignOutPending(3)), findsOneWidget);
    expect(find.textContaining(l10n.settingsSignOutPhotos(2)), findsOneWidget);
    await tippe(tester, find.byKey(const ValueKey('settings-sign-out-cancel')));
    expect(abgemeldet, 0, reason: 'Abbrechen meldet nicht ab');
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);

    await tippe(tester, find.byKey(const ValueKey('settings-sign-out')));
    final vorher = spion.pops;
    await tippe(tester, find.byKey(const ValueKey('settings-sign-out-confirm')));

    expect(abgemeldet, 1);
    expect(
      popsBeimCallback,
      vorher + 2,
      reason: 'erst Dialog und Seite schliessen, dann abmelden',
    );
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  testWidgets('ein fehlender Callback blendet seine Zeile aus', (tester) async {
    await pump(tester);

    for (final key in const <String>[
      'settings-open-goals',
      'settings-export',
      'settings-sign-out',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
  });

  testWidgets('ohne beide Gefahren-Callbacks fehlt die ganze Gruppe',
      (tester) async {
    // WITH the auth layer, so this measures the missing callbacks and not
    // just the missing repository.
    await pump(tester, authRepository: baueRepo());

    expect(find.text('Konto verwalten'), findsNothing);
    expect(find.byKey(const ValueKey('settings-delete-account')), findsNothing);
  });

  testWidgets('„Konto löschen" verlangt das getippte Wort und danach den Code',
      (tester) async {
    // TWO hurdles, and neither deletes on its own. The typed word catches the
    // accident before any mail goes out; the code catches a stranger's finger
    // on an unlocked device.
    //
    // The second step's edge cases live in
    // `test/delete_account_reauth_test.dart`.
    final repo = baueRepo();
    var geloescht = 0;
    await pump(
      tester,
      authRepository: repo,
      onDeleteAccount: () async => geloescht++,
    );

    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    // Step 1 has no delete button at all: it only requests the code.
    expect(find.text('Code anfordern'), findsOneWidget);
    expect(find.text('Konto endgültig löschen'), findsNothing);

    // Without the word the button is not armed — not even a mail goes out.
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();
    expect(repo.accountDeletionCodes, isEmpty);
    expect(geloescht, 0);

    // A WRONG word does not arm it either.
    await tester.enterText(
      find.byKey(const ValueKey('settings-delete-confirm-field')),
      'löschen bitte',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();
    expect(repo.accountDeletionCodes, isEmpty);
    expect(geloescht, 0);

    // With the word the code goes out (lowercase is enough: the hurdle
    // guards against accidents, not against the shift key) — but nothing is
    // deleted yet.
    await tester.enterText(
      find.byKey(const ValueKey('settings-delete-confirm-field')),
      'löschen',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();

    expect(repo.accountDeletionCodes, <String>['jonas@example.com']);
    expect(geloescht, 0, reason: 'das getippte Wort allein loescht nichts');
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsOneWidget,
    );

    // The delete button itself deletes nothing while no code is entered.
    await tester.tap(find.text('Konto endgültig löschen'));
    await tester.pumpAndSettle();
    expect(repo.verifiedCodes, isEmpty);
    expect(geloescht, 0);
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);

    // Only the server-confirmed code goes through: page closes, then the
    // callback runs.
    await tester.enterText(
      find.byKey(const ValueKey('settings-delete-code-field')),
      '12345678',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konto endgültig löschen'));
    await tester.pumpAndSettle();

    expect(repo.verifiedCodes, <String>['jonas@example.com:12345678']);
    expect(geloescht, 1);
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  testWidgets('ohne onDeleteAccount fehlt der Loesch-Block', (tester) async {
    // With repository again: the row is missing because of the missing
    // callback, not the missing auth layer.
    await pump(
      tester,
      authRepository: baueRepo(),
      onSignOut: () async {},
    );

    expect(find.text('Konto verwalten'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-sign-out')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-delete-account')), findsNothing);
    expect(find.text('Konto löschen'), findsNothing);
  });
}
