// DESIGN_REFACTOR §7.2 / §5: both account-change flows render in both
// brightnesses and at 200 % text scale without RenderFlex overflow.
// Overflows are deliberately NOT swallowed — they are what is under test, and
// `renderMatrix` asserts on them for every case.
//
// The two nested `for` loops (brightness x scale, per flow) are gone: the
// matrix declares the same four cases per flow from one call.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';

import 'support/harness.dart';

const String _mail = 'jonas.schmidt.mit.langer.adresse@beispiel-mail.de';

Future<InMemoryAuthRepository> _pump(WidgetTester tester, RenderCase c) async {
  pinPhoneViewport(tester);

  final repo = InMemoryAuthRepository(
    initialUser: const EatovaUser(id: 'u1', email: _mail),
  );
  addTearDown(repo.dispose);

  await c.pump(
    tester,
    SettingsScreen(email: _mail, authRepository: repo),
    // SettingsScreen brings its own Scaffold and SafeArea.
    scaffold: false,
    safeArea: false,
    settle: true,
  );
  return repo;
}

/// Scrolls the row into view and taps it; at double text scale it sits
/// below the viewport of the lazy ListView.
Future<void> _oeffne(WidgetTester tester, String schluessel) async {
  final ziel = find.byKey(ValueKey<String>(schluessel));
  await tester.scrollUntilVisible(
    ziel,
    200,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('screen-settings')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(ziel);
  await tester.pumpAndSettle();
}

Future<void> _schreibe(
  WidgetTester tester,
  String schluessel,
  String text,
) async {
  await tester.enterText(find.byKey(ValueKey<String>(schluessel)), text);
  await tester.pumpAndSettle();
}

/// Taps an action inside the sheet. At double text scale the button sits
/// below the fold, so the test must scroll it into view first.
Future<void> _tippeAktion(WidgetTester tester, String beschriftung) async {
  final ziel = find.text(beschriftung);
  await tester.ensureVisible(ziel);
  await tester.pumpAndSettle();
  await tester.tap(ziel);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  renderMatrix(
    'Der Passwort-Flow rendert overflow-frei',
    (tester, c) async {
      await _pump(tester, c);
      await _oeffne(tester, 'settings-change-password');
      expect(
        find.byKey(const ValueKey('password-change-sheet')),
        findsOneWidget,
      );

      await _tippeAktion(tester, 'Code anfordern');

      // The densest state: three fields, each with a field error.
      await _schreibe(tester, 'password-change-code', '12345');
      await _schreibe(tester, 'password-change-new', 'kurz');
      await _schreibe(tester, 'password-change-repeat', 'anders');
      await _tippeAktion(tester, 'Passwort jetzt ändern');

      expect(find.text('Der Code hat 8 Ziffern.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    textScales: const <double>[1.0, 2.0],
  );

  renderMatrix(
    'Der E-Mail-Flow rendert overflow-frei',
    (tester, c) async {
      final repo = await _pump(tester, c);
      await _oeffne(tester, 'settings-change-email');
      expect(
        find.byKey(const ValueKey('email-change-sheet')),
        findsOneWidget,
      );

      await _schreibe(
        tester,
        'email-change-new-address',
        'jonas.neue.sehr.lange.adresse@beispiel-mail.de',
      );
      await _tippeAktion(tester, 'Codes anfordern');

      // Two code fields with a long address each, plus the hint and a
      // rejected code.
      await _schreibe(tester, 'email-change-code-old', '11111111');
      await _schreibe(tester, 'email-change-code-new', '22222222');
      repo.verifyFails = true;
      await _tippeAktion(tester, 'Adresse jetzt ändern');

      expect(
        find.byKey(const ValueKey('email-change-both-hint')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    textScales: const <double>[1.0, 2.0],
  );
}
