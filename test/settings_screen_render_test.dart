import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// DESIGN_REFACTOR §7.2 / §5: every screen renders in both brightnesses and at
// 200 % system font without RenderFlex overflow.
//
// This file covers the settings screen. Its weak spots: the three-segment
// pill next to the appearance row, the icon tile row with a long mail
// address, and the delete block with its explainer box.
//
// Unlike the behaviour tests, overflows are NOT swallowed here — they are the
// thing under test.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpOhneOverflow(
    WidgetTester tester,
    String fall, {
    required Brightness brightness,
    double textScale = 1.0,
    String? email = 'jonas.schmidt.mit.langer.adresse@beispiel-mail.de',
    bool mitScope = true,
    bool mitAuth = true,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };

    final controller = ThemeModeController();
    addTearDown(controller.dispose);

    // Three rows hang off the auth layer (password, address, delete); without
    // them this is half a page instead of the densest case.
    final repo = mitAuth
        ? InMemoryAuthRepository(
            initialUser: EatovaUser(id: 'u1', email: email),
          )
        : null;
    if (repo != null) addTearDown(repo.dispose);

    // All callbacks set: the full screen and thus the densest case; the
    // thinned variants cannot overflow more than this one.
    final app = MaterialApp(
      theme: buildEatovaTheme(brightness),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: SettingsScreen(
        email: email,
        authRepository: repo,
        onOpenGoals: () {},
        onSignOut: () async {},
        onDeleteAccount: () async {},
        onExportData: () async => '{}',
      ),
    );

    try {
      await tester.pumpWidget(
        mitScope ? ThemeModeScope(controller: controller, child: app) : app,
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = prior;
    }

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      overflows,
      isEmpty,
      reason: '$fall overflowt:\n${overflows.join('\n')}',
    );
  }

  testWidgets('rendert im Hellmodus', (tester) async {
    await pumpOhneOverflow(tester, 'hell', brightness: Brightness.light);
  });

  testWidgets('rendert im Dunkelmodus', (tester) async {
    await pumpOhneOverflow(tester, 'dunkel', brightness: Brightness.dark);
  });

  testWidgets('rendert bei textScale 2.0 (hell)', (tester) async {
    await pumpOhneOverflow(
      tester,
      'hell @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
    );
  });

  testWidgets('rendert bei textScale 2.0 (dunkel)', (tester) async {
    await pumpOhneOverflow(
      tester,
      'dunkel @2.0',
      brightness: Brightness.dark,
      textScale: 2.0,
    );
  });

  testWidgets('die Erscheinungsbild-Zeile traegt die Pille auch bei 2.0',
      (tester) async {
    // The page's densest row: title and subtitle left, three-segment pill
    // right. At 2.0 the pill must wrap to a second line, not burst the row.
    await pumpOhneOverflow(
      tester,
      'Erscheinungsbild @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
    );

    // The row sits below the viewport (the account group now has three rows),
    // and the page is a lazy ListView, so without scrolling the pill is not
    // in the tree at all. The overflow guard runs along, since that is
    // exactly when building the row would trip it.
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
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-theme-mode')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('screen-settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
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
    await pumpOhneOverflow(
      tester,
      'ohne Konto @2.0',
      brightness: Brightness.dark,
      textScale: 2.0,
      email: null,
      mitScope: false,
      mitAuth: false,
    );

    expect(find.text('KONTO'), findsNothing);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsNothing);
  });

  testWidgets('das Loesch-Sheet rendert bei 2.0 ohne Overflow', (tester) async {
    // Its own route above the page, unreachable by the cases above. Title,
    // three lines of explainer, a field and a 52-px button are the app's
    // tightest spot at double font size.
    //
    // The sheet has TWO steps and the second is tighter: its subtitle carries
    // the full mail address, then a labelled digit field and the button. The
    // whole path is checked, ending with the delete button still reachable
    // rather than clipped off the bottom.
    await pumpOhneOverflow(
      tester,
      'Loesch-Sheet Grundzustand',
      brightness: Brightness.dark,
      textScale: 2.0,
    );

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
      // At double font size the delete block sits far below the viewport of
      // a lazy ListView, so without scrolling it is not in the tree.
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
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  testWidgets('das „Über Eatova"-Sheet rendert bei 2.0 ohne Overflow',
      (tester) async {
    // Not cosmetic: the block of description, version, build, sources and
    // privacy row was once 251 px too tall at double font size — and the
    // bottom row is the one that must never be clipped.
    await pumpOhneOverflow(
      tester,
      'Über-Sheet Grundzustand',
      brightness: Brightness.dark,
      textScale: 2.0,
    );

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
      final oeffner = find.byKey(const ValueKey('settings-about'));
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
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  testWidgets('der Seitenfuss steht ohne vorheriges Scrollen im Baum',
      (tester) async {
    // The page is a lazy ListView; this pins that the legal links are still
    // found while the viewport carries them, or the behaviour tests would
    // miss before anyone scrolls.
    await pumpOhneOverflow(tester, 'Fuss', brightness: Brightness.light);

    expect(find.byKey(const ValueKey('settings-privacy-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-terms-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-imprint-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-about')), findsOneWidget);

    // The danger zone slipped one row down and sits just below the edge when
    // fully wired, so this asserts reachability rather than visibility.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-sign-out')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('screen-settings')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-sign-out')), findsOneWidget);
  });
}
