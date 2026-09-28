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
      expect(hell.colorScheme.primary, AppTokens.light.accent);

      final dunkel = buildEatovaTheme(Brightness.dark);
      expect(dunkel.scaffoldBackgroundColor, AppTokens.dark.bg);
      expect(dunkel.colorScheme.brightness, Brightness.dark);
    });

    test('Material 3 bleibt das Fundament', () {
      expect(buildEatovaTheme(Brightness.light).useMaterial3, isTrue);
      expect(buildEatovaTheme(Brightness.dark).useMaterial3, isTrue);
    });

    test('die gebuendelten Schriften sind verdrahtet', () {
      for (final brightness in Brightness.values) {
        final theme = buildEatovaTheme(brightness);
        expect(theme.textTheme.bodyMedium?.fontFamily, AppType.uiFamily,
            reason: 'Figtree traegt die UI-Schrift');
      }
      // No google_fonts: families must come from the bundle, otherwise the
      // app fetches from Google at runtime (privacy + offline).
      expect(AppType.uiFamily, 'Figtree');
      expect(AppType.displayFamily, 'BricolageGrotesque');
    });
  });

  // The dark redesign (2026-09-28) takes its palette verbatim from the
  // design templates; these pins catch an accidental drift.
  group('Dunkle Design-Palette', () {
    const t = AppTokens.dark;

    test('Flaechen, Linien und Text tragen die Design-Werte', () {
      expect(t.bg, const Color(0xFF09090C));
      expect(t.surf, const Color(0xFF131318));
      expect(t.surfRaised, const Color(0xFF1B1A22));
      expect(t.surf2, const Color(0xFF1F1E27));
      expect(t.surfWell, const Color(0xFF16151C));
      // A translucent tint (the settings pill track relies on that), which
      // lands on the design's track tone on a card.
      expect(t.tile.a, lessThan(1));
      expect(Color.alphaBlend(t.tile, t.surf).toARGB32(), 0xFF24232D);
      expect(t.arcTrack, const Color(0xFF24212F));
      // rgba(255, 255, 255, 0.06 / 0.08) and rgba(24, 23, 31, 0.84)
      expect(t.line, const Color(0x0FFFFFFF));
      expect(t.cardBorder, t.line);
      expect(t.lineStrong, const Color(0x14FFFFFF));
      expect(t.navGlass, const Color(0xD618171F));
      expect(t.ink, const Color(0xFFF5F3FA));
      expect(t.inkSoft, const Color(0xFFE6E3EE));
      expect(t.inkMuted, const Color(0xFFD9D6E4));
      expect(t.ink2, const Color(0xFFB1AEC0));
      expect(t.ink3, const Color(0xFF8B8898));
      expect(t.inkDisabled, const Color(0xFF5E5B6B));
      expect(t.inkFaint, const Color(0xFF4A4756));
    });

    test('Akzent, Makros und Aktivitaet tragen die Design-Werte', () {
      expect(t.accentFill, const Color(0xFFB9A5FF));
      expect(t.lime, t.accentFill, reason: 'Legacy-Name = Akzent-Fuellung');
      expect(t.onAccentFill, const Color(0xFF16112A));
      expect(t.onAccentMuted, const Color(0xFF3A2F66));
      expect(t.accentText, const Color(0xFFC8B8FF));
      expect(t.accentTint, const Color(0x24B9A5FF));
      expect(t.accentTintStrong, const Color(0x29B9A5FF));
      expect(t.arcStart, const Color(0xFF7C5CFF));
      expect(t.arcEnd, const Color(0xFFD9CCFF));
      expect(t.chartViolet, const Color(0xFF3A3354));
      expect(t.protein, const Color(0xFF1DB071));
      expect(t.carbs, const Color(0xFF4697E2));
      expect(t.fat, const Color(0xFFD57C11));
      expect(t.proteinInk, const Color(0xFF6FDCA4));
      expect(t.carbsInk, const Color(0xFF8CC4FF));
      expect(t.fatInk, const Color(0xFFFFB866));
      expect(t.activity, const Color(0xFFFF9A4D));
      expect(t.activityInk, const Color(0xFFFFB27A));
      expect(t.activityTint, const Color(0x24FF914D));
      expect(t.success, const Color(0xFF6FDCA4));
    });

    test('die opaken Tints sind die Design-Tints ueber der Karte', () {
      Color ueber(Color c, double a) =>
          Color.alphaBlend(c.withValues(alpha: a), t.surf);
      void nah(Color ist, Color soll, String name) {
        for (final (a, b) in <(double, double)>[
          (ist.r, soll.r),
          (ist.g, soll.g),
          (ist.b, soll.b),
        ]) {
          expect((a - b).abs(), lessThanOrEqualTo(1 / 255), reason: name);
        }
      }

      nah(t.forest, ueber(t.accentFill, 0.16), 'forest');
      nah(t.proteinSurface, ueber(t.protein, 0.16), 'proteinSurface');
      nah(t.carbsSurface, ueber(t.carbs, 0.16), 'carbsSurface');
      nah(t.fatSurface, ueber(t.fat, 0.18), 'fatSurface');
    });

    // #8B8898 carries 84 captions in the templates, so it has to be body-text
    // safe wherever it sits — except on the track/field fills, where hints
    // stay ink2 (documented on the token).
    test('Tertiaertext ink3 erreicht AA auf allen Kartenflaechen', () {
      for (final entry in <String, Color>{
        'bg': t.bg,
        'surf': t.surf,
        'surf2': t.surf2,
        'surfRaised': t.surfRaised,
        'surfWell': t.surfWell,
      }.entries) {
        expect(_contrast(t.ink3, entry.value), greaterThanOrEqualTo(4.5),
            reason: 'ink3 auf ${entry.key}');
      }
    });

    test('Akzent- und Makro-Toene sind als Text auf der Karte lesbar', () {
      for (final entry in <String, Color>{
        'accentText': t.accentText,
        'proteinInk': t.proteinInk,
        'carbsInk': t.carbsInk,
        'fatInk': t.fatInk,
        'activityInk': t.activityInk,
        'success': t.success,
        'inkMuted': t.inkMuted,
        'inkSoft': t.inkSoft,
      }.entries) {
        expect(_contrast(entry.value, t.surf), greaterThanOrEqualTo(4.5),
            reason: '${entry.key} auf surf');
      }
      expect(
        _contrast(t.accentText, Color.alphaBlend(t.accentTint, t.surf)),
        greaterThanOrEqualTo(4.5),
        reason: 'Akzent-Text auf seiner Tint-Pille',
      );
      expect(
        _contrast(t.onAccentFill, t.accentFill),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(t.onAccentMuted, t.accentFill),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('die inaktiven Nav-Items bleiben auf dem Glas lesbar', () {
      // Worst case: the glass over the plain page, nothing brighter behind.
      final glas = Color.alphaBlend(t.navGlass, t.bg);
      expect(_contrast(t.ink3, glas), greaterThanOrEqualTo(4.5));
      final kapsel = Color.alphaBlend(t.accentTintStrong, glas);
      expect(_contrast(t.accentText, kapsel), greaterThanOrEqualTo(4.5));
    });

    test('neue Tokens laufen durch copyWith und lerp', () {
      const rot = Color(0xFFFF0000);
      final kopie = t.copyWith(ink3: rot, navGlass: rot);
      expect(kopie.ink3, rot);
      expect(kopie.navGlass, rot);
      expect(kopie.accentText, t.accentText);
      expect(AppTokens.light.lerp(t, 1).ink3, t.ink3);
      expect(AppTokens.light.lerp(t, 0).ink3, AppTokens.light.ink3);
    });
  });

  group('Form-Skala', () {
    test('folgt dem Design', () {
      expect(rHero, 28, reason: 'Kalorien-Karte');
      expect(rCard, 24, reason: 'Listen-Karten');
      expect(rTile, 20, reason: 'Makro-Kacheln');
      expect(rThumb, 18);
      expect(rControl, 14, reason: 'Controls und Icon-Kacheln');
      expect(rNav, 26);
      // The design's primary buttons are pills: 54 px tall, radius 27.
      expect(rButton, kPrimaryButtonHeight / 2);
      expect(rPill, greaterThanOrEqualTo(999));
    });
  });

  group('Typo-Presets', () {
    const ink = Color(0xFFFFFFFF);

    test('Tab-Titel: Bricolage 36, -0.03 em, Zeilenhoehe 1.05, ExtraBold', () {
      final title = AppType.pageTitle(ink);
      expect(title.fontFamily, AppType.displayFamily);
      expect(title.fontSize, 36);
      expect(title.letterSpacing, closeTo(-36 * 0.03, 1e-9));
      expect(title.height, 1.05);
      expect(title.fontWeight, FontWeight.w800);
      // Pushed pages keep their smaller title.
      expect(AppType.pageTitle(ink, subpage: true).fontSize, 24);
    });

    testWidgets('Tab-Titel wachsen hoechstens auf 60 px, Fliesstext voll',
        (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(AppType.pageTitleScaler(context).scale(36), closeTo(60, 1e-9));
      expect(MediaQuery.textScalerOf(context).scale(14), 28);
    });

    test('Eyebrow: 12 px, 700, 0.07 em Laufweite', () {
      final eyebrow = AppType.sectionEyebrow(AppTokens.dark.accentText);
      expect(eyebrow.fontFamily, AppType.uiFamily);
      expect(eyebrow.fontSize, 12);
      expect(eyebrow.fontWeight, FontWeight.w700);
      expect(eyebrow.letterSpacing, closeTo(12 * 0.07, 1e-9));
      expect(eyebrow.color, AppTokens.dark.accentText);
    });
  });
}
