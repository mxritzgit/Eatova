import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/shared/eatova_wordmark.dart';

// `theme:` is mandatory here: the wordmark reads its colors via `context.t`,
// and AppTokens.of throws on purpose when the ThemeExtension is missing.
void main() {
  Future<void> pumpMarke(WidgetTester tester, Brightness brightness) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(brightness),
        home: const Scaffold(
          body: Center(child: EatovaWordmark(fontSize: 26)),
        ),
      ),
    );
  }

  testWidgets('EatovaWordmark rendert eat + Fokusring + va ohne Overflow',
      (tester) async {
    await pumpMarke(tester, Brightness.dark);

    expect(find.text('eat'), findsOneWidget);
    expect(find.text('va'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(EatovaWordmark),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('die Marke bleibt in beiden Modi hell', (tester) async {
    // Its only site is the auth screen, which is dark in both modes. With
    // `ink`/`accent` as default the mark would be black on black in light mode.
    for (final brightness in Brightness.values) {
      await pumpMarke(tester, brightness);
      // MaterialApp cross-fades theme changes via AnimatedTheme; without a
      // settle the second pass would still carry the old tone.
      await tester.pumpAndSettle();
      final tokens =
          brightness == Brightness.light ? AppTokens.light : AppTokens.dark;
      final text = tester.widget<Text>(find.text('eat'));
      expect(
        text.style!.color,
        tokens.onForest,
        reason: '$brightness: Schrift muss die Marken-Flaechenfarbe tragen',
      );
    }
  });
}
