import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/auth/welcome_screen.dart';
import 'package:eatova/src/l10n/l10n.dart';

import '../support/harness.dart';

// Widget tests for the boot/welcome screen. The wordmark is PAINTED, so
// tests look for the key `boot-mark` rather than find.text.
//
// Since the 2026-10-02 launch polish the screen stands on the page ground
// `bg`: in the dark palette that is the native launch colour, so the native
// splash hands over without a colour change. One test pins that down.
//
// The focus hunt runs as an endless loop, so `pumpAndSettle` never returns;
// every test pumps in fixed steps via [_tick].

/// Advances the clock in steps; replaces `pumpAndSettle` while the focus
/// hunt is in the tree.
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

/// The greeting (`welcome-text`) lies whole inside the safe area and the
/// layout's 24 px side margins, below the mark; the mark stays below the top
/// inset. [padding] is logical.
void expectGreetingInSafeArea(
  WidgetTester tester,
  Size screen,
  EdgeInsets padding,
) {
  final text = tester.getRect(find.byKey(const ValueKey('welcome-text')));
  final mark = tester.getRect(find.byKey(const ValueKey('boot-mark')));
  const eps = 0.01;
  expect(text.top, greaterThanOrEqualTo(padding.top - eps),
      reason: 'Begruessung $text unter dem oberen Rand ${padding.top}');
  expect(text.bottom, lessThanOrEqualTo(screen.height - padding.bottom + eps),
      reason: 'Begruessung $text ueber dem unteren Rand ${padding.bottom}');
  expect(text.left, greaterThanOrEqualTo(24 - eps));
  expect(text.right, lessThanOrEqualTo(screen.width - 24 + eps));
  expect(mark.bottom, lessThanOrEqualTo(text.top + eps),
      reason: 'Marke $mark steht ueber der Begruessung $text');
  // Moves up at most to the top inset plus the 24 px margin.
  expect(
    mark.top,
    greaterThanOrEqualTo(
      math.min(padding.top + 24, (screen.height - mark.height) / 2) - eps,
    ),
    reason: 'Marke $mark nie ueber dem oberen Rand',
  );
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
    // The focus hunt and the lock-in are the subject of several timing
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

    // Changed deliberately on 2026-10-02 (was `forest`, a lighter violet
    // grey): the native launch screen is AppTokens.dark.bg, and a cold start
    // flashed from it to forest. The page ground removes that flash; the
    // native side is pinned in test/launch_screen_handoff_test.dart.
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('screen-welcome')),
    );
    expect(
      scaffold.backgroundColor,
      c.t.bg,
      reason: '${c.brightness}: der Start steht auf dem Seitengrund',
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
    expect(find.text(deL10n.onboardingWelcomeTitle('Mira')), findsNothing);

    ready.complete();
    await tester.pump(); // .then fires
    await _tick(tester, const Duration(milliseconds: 900)); // lock-in + greeting fade

    expect(find.text(deL10n.onboardingWelcomeTitle('Mira')), findsOneWidget);
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

  testWidgets('Session-Restore mit fertigem Profil: hoechstens 700 ms bis '
      'onComplete', (tester) async {
    pinPhoneViewport(tester);
    var fertig = 0;
    await _pumpWelcome(
      tester,
      brightness: Brightness.dark,
      profileReady: Future<void>.value(),
      onComplete: () => fertig++,
    );
    await _tick(
      tester,
      const Duration(milliseconds: 700),
      step: const Duration(milliseconds: 20),
    );
    expect(fertig, 1, reason: 'kein langes Intro, wenn die Daten schon da sind');
  });

  testWidgets('Kaltstart: das erste Bild ist der native Startbildschirm', (
    tester,
  ) async {
    // The first Flutter frame must repeat the native launch mark: ring alone,
    // fully opaque, centred on the FULL screen (not the safe area).
    pinPhoneViewport(tester);
    // Asymmetric insets (status bar 47, home bar 34 logical) must not move
    // the mark off the screen centre.
    const insets = FakeViewPadding(top: 141, bottom: 102);
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await _pumpWelcome(
      tester,
      brightness: Brightness.dark,
      profileReady: Completer<void>().future,
    );
    final screen = tester.getRect(find.byKey(const ValueKey('screen-welcome')));
    final mark = tester.getRect(find.byKey(const ValueKey('boot-mark')));
    expect(mark.center.dx, closeTo(screen.center.dx, 0.01));
    expect(mark.center.dy, closeTo(screen.center.dy, 0.01));
    await _tick(tester, const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
  });

  // Layout rule: the greeting hangs below the mark and stays inside the safe
  // area; the pair moves up only as far as needed, never above the top inset.
  for (final (name, size, insets) in const <(String, Size, FakeViewPadding)>[
    ('390x844', Size(390, 844), FakeViewPadding(top: 177, bottom: 102)),
    ('320x640', Size(320, 640), FakeViewPadding(top: 60)),
  ]) {
    testWidgets('haelt die Begruessung bei doppelter Systemschrift im '
        'sicheren Bereich ($name)', (tester) async {
      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = size * 3.0;
      tester.view.padding = insets;
      tester.view.viewPadding = insets;
      addTearDown(tester.view.reset);
      final ready = Completer<void>();

      await _pumpWelcome(
        tester,
        brightness: Brightness.dark,
        profileReady: ready.future,
        celebrateLogin: true,
        firstName: 'Alexandria',
        textScale: 2.0,
      );
      await _tick(tester, const Duration(milliseconds: 1100));
      expect(tester.takeException(), isNull);

      ready.complete();
      await tester.pump();
      await _tick(tester, const Duration(milliseconds: 900));
      expect(
        find.text(deL10n.onboardingWelcomeTitle('Alexandria')),
        findsOneWidget,
      );
      expectGreetingInSafeArea(
        tester,
        size,
        EdgeInsets.only(top: insets.top / 3, bottom: insets.bottom / 3),
      );

      await _tick(tester, const Duration(milliseconds: 2000));
      expect(tester.takeException(), isNull);
    });
  }
}
