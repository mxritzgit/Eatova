// DESIGN_REFACTOR §7.2 / §5: every screen renders in both brightnesses and at
// 200 % system font without RenderFlex overflow.
//
// This file covers the settings screen. Its weak spots: the three-segment
// pill next to the appearance row, the icon tile row with a long mail
// address, and the delete block with its explainer box.
//
// Unlike the behaviour tests, overflows are NOT swallowed here — they are the
// thing under test. The four hand-written smokes (hell / dunkel / 2.0 hell /
// 2.0 dunkel) are one `renderMatrix` now, which also covers `en`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

import 'support/harness.dart';

const String _mail = 'jonas.schmidt.mit.langer.adresse@beispiel-mail.de';

/// Three rows hang off the auth layer (password, address, delete); without
/// them this is half a page instead of the densest case.
InMemoryAuthRepository _auth(String? email) {
  final repo = InMemoryAuthRepository(
    initialUser: EatovaUser(id: 'u1', email: email),
  );
  addTearDown(repo.dispose);
  return repo;
}

ThemeModeController _themeController() {
  final controller = ThemeModeController();
  addTearDown(controller.dispose);
  return controller;
}

/// All callbacks set: the full screen and thus the densest case; the thinned
/// variants cannot overflow more than this one.
Widget _seite({
  String? email = _mail,
  bool mitScope = true,
  bool mitAuth = true,
}) {
  final Widget page = SettingsScreen(
    email: email,
    authRepository: mitAuth ? _auth(email) : null,
    onOpenGoals: () {},
    onSignOut: () async {},
    onDeleteAccount: () async {},
    onExportData: () async => '{}',
  );
  // [ThemeModeScope] sits inside `home`, which is enough: only the page
  // itself reads it (settings_screen.dart), no sheet does.
  return mitScope
      ? ThemeModeScope(controller: _themeController(), child: page)
      : page;
}

/// Mounts the page and pins the two things every case shares.
Future<void> _pump(
  WidgetTester tester, {
  required Brightness brightness,
  Locale locale = const Locale('de'),
  double textScale = 1.0,
  String? email = _mail,
  bool mitScope = true,
  bool mitAuth = true,
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    _seite(email: email, mitScope: mitScope, mitAuth: mitAuth),
    brightness: brightness,
    locale: locale,
    textScale: textScale,
    // SettingsScreen brings its own Scaffold and SafeArea.
    scaffold: false,
    safeArea: false,
    settle: true,
  );
  expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
  expect(tester.takeException(), isNull);
}

