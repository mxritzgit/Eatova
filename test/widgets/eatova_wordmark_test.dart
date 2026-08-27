import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/shared/eatova_wordmark.dart';

import '../support/harness.dart';

// The mark reads its colors via `context.t`, and AppTokens.of throws on
// purpose when the ThemeExtension is missing — so a themed mount is mandatory.
//
// Structure and ink used to be two tests, one of them looping over both
// brightnesses by hand. `renderMatrix` declares the same two cases and now
// checks BOTH claims in each of them.
void main() {
  renderMatrix('EatovaWordmark rendert eat + Fokusring + va', (tester, c) async {
    await c.pump(tester, const Center(child: EatovaWordmark(fontSize: 26)));

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

    // Its only site is the auth screen, which is dark in both modes. With
    // `ink`/`accent` as default the mark would be black on black in light
    // mode, so the ink is pinned to the brand surface colour.
    final text = tester.widget<Text>(find.text('eat'));
    expect(
      text.style!.color,
      c.t.onForest,
      reason: '${c.brightness}: Schrift muss die Marken-Flaechenfarbe tragen',
    );
  });

  // `_FocusRingPainter.shouldRepaint` needs a colour change in the SAME widget
  // tree — the matrix above builds every case from scratch, so its painter is
  // always brand new and the branch is never reached. Re-pumping the mounted
  // mark with another ring colour is the only way in.
  group('_FocusRingPainter.shouldRepaint', () {
    Future<CustomPainter> pumpeRing(WidgetTester tester, Color ring) async {
      await pumpLocalized(
        tester,
        Center(child: EatovaWordmark(fontSize: 26, ringColor: ring)),
      );
      return tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(EatovaWordmark),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter!;
    }

    testWidgets('andere Ringfarbe im selben Baum zeichnet neu', (tester) async {
      final alt = await pumpeRing(tester, const Color(0xFFB4FF39));
      final neu = await pumpeRing(tester, const Color(0xFFFF5A36));

      expect(identical(alt, neu), isFalse,
          reason: 'die Farbe steckt im Painter, nicht im State');
      expect(neu.shouldRepaint(alt), isTrue);
    });

    testWidgets('gleiche Ringfarbe zeichnet NICHT neu', (tester) async {
      const gleich = Color(0xFFB4FF39);
      final alt = await pumpeRing(tester, gleich);
      final neu = await pumpeRing(tester, gleich);

      expect(neu.shouldRepaint(alt), isFalse);
    });
  });
}
