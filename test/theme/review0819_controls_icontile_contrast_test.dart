import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

// ---------------------------------------------------------------------------
// Finding 2 — [IconTile] had not received the contrast correction.
//
// A glyph in the full category color on ~15 % of the same color looks fine in
// dark mode and fails in light (carb amber at 2.2:1); [AppTokens.readableOnTint]
// exists for exactly that.
//
// Measured is NOT "does the widget call the helper" (a tautology) but the
// contrast ratio between the drawn glyph and the drawn tile. Threshold 3:1,
// the WCAG floor for graphical objects.
// ---------------------------------------------------------------------------

/// Contrast ratio per WCAG 2.1 (1..21).
double _kontrast(Color vordergrund, Color hintergrund) {
  final a = vordergrund.computeLuminance();
  final b = hintergrund.computeLuminance();
  final hell = math.max(a, b);
  final dunkel = math.min(a, b);
  return (hell + 0.05) / (dunkel + 0.05);
}

Widget _harness(Widget child, {required Brightness brightness}) {
  return MaterialApp(
    theme: buildEatovaTheme(brightness),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  // The colors IconTile is really called with in production: macro/slot tones,
  // the brand accent and the danger signal.
  final faelle = <String, Color Function(AppTokens)>{
    'carbs': (t) => t.carbs,
    'protein': (t) => t.protein,
    'fat': (t) => t.fat,
    'snack': (t) => t.snack,
    'accent': (t) => t.accent,
    'danger': (t) => t.danger,
  };

  for (final helligkeit in Brightness.values) {
    final tokens =
        helligkeit == Brightness.light ? AppTokens.light : AppTokens.dark;

    for (final eintrag in faelle.entries) {
      testWidgets('IconTile ${eintrag.key} traegt 3:1 im $helligkeit',
          (tester) async {
        final ton = eintrag.value(tokens);
        await tester.pumpWidget(
          _harness(
            IconTile(icon: Icons.bolt_rounded, color: ton),
            brightness: helligkeit,
          ),
        );

        final kachel = tester.widget<Container>(
          find
              .descendant(
                of: find.byType(IconTile),
                matching: find.byType(Container),
              )
              .first,
        );
        final fuellung = (kachel.decoration! as BoxDecoration).color!;
        // The tile is translucent and is drawn on the card surface.
        final grund = Color.alphaBlend(fuellung, tokens.surf);

        final glyph = tester.widget<Icon>(
          find.descendant(
            of: find.byType(IconTile),
            matching: find.byType(Icon),
          ),
        );

        expect(
          _kontrast(glyph.color!, grund),
          greaterThanOrEqualTo(3.0),
          reason: 'Glyph ${glyph.color} auf $grund — die volle Kategoriefarbe '
              'auf ihrer eigenen Tint reicht im Hellmodus nicht',
        );
      });
    }
  }

  testWidgets('ohne Farbe bleibt der Glyph die normale Tinte', (tester) async {
    // The colorless tile sits on `tile`, where `ink` is right and
    // readableOnTint would only lighten needlessly.
    await tester.pumpWidget(
      _harness(
        const IconTile(icon: Icons.bolt_rounded),
        brightness: Brightness.light,
      ),
    );

    final glyph = tester.widget<Icon>(
      find.descendant(of: find.byType(IconTile), matching: find.byType(Icon)),
    );
    expect(glyph.color, AppTokens.light.ink);
  });
}
