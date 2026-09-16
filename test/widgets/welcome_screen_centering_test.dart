import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/auth/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Future<void> _advance(WidgetTester tester, int milliseconds) async {
  for (var elapsed = 0; elapsed < milliseconds; elapsed += 20) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void _expectCenteredLayout(WidgetTester tester) {
  final screen = tester.getRect(find.byKey(const ValueKey('screen-welcome')));
  final mark = tester.getRect(find.byKey(const ValueKey('boot-mark')));
  expect(mark.center.dx, closeTo(screen.center.dx, 0.01));
  expect(mark.left, greaterThanOrEqualTo(screen.left));
  expect(mark.right, lessThanOrEqualTo(screen.right));
}

// Inspect the actual lettering/ring pixels, not only their enclosing widget.
Future<void> _expectCenteredInk(
  WidgetTester tester,
  GlobalKey capture,
  Color background,
  String name,
) async {
  final boundary =
      capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final mark = tester.getRect(find.byKey(const ValueKey('boot-mark')));
  final origin = boundary.localToGlobal(Offset.zero);
  final band = mark.shift(-origin);
  final ink = (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final rgba = bytes!.buffer.asUint8List();
      final backgroundArgb = background.toARGB32();
      final red = (backgroundArgb >> 16) & 0xff;
      final green = (backgroundArgb >> 8) & 0xff;
      final blue = backgroundArgb & 0xff;
      var left = image.width;
      var right = -1;
      for (
        var y = math.max(0, band.top.ceil());
        y < math.min(image.height, band.bottom.floor());
        y++
      ) {
        for (var x = 0; x < image.width; x++) {
          final i = (y * image.width + x) * 4;
          final difference =
              (rgba[i] - red).abs() +
              (rgba[i + 1] - green).abs() +
              (rgba[i + 2] - blue).abs();
          if (difference > 60) {
            left = math.min(left, x);
            right = math.max(right, x);
          }
        }
      }
      const directory = String.fromEnvironment('WELCOME_PREVIEW_DIR');
      if (directory.isNotEmpty) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$directory/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
      }
      return (left: left, right: right, width: image.width);
    } finally {
      image.dispose();
    }
  }))!;
  expect(ink.right, greaterThan(ink.left), reason: '$name: mark is visible');
  expect(
    (ink.left + ink.right + 1) / 2,
    closeTo(ink.width / 2, 2),
    reason: '$name: painted mark is centred on the screen',
  );
}

void main() {
  setUpAll(() async {
    for (final (family, file) in [
      ('BricolageGrotesque', 'BricolageGrotesque-Bold.ttf'),
      ('Archivo', 'Archivo-Regular.ttf'),
    ]) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$file'))).load();
    }
  });

  const cases = [
    (name: 'phone', size: Size(390, 844), scale: 1.0, rtl: false),
    (name: 'compact', size: Size(320, 640), scale: 2.0, rtl: false),
    (name: 'landscape', size: Size(568, 320), scale: 2.0, rtl: true),
    (name: 'tablet', size: Size(1024, 768), scale: 1.0, rtl: false),
  ];
  for (final brightness in Brightness.values) {
    final tokens = brightness == Brightness.light
        ? AppTokens.light
        : AppTokens.dark;
    for (final c in cases) {
      testWidgets('welcome stays centred ${brightness.name} ${c.name}', (
        tester,
      ) async {
        final capture = GlobalKey();
        final ready = Completer<void>();
        var completions = 0;
        await pumpLocalized(
          tester,
          RepaintBoundary(
            key: capture,
            child: Directionality(
              textDirection: c.rtl ? TextDirection.rtl : TextDirection.ltr,
              child: WelcomeScreen(
                firstName: 'Alexandria',
                profileReady: ready.future,
                celebrateLogin: true,
                onComplete: () => completions++,
              ),
            ),
          ),
          brightness: brightness,
          surfaceSize: c.size,
          textScale: c.scale,
          reducedMotion: false,
          scaffold: false,
          safeArea: false,
        );
        await _advance(tester, 300);
        _expectCenteredLayout(tester);
        await _advance(tester, 900);
        _expectCenteredLayout(tester);
        await _expectCenteredInk(
          tester,
          capture,
          tokens.forest,
          'loading-${brightness.name}-${c.name}',
        );
        expect(completions, 0);

        ready.complete();
        await tester.pump();
        await _advance(tester, 220);
        _expectCenteredLayout(tester);
        await _advance(tester, 520);
        _expectCenteredLayout(tester);
        expect(find.byKey(const ValueKey('welcome-text')), findsOneWidget);
        await _expectCenteredInk(
          tester,
          capture,
          tokens.forest,
          'welcome-${brightness.name}-${c.name}',
        );
        expect(tester.takeException(), isNull);
        await _advance(tester, 1200);
        expect(completions, 1);
      });
    }

    testWidgets('reduced-motion mark stays centred ${brightness.name}', (
      tester,
    ) async {
      final capture = GlobalKey();
      final ready = Completer<void>();
      var completions = 0;
      await pumpLocalized(
        tester,
        RepaintBoundary(
          key: capture,
          child: WelcomeScreen(
            firstName: 'Mira',
            profileReady: ready.future,
            onComplete: () => completions++,
          ),
        ),
        brightness: brightness,
        surfaceSize: const Size(390, 844),
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      _expectCenteredLayout(tester);
      await _expectCenteredInk(
        tester,
        capture,
        tokens.forest,
        'reduced-${brightness.name}',
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(completions, 0);
      ready.complete();
      await tester.pumpAndSettle();
      expect(completions, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
