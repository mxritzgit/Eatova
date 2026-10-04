import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

// The settings code fields drew their caption as a separate eyebrow and had
// only the dot placeholder as hint. A screen reader announced each of them as
// "bullet bullet …" — in the email change, two identical fields where the
// order of the codes matters. Each field now carries its caption as its name,
// like the sign-in code field.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<InMemoryAuthRepository> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
    );
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

  String nameOf(WidgetTester tester, String key) =>
      tester.getSemantics(find.byKey(ValueKey<String>(key))).label;

  testWidgets('both email change code fields are named by their address role', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    await tap(tester, find.byKey(const ValueKey('settings-change-email')));
    await tester.enterText(
      find.byKey(const ValueKey('email-change-new-address')),
      'neu@eatova.de',
    );
    await tap(tester, find.text(deL10n.settingsEmailChangeRequestCta));

    expect(
      nameOf(tester, 'email-change-code-old'),
      contains(deL10n.settingsEmailChangeOldCodeLabel),
    );
    expect(
      nameOf(tester, 'email-change-code-new'),
      contains(deL10n.settingsEmailChangeNewCodeLabel),
    );
    semantics.dispose();
  });

  testWidgets('the password change code field is named', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    await tap(tester, find.byKey(const ValueKey('settings-change-password')));
    await tap(tester, find.text(deL10n.settingsPasswordChangeRequestCta));

    expect(
      nameOf(tester, 'password-change-code'),
      contains(deL10n.settingsPasswordChangeCodeFieldLabel),
    );
    // Let the resend countdown's periodic timer run out.
    await tester.pump(const Duration(seconds: 61));
    semantics.dispose();
  });
}
