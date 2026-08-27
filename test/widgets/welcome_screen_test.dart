import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/auth/welcome_screen.dart';

import '../support/harness.dart';

// Widget tests for the boot/welcome screen. The wordmark is PAINTED, so
// tests look for the key `boot-mark` rather than find.text.
//
// The screen is a deliberate exception to the design-refactor rules: as a
// brand moment it uses the forest surface in both modes, never the mode
// background. One test pins that down so nobody moves it to t.bg later.
//
// The focus sweep runs as an endless loop, so `pumpAndSettle` never returns;
// every test pumps in fixed steps via [_tick].

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

Widget _welcome({
  required Brightness brightness,
  required Future<void> profileReady,
  bool celebrateLogin = false,
  VoidCallback? onComplete,
  String firstName = 'Mira',
}) =>
    // Per-mode key: forces fresh state when a test pumps both brightnesses,
    // otherwise the first profileReady sticks.
    WelcomeScreen(
      key: ValueKey('welcome-$brightness'),
      firstName: firstName,
      profileReady: profileReady,
      celebrateLogin: celebrateLogin,
      onComplete: onComplete ?? () {},
    );

Future<void> _pumpWelcome(
  WidgetTester tester, {
  required Brightness brightness,
  required Future<void> profileReady,
  bool celebrateLogin = false,
  VoidCallback? onComplete,
  String firstName = 'Mira',
  double textScale = 1.0,
}) async {
  await pumpLocalized(
    tester,
    _welcome(
      brightness: brightness,
      profileReady: profileReady,
      celebrateLogin: celebrateLogin,
      onComplete: onComplete,
      firstName: firstName,
    ),
    brightness: brightness,
    textScale: textScale,
    // The comet sweep and the snap-in are the subject of several timing
    // assertions here, so animations stay ON.
    reducedMotion: false,
    // WelcomeScreen brings its own Scaffold; `screen-welcome` IS that Scaffold.
    scaffold: false,
    safeArea: false,
  );
}

void main() {
  // One case per brightness instead of a loop inside one test: a failure names
  // the mode, and the matrix reports an overflow the old loop never looked at.
  renderMatrix('Der Willkommens-Screen rendert overflow-frei', (tester, c) async {
    pinPhoneViewport(tester);
    await c.pump(
      tester,
      _welcome(
        brightness: c.brightness,
        profileReady: Completer<void>().future,
      ),
      reducedMotion: false,
      scaffold: false,
      safeArea: false,
    );
    await _tick(tester, const Duration(milliseconds: 1200));

    expect(
      find.byKey(const ValueKey('screen-welcome')),
      findsOneWidget,
      reason: '${c.brightness}: Screen fehlt',
    );
    expect(find.byKey(const ValueKey('boot-mark')), findsOneWidget,
        reason: '${c.brightness}: Marken-Block fehlt');
    expect(tester.takeException(), isNull, reason: '${c.brightness}');

    // The screen is a deliberate exception to the design-refactor rules: as a
    // brand moment it stands on `forest` in BOTH modes, never on the mode
    // background. Pinned here so nobody moves it to t.bg later.
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('screen-welcome')),
    );
    expect(
      scaffold.backgroundColor,
      c.t.forest,
      reason: '${c.brightness}: der Marken-Moment steht auf forest',
    );
    expect(
      scaffold.backgroundColor,
      isNot(c.t.bg),
      reason: '${c.brightness}: kein Modus-Grund unter dem Marken-Moment',
    );
  });

  testWidgets('zeigt die Begruessung mit dem Vornamen bei celebrateLogin',
      (tester) async {
    pinPhoneViewport(tester);
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
    pinPhoneViewport(tester);
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
    pinPhoneViewport(tester);
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
    pinPhoneViewport(tester);
    final ready = Completer<void>();

    await _pumpWelcome(
      tester,
      brightness: Brightness.dark,
      profileReady: ready.future,
      celebrateLogin: true,
      textScale: 2.0,
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
