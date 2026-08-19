import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

// ---------------------------------------------------------------------------
// Komplettreview 2026-08-19, Fund 2 — [IconTile] hatte die Kontrast-Korrektur
// nicht bekommen.
//
// Das Muster „Glyph in der voller Kategoriefarbe auf derselben Farbe mit
// ~15 % Deckung" sieht im Dunkelmodus gut aus und scheitert hell: der
// Kohlenhydrat-Amber kam auf 2.2:1. app_tokens.dart beschreibt genau das und
// haelt dafuer [AppTokens.readableOnTint] bereit; MealAvatar und SlotSelector
// benutzen die Korrektur seit dem Design-Refactor, IconTile nicht.
//
// Gemessen wird deshalb NICHT „ruft das Widget die Hilfsfunktion auf"
// (das waere eine Tautologie), sondern das Kontrastverhaeltnis zwischen dem
// tatsaechlich gezeichneten Glyph und der tatsaechlich gezeichneten Kachel.
// Schwelle 3:1 — die WCAG-Untergrenze fuer grafische Objekte.
// ---------------------------------------------------------------------------

/// Kontrastverhaeltnis nach WCAG 2.1 (1..21).
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
  // Die Faerbungen, mit denen IconTile im Produktivcode wirklich aufgerufen
  // wird: die Makro-/Slot-Toene, der Marken-Akzent und das Gefahren-Signal.
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
        // Die Kachel ist durchscheinend; gezeichnet wird sie auf der
        // Kartenflaeche, auf der die Zeilen sitzen.
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
    // Die farblose Kachel liegt auf `tile` (fast farblos) — dort ist `ink`
    // richtig und readableOnTint waere eine unnoetige Aufhellung.
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
