import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/auth/welcome_screen.dart';

// Widget tests for the boot/welcome screen. The wordmark is PAINTED, so
// tests look for the key `boot-mark` rather than find.text.
//
// The screen is a deliberate exception to the design-refactor rules: as a
// brand moment it uses the forest surface in both modes, never the mode
// background. One test pins that down so nobody moves it to t.bg later.
//
// The focus sweep runs as an endless loop, so `pumpAndSettle` never returns;
// every test pumps in fixed steps via [_tick].

/// iPhone 14 (393x852 logical). The default 800x600 test viewport is larger
/// than any phone and would hide overflow.
void _pinPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Advances the clock in steps; replaces `pumpAndSettle` while the comet
/// loop is in the tree.
Future<void> _tick(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 50),
}) async {
  var elapsed = Duration.zero;
  while (elapsed < total) {
    await tester.pump(step);
    elapsed += step;
  }
}

Future<void> _pumpWelcome(
  WidgetTester tester, {
  required Brightness brightness,
  required Future<void> profileReady,
  bool celebrateLogin = false,
  VoidCallback? onComplete,
  String firstName = 'Mira',
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildEatovaTheme(brightness),
      // The greeting comes from the ARB (`context.l10n`); `de` keeps the
      // German expectations below valid.
      locale: const Locale('de'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          // Per-mode key: forces fresh state when a test pumps both
          // brightnesses, otherwise the first profileReady sticks.
          child: WelcomeScreen(
            key: ValueKey('welcome-$brightness'),
            firstName: firstName,
            profileReady: profileReady,
            celebrateLogin: celebrateLogin,
            onComplete: onComplete ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('rendert in hell UND dunkel ohne Exception', (tester) async {
    _pinPhoneViewport(tester);

    for (final brightness in Brightness.values) {
      await _pumpWelcome(
        tester,
        brightness: brightness,
        profileReady: Completer<void>().future,
      );
      await _tick(tester, const Duration(milliseconds: 1200));

      expect(
        find.byKey(const ValueKey('screen-welcome')),
        findsOneWidget,
        reason: '$brightness: Screen fehlt',
      );
      expect(find.byKey(const ValueKey('boot-mark')), findsOneWidget,
          reason: '$brightness: Marken-Block fehlt');
      expect(tester.takeException(), isNull, reason: '$brightness');
    }
  });

  testWidgets('traegt in beiden Modi die Marken-Flaeche, nicht den Modus-Grund',
      (tester) async {
    _pinPhoneViewport(tester);

    for (final brightness in Brightness.values) {
      final tokens =
          brightness == Brightness.light ? AppTokens.light : AppTokens.dark;
      await _pumpWelcome(
        tester,
        brightness: brightness,
        profileReady: Completer<void>().future,
      );
      await _tick(tester, const Duration(milliseconds: 400));

      final scaffold = tester.widget<Scaffold>(
        find.byKey(const ValueKey('screen-welcome')),
      );
      expect(
        scaffold.backgroundColor,
        tokens.forest,
        reason: '$brightness: der Marken-Moment steht auf forest',
      );
      expect(
        scaffold.backgroundColor,
        isNot(tokens.bg),
        reason: '$brightness: kein Modus-Grund unter dem Marken-Moment',
      );
    }
  });

  testWidgets('zeigt die Begruessung mit dem Vornamen bei celebrateLogin',
      (tester) async {
    _pinPhoneViewport(tester);
    final ready = Completer<void>();

    await _pumpWelcome(
      tester,
      brightness: Brightness.light,
      profileReady: ready.future,
      celebrateLogin: true,
      firstName: 'Mira',
    );
    await _tick(tester, const Duration(milliseconds: 1100));

    expect(find.byKey(const ValueKey('boot-mark')), findsOneWidget);
    expect(find.text('Willkommen, Mira.'), findsNothing);

    ready.complete();
    await tester.pump(); // .then fires
    await _tick(tester, const Duration(milliseconds: 900)); // snap + switcher

    expect(find.text('Willkommen, Mira.'), findsOneWidget);
    expect(find.text('Du bist drin.'), findsOneWidget);
    expect(find.byKey(const ValueKey('boot-mark')), findsOneWidget,
        reason: 'die eingerastete Marke bleibt stehen — der Willkommens-Text '
            'erscheint darunter, er ersetzt sie nicht');

    // Drain hold + exit, otherwise a timer hangs in teardown.
    await _tick(tester, const Duration(milliseconds: 2000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ruft onComplete erst nach aufgeloestem profileReady '
      '(Session-Restore)', (tester) async {
    _pinPhoneViewport(tester);
    var fertig = 0;
    final ready = Completer<void>();

    await _pumpWelcome(
      tester,
      brightness: Brightness.dark,
      profileReady: ready.future,
      onComplete: () => fertig++,
    );
    await _tick(tester, const Duration(milliseconds: 1500));
    expect(fertig, 0, reason: 'ohne Profil-Load darf nichts weiterspringen');

    ready.complete();
    await tester.pump();
    await _tick(tester, const Duration(milliseconds: 800));

    expect(fertig, 1);
  });

  testWidgets('ruft onComplete erst nach der Willkommens-Sequenz '
      '(frischer Login)', (tester) async {
    _pinPhoneViewport(tester);
    var fertig = 0;
    final ready = Completer<void>();

    await _pumpWelcome(
      tester,
      brightness: Brightness.light,
      profileReady: ready.future,
      celebrateLogin: true,
      onComplete: () => fertig++,
    );
    await _tick(tester, const Duration(milliseconds: 1200));
    expect(fertig, 0);

    ready.complete();
    await tester.pump();
    await _tick(tester, const Duration(milliseconds: 1000));
    expect(fertig, 0, reason: 'Einrasten + Halte-Pause laufen noch');

    await _tick(tester, const Duration(milliseconds: 1500));
    expect(fertig, 1);
  });

  testWidgets('bleibt bei doppelter Systemschrift overflow-frei',
      (tester) async {
    _pinPhoneViewport(tester);
    final ready = Completer<void>();

    await _pumpWelcome(
      tester,
      brightness: Brightness.dark,
      profileReady: ready.future,
      celebrateLogin: true,
      textScaler: const TextScaler.linear(2.0),
    );
    await _tick(tester, const Duration(milliseconds: 1100));
    expect(tester.takeException(), isNull, reason: 'Wortmark bei textScale 2.0');

    ready.complete();
    await tester.pump();
    await _tick(tester, const Duration(milliseconds: 900));
    expect(
      tester.takeException(),
      isNull,
      reason: 'Willkommens-Text bei textScale 2.0',
    );

    await _tick(tester, const Duration(milliseconds: 2000));
    expect(tester.takeException(), isNull);
  });
}
