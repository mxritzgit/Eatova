import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import '../support/design_capture.dart' show loadDesignFonts;

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

/// [farbe] at [alpha] composited on the palette's card.
Color _ueberKarte(AppTokens t, Color farbe, double alpha) =>
    Color.alphaBlend(farbe.withValues(alpha: alpha), t.surf);

/// Channel-wise equal within one 8-bit step (pre-mixed hex rounding).
void _nah(Color ist, Color soll, String name) {
  for (final (a, b) in <(double, double)>[
    (ist.r, soll.r),
    (ist.g, soll.g),
    (ist.b, soll.b),
  ]) {
    expect((a - b).abs(), lessThanOrEqualTo(1 / 255), reason: name);
  }
}

const Map<String, AppTokens> _paletten = <String, AppTokens>{
  'hell': AppTokens.light,
  'dunkel': AppTokens.dark,
};

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

    // WCAG 1.4.11: the calorie arc is a graphical object, so every stop of its
    // gradient needs 3:1 against the unfilled track. The August light arcEnd
    // #B7A6F0 sat at 1.77:1.
    test('Kalorienbogen: jeder Verlaufston hebt sich 3:1 von der Spur ab', () {
      for (final (modus, t) in [
        ('hell', AppTokens.light),
        ('dunkel', AppTokens.dark),
      ]) {
        expect(_contrast(t.arcStart, t.arcTrack), greaterThanOrEqualTo(3.0),
            reason: '$modus: arcStart auf arcTrack');
        expect(_contrast(t.arcEnd, t.arcTrack), greaterThanOrEqualTo(3.0),
            reason: '$modus: arcEnd auf arcTrack');
      }
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

    // readableOnTint on the slot tints: hell_modus_audit_test.dart ('der
    // MealAvatar-Buchstabe erreicht auf seinem eigenen Tint AA').

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
      _nah(t.forest, _ueberKarte(t, t.accentFill, 0.16), 'forest');
      _nah(t.proteinSurface, _ueberKarte(t, t.protein, 0.16), 'proteinSurface');
      _nah(t.carbsSurface, _ueberKarte(t, t.carbs, 0.16), 'carbsSurface');
      _nah(t.fatSurface, _ueberKarte(t, t.fat, 0.18), 'fatSurface');
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

  // The light palette (2026-10-04) mirrors the dark roles instead of copying
  // values: offset surfaces step DOWN from the white card, translucent tokens
  // stay translucent, and the opaque tints are pre-mixed on the white card.
  group('Helle Palette spiegelt die dunklen Rollen', () {
    const t = AppTokens.light;

    test('weisse Karten auf gedaempftem Grund, Versatzflaechen darunter', () {
      expect(t.surf, const Color(0xFFFFFFFF));
      final karte = t.surf.computeLuminance();
      expect(t.bg.computeLuminance(), lessThan(karte));
      for (final entry in <String, Color>{
        'surf2': t.surf2,
        'surfRaised': t.surfRaised,
        'surfWell': t.surfWell,
      }.entries) {
        expect(entry.value.computeLuminance(), lessThan(karte),
            reason: '${entry.key} setzt sich von der Karte ab');
      }
      // The dark order surf < surfWell < surfRaised < surf2, mirrored.
      expect(t.surfWell.computeLuminance(),
          greaterThan(t.surfRaised.computeLuminance()));
      expect(t.surfRaised.computeLuminance(),
          greaterThan(t.surf2.computeLuminance()));
    });

    test('durchscheinende Tokens bleiben durchscheinend', () {
      for (final entry in <String, Color>{
        'tile': t.tile,
        'line': t.line,
        'lineStrong': t.lineStrong,
        'navGlass': t.navGlass,
        'accentTint': t.accentTint,
        'accentTintStrong': t.accentTintStrong,
        'accentGlow': t.accentGlow,
        'activityTint': t.activityTint,
        'shadowTint': t.shadowTint,
        'shadowFloat': t.shadowFloat,
        'scrim': t.scrim,
        'slotBreakfastTint': t.slotBreakfastTint,
        'slotLunchTint': t.slotLunchTint,
        'slotDinnerTint': t.slotDinnerTint,
        'slotSnackTint': t.slotSnackTint,
      }.entries) {
        expect(entry.value.a, lessThan(1), reason: entry.key);
      }
      // lineStrong is the stronger edge, the floating shadow the deeper one.
      expect(t.lineStrong.a, greaterThan(t.line.a));
      expect(t.shadowFloat.a, greaterThan(t.shadowTint.a));
    });

    test('die opaken Tints sind die Akzent-/Makro-Toene ueber der Karte', () {
      _nah(t.forest, _ueberKarte(t, t.accentFill, 0.16), 'forest');
      _nah(t.proteinSurface, _ueberKarte(t, t.protein, 0.12), 'proteinSurface');
      _nah(t.carbsSurface, _ueberKarte(t, t.carbs, 0.12), 'carbsSurface');
      _nah(t.fatSurface, _ueberKarte(t, t.fat, 0.14), 'fatSurface');
      _nah(t.fieldError, _ueberKarte(t, t.danger, 0.14), 'fieldError');
    });

    test('Akzentfamilie und Slot-Farben bleiben die der Marke', () {
      // Same hue family as the dark lavender, deepened for a white card.
      double hue(Color c) => HSLColor.fromColor(c).hue;
      for (final entry in <String, Color>{
        'accentFill': t.accentFill,
        'accent': t.accent,
        'accentText': t.accentText,
        'arcStart': t.arcStart,
        'arcEnd': t.arcEnd,
      }.entries) {
        expect((hue(entry.value) - hue(AppTokens.dark.accentFill)).abs(),
            lessThan(12), reason: entry.key);
      }
      // The snack slot carries the accent in both palettes; the slot icon
      // tints are the slot hues.
      expect(t.snack, t.accent);
      for (final (tint, ton) in <(Color, Color)>[
        (t.slotBreakfastTint, t.carbs),
        (t.slotLunchTint, t.protein),
        (t.slotDinnerTint, t.fat),
        (t.slotSnackTint, t.accent),
      ]) {
        expect(tint.withValues(alpha: 1), ton);
      }
      // Macro hue identity: each light tone within 15 degrees of its dark one.
      for (final (hell, dunkel) in <(Color, Color)>[
        (t.protein, AppTokens.dark.protein),
        (t.carbs, AppTokens.dark.carbs),
        (t.fat, AppTokens.dark.fat),
        (t.activity, AppTokens.dark.activity),
      ]) {
        expect((hue(hell) - hue(dunkel)).abs(), lessThan(15));
      }
    });

    // The light arc mirrors the dark one: the tip is the strongest stop.
    test('der Bogen wird zur Spitze hin kraeftiger', () {
      expect(
        _contrast(t.arcEnd, t.arcTrack),
        greaterThan(_contrast(t.arcStart, t.arcTrack)),
      );
      const d = AppTokens.dark;
      expect(
        _contrast(d.arcEnd, d.arcTrack),
        greaterThan(_contrast(d.arcStart, d.arcTrack)),
      );
    });
  });

  // Every role pair, measured in BOTH palettes. Translucent tokens are
  // composited first: `computeLuminance()` ignores alpha.
  group('Kontrast-Rollen in beiden Paletten', () {
    for (final MapEntry(key: modus, value: t) in _paletten.entries) {
      final gruende = <String, Color>{
        'bg': t.bg,
        'surf': t.surf,
        'surf2': t.surf2,
        'surfRaised': t.surfRaised,
        'surfWell': t.surfWell,
      };

      // ink3 carries 84 captions in the templates, so it has to be body-text
      // safe wherever it sits — except on the track/field fills, where hints
      // stay ink2 (documented on the token).
      test('$modus: jede Textstufe erreicht AA auf allen Kartenflaechen', () {
        for (final grund in gruende.entries) {
          for (final text in <String, Color>{
            'ink': t.ink,
            'inkSoft': t.inkSoft,
            'inkMuted': t.inkMuted,
            'ink2': t.ink2,
            'ink3': t.ink3,
          }.entries) {
            expect(_contrast(text.value, grund.value),
                greaterThanOrEqualTo(4.5),
                reason: '$modus: ${text.key} auf ${grund.key}');
          }
        }
      });

      test('$modus: Hint und Wert tragen auf allen Feld-Fuellungen', () {
        for (final feld in <String, Color>{
          'field': t.field,
          'fieldFocus': t.fieldFocus,
          'fieldError': t.fieldError,
        }.entries) {
          expect(_contrast(t.ink2, feld.value), greaterThanOrEqualTo(4.5),
              reason: '$modus: ink2 auf ${feld.key}');
          expect(_contrast(t.ink, feld.value), greaterThanOrEqualTo(4.5),
              reason: '$modus: ink auf ${feld.key}');
        }
      });

      test('$modus: Akzent als Text, Fuellung und Zustand', () {
        for (final grund in <String, Color>{
          'bg': t.bg,
          'surf': t.surf,
          'surf2': t.surf2,
        }.entries) {
          expect(_contrast(t.accentText, grund.value),
              greaterThanOrEqualTo(4.5),
              reason: '$modus: accentText auf ${grund.key}');
          // `accent` also carries text (links, the today mark's number).
          expect(_contrast(t.accent, grund.value), greaterThanOrEqualTo(4.5),
              reason: '$modus: accent auf ${grund.key}');
          // A selected chip/segment is a state: 3:1 (WCAG 1.4.11).
          expect(_contrast(t.accentFill, grund.value),
              greaterThanOrEqualTo(3.0),
              reason: '$modus: accentFill als Zustand auf ${grund.key}');
        }
        for (final grund in <String, Color>{'bg': t.bg, 'surf': t.surf}
            .entries) {
          final pille = Color.alphaBlend(t.accentTint, grund.value);
          expect(_contrast(t.accentText, pille), greaterThanOrEqualTo(4.5),
              reason: '$modus: Akzent-Text auf seiner Tint-Pille '
                  'ueber ${grund.key}');
          final spur = Color.alphaBlend(t.tile, grund.value);
          expect(_contrast(t.accentFill, spur), greaterThanOrEqualTo(3.0),
              reason: '$modus: gewaehltes Segment auf der Spur '
                  'ueber ${grund.key}');
        }
        expect(_contrast(t.onAccentFill, t.accentFill),
            greaterThanOrEqualTo(4.5));
        expect(_contrast(t.onAccentMuted, t.accentFill),
            greaterThanOrEqualTo(4.5));
      });

      test('$modus: die inaktiven Nav-Items bleiben auf dem Glas lesbar', () {
        // Worst case: the glass over the plain page, nothing brighter behind.
        final glas = Color.alphaBlend(t.navGlass, t.bg);
        expect(_contrast(t.ink3, glas), greaterThanOrEqualTo(4.5));
        final kapsel = Color.alphaBlend(t.accentTintStrong, glas);
        expect(_contrast(t.accentText, kapsel), greaterThanOrEqualTo(4.5));
      });

      test('$modus: Makro-, Aktivitaets- und Erfolgs-Toene als Text', () {
        for (final grund in <String, Color>{'bg': t.bg, 'surf': t.surf}
            .entries) {
          for (final ton in <String, Color>{
            'proteinInk': t.proteinInk,
            'carbsInk': t.carbsInk,
            'fatInk': t.fatInk,
            'activityInk': t.activityInk,
            'success': t.success,
          }.entries) {
            expect(_contrast(ton.value, grund.value),
                greaterThanOrEqualTo(4.5),
                reason: '$modus: ${ton.key} auf ${grund.key}');
          }
        }
        for (final (name, ink, flaeche) in <(String, Color, Color)>[
          ('protein', t.proteinInk, t.proteinSurface),
          ('carbs', t.carbsInk, t.carbsSurface),
          ('fat', t.fatInk, t.fatSurface),
        ]) {
          expect(_contrast(ink, flaeche), greaterThanOrEqualTo(4.5),
              reason: '$modus: ${name}Ink auf ${name}Surface');
          expect(_contrast(t.ink, flaeche), greaterThanOrEqualTo(4.5),
              reason: '$modus: ink auf ${name}Surface');
        }
        expect(
          _contrast(t.activityInk, Color.alphaBlend(t.activityTint, t.surf)),
          greaterThanOrEqualTo(4.5),
          reason: '$modus: activityInk auf seiner Kachel',
        );
      });

      test('$modus: Grafik-Toene tragen 3:1 auf Karte und Spur', () {
        final spur = Color.alphaBlend(t.tile, t.surf);
        for (final ton in <String, Color>{
          'protein': t.protein,
          'carbs': t.carbs,
          'fat': t.fat,
          'activity': t.activity,
          'snack': t.snack,
          'progressAccent': t.progressAccent,
        }.entries) {
          expect(_contrast(ton.value, t.surf), greaterThanOrEqualTo(3.0),
              reason: '$modus: ${ton.key} auf surf');
          expect(_contrast(ton.value, spur), greaterThanOrEqualTo(3.0),
              reason: '$modus: ${ton.key} auf der Spur');
        }
      });

      test('$modus: Slot-Glyphen auf ihren Kacheln', () {
        for (final (name, tint, ink) in <(String, Color, Color)>[
          ('breakfast', t.slotBreakfastTint, t.slotBreakfastInk),
          ('lunch', t.slotLunchTint, t.slotLunchInk),
          ('dinner', t.slotDinnerTint, t.slotDinnerInk),
          ('snack', t.slotSnackTint, t.slotSnackInk),
        ]) {
          final kachel = Color.alphaBlend(tint, t.surf);
          expect(_contrast(ink, kachel), greaterThanOrEqualTo(4.5),
              reason: '$modus: $name-Glyphe auf ihrer Kachel');
        }
      });

      test('$modus: Signaltoene als ungeboxter Text auf Grund und Karte', () {
        for (final grund in <String, Color>{'bg': t.bg, 'surf': t.surf}
            .entries) {
          expect(_contrast(t.danger, grund.value), greaterThanOrEqualTo(4.5),
              reason: '$modus: danger auf ${grund.key}');
          expect(_contrast(t.warning, grund.value), greaterThanOrEqualTo(4.5),
              reason: '$modus: warning auf ${grund.key}');
        }
      });
    }
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

    // Figtree has no "≈" (U+2248); without a fallback "≈ 50 min" shows a
    // missing-glyph box. Every Figtree style falls back to the bundled
    // display family, which has the glyph.
    test('jeder Figtree-Stil faellt auf Bricolage zurueck', () {
      const fallback = [AppType.displayFamily];
      expect(AppType.ui(13).fontFamilyFallback, fallback);
      expect(AppType.sectionEyebrow(ink).fontFamilyFallback, fallback);
      expect(AppType.eyebrow(ink).fontFamilyFallback, fallback);
      for (final brightness in Brightness.values) {
        final theme = buildEatovaTheme(brightness);
        for (final style in _slots(theme.textTheme)) {
          expect(style.fontFamilyFallback, fallback);
        }
      }
    });

    testWidgets('"≈" kommt in Figtree-Text aus Bricolage', (tester) async {
      await tester.runAsync(loadDesignFonts);
      double width(TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: '≈', style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final result = painter.width;
        painter.dispose();
        return result;
      }

      final ui = AppType.ui(20, weight: FontWeight.w700);
      const bricolage = TextStyle(
        fontFamily: AppType.displayFamily,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      );
      final figtreeOnly = ui.copyWith(fontFamilyFallback: const <String>[]);
      expect(width(ui), width(bricolage));
      // Guard: Figtree itself really lacks the glyph, or the check above
      // would pass without any fallback.
      expect(width(figtreeOnly), isNot(width(bricolage)));
    });
  });

  // Material's English geometry adds 0.1-0.5 px tracking and 1.33-1.5 line
  // heights to every Text without its own values; the design sets text with
  // normal tracking and the fonts' normal line height. The body slots keep a
  // reading height of 1.4 (final review B-I1: 16 px dense fields stay 44 px).
  group('Text-Geometrie', () {
    test('Figtree und Bricolage haben 1.2 als natuerliche Zeilenhoehe', () {
      expect(AppType.normalHeight, 1.2);
      expect(AppType.bodyHeight, 1.4);
    });

    testWidgets('das Theme setzt Laufweite 0, Zeilenhoehe normal und 1.4 '
        'fuer Fliesstext', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        late BuildContext context;
        late BuildContext buttonContext;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildEatovaTheme(brightness),
            home: Material(
              child: Builder(
                builder: (c) {
                  context = c;
                  return TextButton(
                    onPressed: () {},
                    child: Builder(
                      builder: (b) {
                        buttonContext = b;
                        return const Text('Los');
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        );
        // The second brightness animates in from the first.
        await tester.pumpAndSettle();
        // Theme.of merges Material's local geometry under the app's theme:
        // the resolved slots are what a Text really inherits.
        final text = Theme.of(context).textTheme;
        final body = <TextStyle>[
          text.bodyLarge!,
          text.bodyMedium!,
          text.bodySmall!,
        ];
        for (final style in _slots(text)) {
          expect(style.letterSpacing, 0, reason: style.debugLabel);
          expect(
            style.height,
            body.contains(style) ? AppType.bodyHeight : AppType.normalHeight,
            reason: style.debugLabel,
          );
        }
        // What a plain Text (bodyMedium) and a button label inherit. Null is
        // fine: no tracking, and the fonts' own (normal) line height.
        for (final (style, height) in [
          (DefaultTextStyle.of(context).style, AppType.bodyHeight),
          (DefaultTextStyle.of(buttonContext).style, AppType.normalHeight),
        ]) {
          expect(style.letterSpacing ?? 0, 0, reason: style.debugLabel);
          expect(
            style.height ?? AppType.normalHeight,
            height,
            reason: style.debugLabel,
          );
          expect(style.fontFamily, AppType.uiFamily);
        }
        // The sizes stay Material's; only bodySmall keeps its 13 px.
        expect(text.bodyMedium!.fontSize, 14);
        expect(text.bodySmall!.fontSize, 13);
        expect(
          text.bodySmall!.color,
          (brightness == Brightness.dark ? AppTokens.dark : AppTokens.light)
              .ink2,
        );
      }
    });
  });
}

/// All fifteen slots of [theme].
List<TextStyle> _slots(TextTheme theme) => <TextStyle?>[
  theme.displayLarge,
  theme.displayMedium,
  theme.displaySmall,
  theme.headlineLarge,
  theme.headlineMedium,
  theme.headlineSmall,
  theme.titleLarge,
  theme.titleMedium,
  theme.titleSmall,
  theme.bodyLarge,
  theme.bodyMedium,
  theme.bodySmall,
  theme.labelLarge,
  theme.labelMedium,
  theme.labelSmall,
].nonNulls.toList();
