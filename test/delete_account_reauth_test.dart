import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/settings/account_change_messages.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';

import 'support/harness.dart';

// Re-authentication before account deletion (security audit 2026-08-14).
// Server-side, `delete_account()` rejects any JWT without a fresh
// 'otp'/'recovery' `amr` entry; this file covers the UI half. The wire half is
// in `test/delete_account_wire_test.dart`.

/// Code request hangs until released — the only way to see the double tap.
class _LangsamerVersand extends InMemoryAuthRepository {
  _LangsamerVersand({super.initialUser});

  final Completer<void> _tor = Completer<void>();

  void freigeben() => _tor.complete();

  @override
  Future<void> sendPasswordReset(String email) async {
    await _tor.future;
    return super.sendPasswordReset(email);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  InMemoryAuthRepository baueRepo() {
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'jonas@eatova.de'),
    );
    addTearDown(repo.dispose);
    return repo;
  }

  /// Pumps the page as a ROUTE, so the test can see deletion close it.
  Future<void> pump(
    WidgetTester tester, {
    AuthRepository? repo,
    Future<void> Function()? onDeleteAccount,
    String? email = 'jonas@eatova.de',
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open-settings'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  email: email,
                  authRepository: repo,
                  onDeleteAccount: onDeleteAccount,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
      brightness: Brightness.light,
      textScale: textScale,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
  }

  Future<void> tippe(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> schreibe(
    WidgetTester tester,
    String schluessel,
    String text,
  ) async {
    await tester.enterText(find.byKey(ValueKey<String>(schluessel)), text);
    await tester.pumpAndSettle();
  }

  /// Up to the code step: sheet open, word typed, code requested.
  Future<void> oeffneCodeSchritt(
    WidgetTester tester,
    InMemoryAuthRepository repo,
    Future<void> Function() onDeleteAccount,
  ) async {
    await pump(tester, repo: repo, onDeleteAccount: onDeleteAccount);
    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    await schreibe(tester, 'settings-delete-confirm-field', 'LÖSCHEN');
    await tippe(tester, find.text('Code anfordern'));
  }

  // --- (a) The typed word alone no longer deletes ---------------------------

  testWidgets('das getippte Wort fordert nur den Code an und loescht nichts',
      (tester) async {
    final repo = baueRepo();
    var geloescht = 0;
    await pump(tester, repo: repo, onDeleteAccount: () async => geloescht++);

    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    expect(find.text('Konto endgültig löschen'), findsNothing);

    await schreibe(tester, 'settings-delete-confirm-field', 'LÖSCHEN');
    expect(find.text('Konto endgültig löschen'), findsNothing);

    await tippe(tester, find.text('Code anfordern'));

    expect(geloescht, 0, reason: 'das Wort allein loescht nichts');
    expect(repo.passwordResets, <String>['jonas@eatova.de']);
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsOneWidget,
    );
    expect(find.text('Konto endgültig löschen'), findsOneWidget);
  });

  testWidgets('ohne das richtige Wort geht nicht einmal die Anforderung raus',
      (tester) async {
    // The word hurdle still catches the slip before any mail goes out.
    final repo = baueRepo();
    var geloescht = 0;
    await pump(tester, repo: repo, onDeleteAccount: () async => geloescht++);

    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();

    expect(repo.passwordResets, isEmpty);
    expect(geloescht, 0);
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsNothing,
    );

    await schreibe(tester, 'settings-delete-confirm-field', 'löschen bitte');
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();

    expect(repo.passwordResets, isEmpty);
    expect(geloescht, 0);
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsNothing,
    );

    // Lower case is enough: the hurdle guards a slip, not the shift key.
    await schreibe(tester, 'settings-delete-confirm-field', 'löschen');
    await tippe(tester, find.text('Code anfordern'));

    expect(repo.passwordResets, <String>['jonas@eatova.de']);
    expect(geloescht, 0);
  });

  // --- (b) Only the confirmed code deletes ----------------------------------

  testWidgets('erst der bestaetigte Code loescht das Konto', (tester) async {
    final repo = baueRepo();
    var geloescht = 0;
    await oeffneCodeSchritt(tester, repo, () async => geloescht++);

    await schreibe(tester, 'settings-delete-code-field', '12345678');
    await tippe(tester, find.text('Konto endgültig löschen'));

    expect(repo.verifiedCodes, <String>['jonas@eatova.de:12345678']);
    expect(geloescht, 1);
    // Close first, then delete, or the AuthGate blames an expired session.
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  testWidgets('ein zu kurzer Code blockt VOR dem Aufruf', (tester) async {
    // A hopeless call only burns the code — GoTrue accepts it once.
    final repo = baueRepo();
    var geloescht = 0;
    await oeffneCodeSchritt(tester, repo, () async => geloescht++);

    await schreibe(tester, 'settings-delete-code-field', '12345');
    await tippe(tester, find.text('Konto endgültig löschen'));

    expect(repo.verifiedCodes, isEmpty);
    expect(geloescht, 0);
    expect(find.text(kAccountCodeInvalid()), findsOneWidget);
  });

  // --- (c) A wrong code does not delete -------------------------------------

  testWidgets('ein falscher Code loescht nicht und meldet verstaendlich',
      (tester) async {
    final repo = baueRepo();
    var geloescht = 0;
    await oeffneCodeSchritt(tester, repo, () async => geloescht++);

    await schreibe(tester, 'settings-delete-code-field', '00000000');
    repo.verifyFails = true;
    await tippe(tester, find.text('Konto endgültig löschen'));

    expect(geloescht, 0);
    expect(find.byKey(const ValueKey('settings-delete-error')), findsOneWidget);
    expect(find.text(kAccountCodeRejected()), findsOneWidget);
    // No raw details on screen.
    expect(find.textContaining('AuthException'), findsNothing);
    expect(find.textContaining('Token has expired'), findsNothing);
    // Sheet stays open with the input intact, so a typo is correctable.
    expect(find.byKey(const ValueKey('delete-account-sheet')), findsOneWidget);
    expect(find.text('00000000'), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
  });

  // --- Latch and visibility -------------------------------------------------

  testWidgets('zwei Taps auf „Code anfordern" fordern nur EINEN Code an',
      (tester) async {
    final repo = _LangsamerVersand(
      initialUser: const EatovaUser(id: 'u1', email: 'jonas@eatova.de'),
    );
    addTearDown(repo.dispose);

    await pump(tester, repo: repo, onDeleteAccount: () async {});
    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    await schreibe(tester, 'settings-delete-confirm-field', 'LÖSCHEN');

    // Two taps with NO frame between: the tree still shows the button armed,
    // so only the handler latch stops the second send.
    await tester.tap(find.text('Code anfordern'));
    await tester.tap(find.text('Code anfordern'));
    await tester.pump();

    expect(find.text('Code wird angefordert…'), findsOneWidget);

    repo.freigeben();
    await tester.pumpAndSettle();

    expect(repo.passwordResets, hasLength(1));
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsOneWidget,
    );
  });

  testWidgets('beide Schritte rendern bei textScale 2.0 ohne Overflow',
      (tester) async {
    // The code step is the tighter one: full mail address plus digit field.
    final repo = baueRepo();
    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };

    try {
      await pump(
        tester,
        repo: repo,
        onDeleteAccount: () async {},
        textScale: 2.0,
      );

      // At 2.0 the delete block sits below the viewport of a lazy ListView.
      final oeffner = find.byKey(const ValueKey('settings-delete-account'));
      await tester.scrollUntilVisible(
        oeffner,
        400,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('screen-settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(oeffner);
      await tester.pumpAndSettle();

      await schreibe(tester, 'settings-delete-confirm-field', 'LÖSCHEN');
      await tippe(tester, find.text('Code anfordern'));

      expect(
        find.byKey(const ValueKey('settings-delete-code-field')),
        findsOneWidget,
      );
      await schreibe(tester, 'settings-delete-code-field', '12345678');
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  testWidgets('ohne AuthRepository fehlt der Loesch-Block ganz',
      (tester) async {
    // Nothing to re-authenticate against, so the action is not offered.
    await pump(tester, onDeleteAccount: () async {});

    expect(find.byKey(const ValueKey('settings-delete-account')), findsNothing);
  });

  testWidgets('ohne bekannte Adresse fehlt der Loesch-Block ebenfalls',
      (tester) async {
    // The code is verified against EXACTLY this address, so without it step
    // two is a dead end. The session beats `_adresse`, hence the bare user.
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1'),
    );
    addTearDown(repo.dispose);

    await pump(tester, repo: repo, onDeleteAccount: () async {}, email: null);

    expect(find.byKey(const ValueKey('settings-delete-account')), findsNothing);
  });
}
