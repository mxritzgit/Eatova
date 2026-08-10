import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/shared/eatova_wordmark.dart';

// `theme:` ist seit dem Design-Refactor 2026-08-09 Pflicht: die Wortmarke
// liest ihre Farben ueber `context.t`, und AppTokens.of wirft bewusst, wenn
// die ThemeExtension fehlt. Die geprueften Aussagen sind unveraendert; dazu
// kommt die Zusicherung, dass die Marke in BEIDEN Modi hell bleibt.
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
    // Ihr einziger Standort ist der Auth-Screen, und der ist in beiden Modi
    // dunkel (unmigriertes `app_colors.bg`). Mit `ink`/`accent` als Standard
    // waere die Marke im Hellmodus schwarz auf schwarz.
    for (final brightness in Brightness.values) {
      await pumpMarke(tester, brightness);
      // MaterialApp blendet einen Theme-Wechsel ueber ein AnimatedTheme —
      // ohne Settle laege beim zweiten Durchlauf noch der alte Ton an.
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
