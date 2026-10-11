// Visual evidence for the start-failure screen (buildBootErrorApp in
// lib/main.dart), the one page a user reads when the app cannot start:
//
//   boot-error-en / boot-error-de      the release text at 390 px
//   boot-error-en-320-x2               a 320 px phone at 2x text
//
// The screen follows the device brightness; the capture run's brightness is
// handed to it as the platform's. With --dart-define=DARK_REDESIGN_CAPTURE=true
// the PNGs land in build/dark-redesign/ (light: DESIGN_CAPTURE_BRIGHTNESS=
// light); without it the suite still checks that the screen renders without
// an exception or overflow.

import 'package:eatova/main.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/design_capture.dart';

void main() {
  setUpAll(loadDesignFonts);

  for (final (name, locale, width, scale) in const [
    ('boot-error-en', Locale('en', 'US'), 390.0, 1.0),
    ('boot-error-de', Locale('de', 'DE'), 390.0, 1.0),
    ('boot-error-en-320-x2', Locale('en', 'US'), 320.0, 2.0),
  ]) {
    testWidgets(name, (tester) async {
      pinDesignViewport(tester);
      tester.view.physicalSize =
          Size(width, kDesignViewport.height) * kDesignPixelRatio;
      tester.platformDispatcher.localesTestValue = [locale];
      tester.platformDispatcher.platformBrightnessTestValue =
          designCaptureBrightness ?? Brightness.dark;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await tester.pumpWidget(
        designCaptureBoundary(
          buildBootErrorApp(StateError('boot'), showDetails: false),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = locale.languageCode == 'de' ? deL10n : enL10n;
      expect(find.text(l10n.bootErrorTitle), findsOneWidget);
      expect(find.text(l10n.bootErrorBody), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, name);
    });
  }
}
