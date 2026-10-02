import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/widgets/shared/eatova_wordmark.dart';

import '../support/harness.dart';

// The mark reads its colors via `context.t`, and AppTokens.of throws on
// purpose when the ThemeExtension is missing — so a themed mount is mandatory.
//
// Structure and ink used to be two tests, one of them looping over both
// brightnesses by hand. `renderMatrix` declares the same two cases and now
// checks BOTH claims in each of them.
/// WCAG 2.1 contrast of two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

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

    // Every site (auth entry, code screen, About) passes the mode's colours
    // itself; they must win over the forest-surface defaults.
    await c.pump(
      tester,
      Center(
        child: EatovaWordmark(
          fontSize: 26,
          textColor: c.t.ink,
          ringColor: c.t.accent,
        ),
      ),
    );
    for (final word in ['eat', 'va']) {
      expect(
        tester.widget<Text>(find.text(word)).style!.color,
        c.t.ink,
        reason: '${c.brightness}: "$word" traegt die uebergebene Farbe',
      );
    }
  });

  // A real site: the auth entry header sits on the mode ground `bg`, so the
  // lettering must be the mode's ink and read at 4.5:1 there.
  renderMatrix('Die Marke im Auth-Kopf ist auf dem Seitengrund lesbar', (
    tester,
    c,
  ) async {
    final repository = InMemoryAuthRepository();
    addTearDown(repository.dispose);
    await c.pump(
      tester,
      AuthScreen(authRepository: repository),
      scaffold: false,
      safeArea: false,
      settle: true,
    );
    final eat = find.descendant(
      of: find.byType(EatovaWordmark),
      matching: find.text('eat'),
    );
    final color = tester.widget<Text>(eat).style!.color!;
    expect(color, c.t.ink, reason: '${c.brightness}');
    expect(
      _contrast(color, c.t.bg),
      greaterThanOrEqualTo(4.5),
      reason: '${c.brightness}: Schrift gegen bg',
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
