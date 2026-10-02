// Visual evidence for the cold-start animation (design polish run 2026-10-02).
//
// Mounts the real WelcomeScreen at the design's reference geometry and walks
// the clock in fixed steps, writing one shot per step:
//   launch-fast-NNNN     session restore, profile already loaded
//   launch-slow-NNNN     session restore, profile takes 2.4 s (loading loop)
//   launch-login-NNNN    fresh login: loading, lock-in, greeting, exit
//   launch-login-de-NNNN the greeting in German
//   launch-reduced-NN    reduced motion
//   launch-greeting-xl / launch-greeting-light  the held greeting at text
//                        scale 2.0 and in the (dormant) light palette
// NNNN is the elapsed time in ms since the first frame.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/. Without it the suite still pins the timing budget
// (a ready profile reaches the home page within 700 ms), that onComplete
// fires exactly once, and that every state renders without an exception.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/auth/welcome_screen.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

Future<int Function()> _mount(
  WidgetTester tester, {
  required Future<void> ready,
  bool celebrate = false,
  bool reduced = false,
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
}) async {
  pinDesignViewport(tester);
  var completions = 0;
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        WelcomeScreen(
          firstName: 'Mira',
          profileReady: ready,
          celebrateLogin: celebrate,
          onComplete: () => completions++,
        ),
        locale: locale,
        brightness: brightness,
        textScale: textScale,
        reducedMotion: reduced,
        scaffold: false,
        safeArea: false,
      ),
    ),
  );
  return () => completions;
}

/// Shoots every 80 ms (five 16 ms frames) until [until] ms have passed since [start]; returns
/// the new elapsed time.
Future<int> _film(
  WidgetTester tester,
  String name, {
  required int start,
  required int until,
  int Function()? done,
}) async {
  var elapsed = start;
  while (elapsed < until) {
    await captureDesignShot(
      tester,
      '$name-${elapsed.toString().padLeft(4, '0')}',
    );
    // 60 Hz frames between two shots: each controller hand-off starts on the
    // next frame, so coarse 80 ms frames would overstate the timeline.
    var completed = false;
    for (var f = 0; f < 5 && !completed; f++) {
      await tester.pump(const Duration(milliseconds: 16));
      elapsed += 16;
      completed = done != null && done() > 0;
    }
    expect(tester.takeException(), isNull, reason: '$name @ $elapsed ms');
    if (completed) {
      // One more frame of the empty stage the home page takes over from.
      await captureDesignShot(
        tester,
        '$name-${elapsed.toString().padLeft(4, '0')}',
      );
      break;
    }
  }
  return elapsed;
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('session restore with a ready profile stays within 700 ms', (
    tester,
  ) async {
    final completions = await _mount(tester, ready: Future<void>.value());
    expect(find.byKey(const ValueKey('boot-mark')), findsOneWidget);
    final elapsed = await _film(
      tester,
      'launch-fast',
      start: 0,
      until: 1600,
      done: completions,
    );
    expect(completions(), 1);
    expect(
      elapsed,
      lessThanOrEqualTo(700),
      reason: 'a ready profile must not wait for a long intro',
    );
  });

  testWidgets('slow profile: loading loop, then lock-in and exit', (
    tester,
  ) async {
    final ready = Completer<void>();
    final completions = await _mount(tester, ready: ready.future);
    var elapsed = await _film(tester, 'launch-slow', start: 0, until: 2400);
    expect(completions(), 0, reason: 'no profile, no hand-off');
    ready.complete();
    elapsed = await _film(
      tester,
      'launch-slow',
      start: elapsed,
      until: elapsed + 1600,
      done: completions,
    );
    expect(completions(), 1);
    expect(elapsed, lessThanOrEqualTo(2400 + 700));
  });

  for (final locale in const [Locale('en'), Locale('de')]) {
    final name = locale.languageCode == 'en'
        ? 'launch-login'
        : 'launch-login-de';
    testWidgets('fresh login: lock-in, greeting, exit ($name)', (tester) async {
      final ready = Completer<void>();
      final completions = await _mount(
        tester,
        ready: ready.future,
        celebrate: true,
        locale: locale,
      );
      var elapsed = await _film(tester, name, start: 0, until: 640);
      ready.complete();
      elapsed = await _film(
        tester,
        name,
        start: elapsed,
        until: elapsed + 3200,
        done: completions,
      );
      expect(completions(), 1);
    });
  }

  for (final (name, brightness, scale) in const [
    ('launch-greeting-xl', Brightness.dark, 2.0),
    ('launch-greeting-light', Brightness.light, 1.0),
  ]) {
    testWidgets('greeting hold: $name', (tester) async {
      final completions = await _mount(
        tester,
        ready: Future<void>.value(),
        celebrate: true,
        brightness: brightness,
        textScale: scale,
      );
      for (var f = 0; f < 70; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byKey(const ValueKey('welcome-text')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, name);
      for (var f = 0; f < 120; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(completions(), 1);
    });
  }

  testWidgets('reduced motion: static mark, nothing ticking', (tester) async {
    final ready = Completer<void>();
    final completions = await _mount(
      tester,
      ready: ready.future,
      celebrate: true,
      reduced: true,
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await captureDesignShot(tester, 'launch-reduced-00');
    ready.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    // No lock-in or fade, but the greeting holds its 1 s reading pause
    // (since 2026-10-03; before, it stood for one frame). The pause is a
    // timer, not an animation: still nothing ticking.
    expect(find.byKey(const ValueKey('welcome-text')), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(completions(), 0);
    await captureDesignShot(tester, 'launch-reduced-01');
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    expect(completions(), 1);
    expect(tester.takeException(), isNull);
  });
}
