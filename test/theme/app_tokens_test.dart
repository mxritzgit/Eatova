import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';

// The palette lives as a ThemeExtension, not as top-level `const`s, so a
// surface can be light AND dark without every widget building two paths.
// Pinned here: both palettes exist and differ, `context.t` resolves, text
// stays readable in both modes (WCAG), and lerp blends instead of jumping.

/// WCAG 2.1 contrast ratio of two opaque colours (1.0 … 21.0).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hell = math.max(la, lb);
  final dunkel = math.min(la, lb);
  return (hell + 0.05) / (dunkel + 0.05);
}

void main() {
  group('AppTokens', () {
    test('helle und dunkle Palette sind verschieden', () {
      expect(AppTokens.light.bg, isNot(AppTokens.dark.bg));
      expect(AppTokens.light.ink, isNot(AppTokens.dark.ink));
      expect(AppTokens.light.surf, isNot(AppTokens.dark.surf));
    });

    test('hell ist wirklich hell, dunkel wirklich dunkel', () {
      expect(AppTokens.light.bg.computeLuminance(), greaterThan(0.5),
          reason: 'die helle Palette braucht einen hellen Grund');
      expect(AppTokens.dark.bg.computeLuminance(), lessThan(0.1),
          reason: 'die dunkle Palette bleibt off-black, nie reines Schwarz');
      expect(AppTokens.dark.bg, isNot(const Color(0xFF000000)));
    });

    test('Fliesstext erreicht in beiden Modi WCAG AA (4.5:1)', () {
      for (final entry in <String, AppTokens>{
        'hell': AppTokens.light,
        'dunkel': AppTokens.dark,
      }.entries) {
        final t = entry.value;
        expect(_contrast(t.ink, t.bg), greaterThanOrEqualTo(4.5),
            reason: '${entry.key}: Haupttext auf Grund');
        expect(_contrast(t.ink, t.surf), greaterThanOrEqualTo(4.5),
            reason: '${entry.key}: Haupttext auf Karte');
        expect(_contrast(t.onForest, t.forest), greaterThanOrEqualTo(4.5),
            reason: '${entry.key}: Text auf der Marken-Flaeche');
      }
    });

    // 4.5:1, not 3:1: `ink2` almost always carries small type (9.5–12.5 px),
    // which is normal body text under WCAG, not "large text". Checked against
    // all three surfaces the tone appears on.
    test('Sekundaertext erreicht AA (4.5:1) auf allen drei Flaechen', () {
      for (final entry in <String, AppTokens>{
        'hell': AppTokens.light,
        'dunkel': AppTokens.dark,
      }.entries) {
        final t = entry.value;
        expect(_contrast(t.ink2, t.bg), greaterThanOrEqualTo(4.5),
            reason: '${entry.key}: gedaempfter Text auf Grund');
        expect(_contrast(t.ink2, t.surf), greaterThanOrEqualTo(4.5),
            reason: '${entry.key}: gedaempfter Text auf Karte');
        expect(_contrast(t.ink2, t.surf2), greaterThanOrEqualTo(4.5),
            reason: '${entry.key}: gedaempfter Text auf abgesetzter Karte');
      }
    });

    // MealAvatar and the slot picker put a glyph in the slot colour onto the
    // same colour at 16 % opacity, unreadable in the light palette (amber hit
    // 2.15:1), so [AppTokens.readableOnTint] mixes the tone towards [ink].
    test('readableOnTint macht Slot-Glyphen auf ihrer eigenen Tint lesbar', () {
      for (final entry in <String, AppTokens>{
        'hell': AppTokens.light,
        'dunkel': AppTokens.dark,
      }.entries) {
        final t = entry.value;
        for (final paar in <(String, Color)>[
          ('protein', t.protein),
          ('carbs', t.carbs),
          ('fat', t.fat),
          ('snack', t.snack),
        ]) {
          final tint = Color.alphaBlend(paar.$2.withValues(alpha: 0.16), t.surf);
          expect(_contrast(t.readableOnTint(paar.$2), tint),
              greaterThanOrEqualTo(4.5),
              reason: '${entry.key}: ${paar.$1}-Glyph auf seiner eigenen Tint');
        }
      }
    });

    test('Makro-Farben sind in beiden Modi voneinander unterscheidbar', () {
      for (final t in <AppTokens>[AppTokens.light, AppTokens.dark]) {
        final macros = <Color>[t.protein, t.carbs, t.fat];
        expect(macros.toSet().length, 3,
            reason: 'eine Makro-Farbe doppelt zu vergeben macht die Balken '
                'unlesbar');
      }
    });

    test('lerp mischt beide Richtungen', () {
      final mitte = AppTokens.light.lerp(AppTokens.dark, 0.5);
      expect(mitte.bg, isNot(AppTokens.light.bg));
      expect(mitte.bg, isNot(AppTokens.dark.bg));

      final ganz = AppTokens.light.lerp(AppTokens.dark, 1.0);
      expect(ganz.bg, AppTokens.dark.bg);
    });

    test('copyWith aendert nur das Uebergebene', () {
      const rot = Color(0xFFFF0000);
      final kopie = AppTokens.light.copyWith(lime: rot);
      expect(kopie.lime, rot);
      expect(kopie.bg, AppTokens.light.bg);
      expect(kopie.ink, AppTokens.light.ink);
    });
  });

  group('buildEatovaTheme', () {
    testWidgets('context.t loest im hellen Theme auf', (tester) async {
      late AppTokens gelesen;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.light),
          home: Builder(
            builder: (context) {
              gelesen = context.t;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(gelesen.bg, AppTokens.light.bg);
    });

    testWidgets('context.t loest im dunklen Theme auf', (tester) async {
      late AppTokens gelesen;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.dark),
          home: Builder(
            builder: (context) {
              gelesen = context.t;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(gelesen.bg, AppTokens.dark.bg);
    });

    test('Scaffold-Grund und ColorScheme folgen den Tokens', () {
      final hell = buildEatovaTheme(Brightness.light);
      expect(hell.scaffoldBackgroundColor, AppTokens.light.bg);
      expect(hell.colorScheme.brightness, Brightness.light);
      expect(hell.colorScheme.primary, AppTokens.light.forest);

      final dunkel = buildEatovaTheme(Brightness.dark);
      expect(dunkel.scaffoldBackgroundColor, AppTokens.dark.bg);
      expect(dunkel.colorScheme.brightness, Brightness.dark);
    });

    test('Material 3 bleibt das Fundament', () {
      expect(buildEatovaTheme(Brightness.light).useMaterial3, isTrue);
      expect(buildEatovaTheme(Brightness.dark).useMaterial3, isTrue);
    });

    test('die gebuendelten Schriften sind verdrahtet', () {
      final theme = buildEatovaTheme(Brightness.light);
      expect(theme.textTheme.bodyMedium?.fontFamily, AppType.uiFamily,
          reason: 'Archivo traegt die UI-Schrift');
      // No google_fonts: families must come from the bundle, otherwise the
      // app fetches from Google at runtime (privacy + offline).
      expect(AppType.uiFamily, 'Archivo');
      expect(AppType.displayFamily, 'BricolageGrotesque');
    });
  });
}
