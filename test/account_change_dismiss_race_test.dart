import 'dart:async';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

// A dismiss attempt while the final request of an account change is in
// flight opens the "discard?" dialog above the sheet. The sheet's success
// path then popped the TOP route: the dialog closed with `true`, its guard
// read that as "discard" and closed the sheet without a result. The change
// had succeeded on the server, but the settings screen never confirmed it.

/// Holds the final request until the test releases it.
class _HeldChange extends InMemoryAuthRepository {
  _HeldChange()
    : super(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );

  final gate = Completer<void>();
  int emailConfirmations = 0;

  @override
  Future<void> confirmPasswordChange({
    required String currentPassword,
    required String code,
    required String newPassword,
  }) async {
    await gate.future;
    return super.confirmPasswordChange(
      currentPassword: currentPassword,
      code: code,
      newPassword: newPassword,
    );
  }

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {
    if (++emailConfirmations == 2) await gate.future;
    return super.confirmEmailChange(email: email, code: code);
  }
}

Finder get _dialog =>
    find.byKey(const ValueKey<String>('account-change-discard-dialog'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<_HeldChange> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _HeldChange();
    addTearDown(repo.dispose);
    await pumpLocalized(
      tester,
      SettingsScreen(email: 'alt@eatova.de', authRepository: repo),
      scaffold: false,
      safeArea: false,
    );
    await tester.pumpAndSettle();
    return repo;
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> write(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey<String>(key)), text);
    await tester.pumpAndSettle();
  }

  /// Submits, then asks to leave (system back) while the request is pending.
  Future<void> submitThenTryToLeave(WidgetTester tester, String cta) async {
    await tester.ensureVisible(find.text(cta));
    await tester.pumpAndSettle();
    await tester.tap(find.text(cta));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_dialog, findsOneWidget);
  }

  testWidgets('a password change that succeeds behind the discard dialog '
      'still confirms', (tester) async {
    final repo = await open(tester);
    await tap(tester, find.byKey(const ValueKey('settings-change-password')));
    await tap(tester, find.text(deL10n.settingsPasswordChangeRequestCta));
    await write(tester, 'password-change-current', 'CurrentPassword99');
    await write(tester, 'password-change-code', '12345678');
    await write(tester, 'password-change-new', 'NeuesPasswort1');
    await write(tester, 'password-change-repeat', 'NeuesPasswort1');

    await submitThenTryToLeave(tester, deL10n.settingsPasswordChangeSubmitCta);
    repo.gate.complete();
    await tester.pumpAndSettle();

    expect(repo.passwordUpdates, <String>['NeuesPasswort1']);
    expect(_dialog, findsNothing);
    expect(find.byKey(const ValueKey('password-change-sheet')), findsNothing);
    expect(find.text(deL10n.settingsPasswordChangedSnack), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
  });

  testWidgets('an email change that succeeds behind the discard dialog '
      'still confirms', (tester) async {
    final repo = await open(tester);
    await tap(tester, find.byKey(const ValueKey('settings-change-email')));
    await write(tester, 'email-change-new-address', 'neu@eatova.de');
    await tap(tester, find.text(deL10n.settingsEmailChangeRequestCta));
    await write(tester, 'email-change-code-old', '11111111');
    await write(tester, 'email-change-code-new', '22222222');

    await submitThenTryToLeave(tester, deL10n.settingsEmailChangeSubmitCta);
    repo.gate.complete();
    await tester.pumpAndSettle();

    expect(repo.currentUser?.email, 'neu@eatova.de');
    expect(_dialog, findsNothing);
    expect(find.byKey(const ValueKey('email-change-sheet')), findsNothing);
    expect(find.text(deL10n.settingsEmailChangedSnack), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a failed request behind the discard dialog keeps the choice '
      'with the user', (tester) async {
    final repo = await open(tester);
    repo.verifyFails = true;
    await tap(tester, find.byKey(const ValueKey('settings-change-email')));
    await write(tester, 'email-change-new-address', 'neu@eatova.de');
    await tap(tester, find.text(deL10n.settingsEmailChangeRequestCta));
    await write(tester, 'email-change-code-old', '11111111');
    await write(tester, 'email-change-code-new', '22222222');
    // The first confirmation fails at once; hold nothing.
    repo.gate.complete();

    await tester.ensureVisible(find.text(deL10n.settingsEmailChangeSubmitCta));
    await tester.pumpAndSettle();
    await tester.tap(find.text(deL10n.settingsEmailChangeSubmitCta));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(_dialog, findsOneWidget);
    expect(find.byKey(const ValueKey('email-change-sheet')), findsOneWidget);
  });
}