/// The page is a lazy ListView; rows below the fold are not in the tree until
/// scrolled to, and building them is exactly when an overflow would trip.
Future<void> _scrollTo(WidgetTester tester, Key key, double schritt) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    schritt,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('screen-settings')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  renderMatrix(
    'Einstellungen rendern overflow-frei',
    (tester, c) async {
      await _pump(tester, brightness: c.brightness, locale: c.locale,
          textScale: c.textScale);
    },
    locales: const <Locale>[Locale('de'), Locale('en')],
    textScales: const <double>[1.0, 2.0],
  );

  testWidgets('die Erscheinungsbild-Zeile traegt die Pille auch bei 2.0',
      (tester) async {
    // The page's densest row: title and subtitle left, three-segment pill
    // right. At 2.0 the pill must wrap to a second line, not burst the row.
    final overflows = await collectOverflows(() async {
      await _pump(tester, brightness: Brightness.light, textScale: 2.0);

      // The row sits below the viewport (the account group now has three
      // rows), so without scrolling the pill is not in the tree at all.
      await _scrollTo(tester, const ValueKey('settings-theme-mode'), 300);
    });

    expect(overflows, isEmpty, reason: describeOverflows(overflows));
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-theme-mode-dark')),
      findsOneWidget,
    );
  });

  testWidgets('die ausgeduennte Seite rendert ebenfalls sauber',
      (tester) async {
    // Without mail address, auth layer and ThemeModeScope half the page is
    // gone; an empty [SettingsGroup] would be the weak spot here.
    final overflows = await collectOverflows(() async {
      await _pump(
        tester,
        brightness: Brightness.dark,
        textScale: 2.0,
        email: null,
        mitScope: false,
        mitAuth: false,
      );
    });

    expect(overflows, isEmpty, reason: describeOverflows(overflows));
    expect(find.text('KONTO'), findsNothing);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsNothing);
  });

  testWidgets('das Loesch-Sheet rendert bei 2.0 ohne Overflow', (tester) async {
    // Its own route above the page, unreachable by the matrix above. Title,
    // three lines of explainer, a field and a 52-px button are the app's
    // tightest spot at double font size.
    //
    // The sheet has TWO steps and the second is tighter: its subtitle carries
    // the full mail address, then a labelled digit field and the button. The
    // whole path is checked, ending with the delete button still reachable
    // rather than clipped off the bottom.
    final overflows = await collectOverflows(() async {
      await _pump(tester, brightness: Brightness.dark, textScale: 2.0);

      // At double font size the delete block sits far below the viewport.
      await _scrollTo(tester, const ValueKey('settings-delete-account'), 400);
      await tester.tap(find.byKey(const ValueKey('settings-delete-account')));
      await tester.pumpAndSettle();

      // Step 1: the typed word. The button still only requests the code.
      expect(find.text('Code anfordern'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('settings-delete-confirm-field')),
        'LÖSCHEN',
      );
      await tester.pumpAndSettle();

      // Step 2: the code. Subtitle with full mail address, labelled digit
      // field, 52-px button.
      await tester.tap(find.text('Code anfordern'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-delete-code-field')),
        findsOneWidget,
      );
      expect(find.text('Konto endgültig löschen'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('settings-delete-code-field')),
        '12345678',
      );
      await tester.pumpAndSettle();

      // The core promise: the delete button stays reachable and fully on
      // screen at double font size. An overflow counter alone would miss
      // this — a button hanging out the bottom raises no RenderFlex error.
      final knopf = find.text('Konto endgültig löschen');
      await tester.ensureVisible(knopf);
      await tester.pumpAndSettle();
      final rect = tester.getRect(knopf);
      final bild = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(rect.left, greaterThanOrEqualTo(0.0), reason: 'links beschnitten');
      expect(rect.right, lessThanOrEqualTo(bild.width),
          reason: 'rechts beschnitten');
      expect(rect.top, greaterThanOrEqualTo(0.0), reason: 'oben beschnitten');
      expect(rect.bottom, lessThanOrEqualTo(bild.height),
          reason: 'unten beschnitten');
    });

    expect(overflows, isEmpty, reason: describeOverflows(overflows));
  });

  testWidgets('das „Über Eatova"-Sheet rendert bei 2.0 ohne Overflow',
      (tester) async {
    // Not cosmetic: the block of description, version, build, sources and
    // privacy row was once 251 px too tall at double font size — and the
    // bottom row is the one that must never be clipped.
    final overflows = await collectOverflows(() async {
      await _pump(tester, brightness: Brightness.dark, textScale: 2.0);

      await _scrollTo(tester, const ValueKey('settings-about'), 400);
      await tester.tap(find.byKey(const ValueKey('settings-about')));
      await tester.pumpAndSettle();

      // The sheet's two mandatory rows: the ODbL attribution for the
      // OpenFoodFacts data and the GDPR Art. 13 privacy link.
      expect(find.text('Quellen'), findsOneWidget);
      expect(
        find.textContaining('OpenFoodFacts'),
        findsOneWidget,
        reason: 'die Quellennennung ist lizenzrechtlich vorgeschrieben',
      );
      expect(
        find.byKey(const ValueKey('profile-privacy-link')),
        findsOneWidget,
        reason: 'Key bleibt Key — er ist mit dem Sheet mitgewandert',
      );
    });

    expect(overflows, isEmpty, reason: describeOverflows(overflows));
  });

  testWidgets('der Seitenfuss der Einstellungen steht ohne vorheriges '
      'Scrollen im Baum', (tester) async {
    // The page is a lazy ListView; this pins that the legal links are still
    // found while the viewport carries them, or the behaviour tests would
    // miss before anyone scrolls.
    await _pump(tester, brightness: Brightness.light);

    expect(find.byKey(const ValueKey('settings-privacy-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-terms-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-imprint-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-about')), findsOneWidget);

    // The danger zone slipped one row down and sits just below the edge when
    // fully wired, so this asserts reachability rather than visibility.
    await _scrollTo(tester, const ValueKey('settings-sign-out'), 300);
    expect(find.byKey(const ValueKey('settings-sign-out')), findsOneWidget);
  });
}
