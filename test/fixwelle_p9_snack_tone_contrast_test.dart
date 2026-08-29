import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// ---------------------------------------------------------------------------
// P9-04 — the toast's tone channel died in light mode.
//
// The toast is painted on [AppTokens.forest] in BOTH modes (snackBarTheme).
// The icon took the raw signal tone, so in the LIGHT palette three of four
// tones sat dark on dark: neutral 2.05:1, warning 2.20:1, error 2.15:1 against
// their own disc — error, warning and a neutral notice looked the same.
//
// Measured here is not "does the widget call helper X" (a tautology) but the
// ratio between the glyph that is drawn and the disc that is drawn under it,
// composited over the surface the toast really uses. Floor 3:1, the WCAG 1.4.11
// bar for graphical objects.
//
// Second half of the finding: a floor alone is not enough — four tones all
// lifted onto the same beige would clear 3:1 and still say nothing. So the
// tones are also held apart from each other (CIE Lab dE76).
// ---------------------------------------------------------------------------

/// Contrast ratio per WCAG 2.1 (1..21).
double _kontrast(Color vordergrund, Color hintergrund) {
  final a = vordergrund.computeLuminance();
  final b = hintergrund.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

/// CIE Lab (D65), for the "do the tones still differ?" half.
List<double> _lab(Color c) {
  double lin(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = lin(c.r), g = lin(c.g), b = lin(c.b);
  final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
  double f(double t) =>
      t > 216 / 24389 ? math.pow(t, 1 / 3).toDouble() : (841 / 108) * t + 4 / 29;
  final fx = f(x), fy = f(y), fz = f(z);
  return <double>[116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

double _deltaE(Color a, Color b) {
  final la = _lab(a), lb = _lab(b);
  return math.sqrt(
    math.pow(la[0] - lb[0], 2) +
        math.pow(la[1] - lb[1], 2) +
        math.pow(la[2] - lb[2], 2),
  );
}

const IconData _testIcon = Icons.bolt_rounded;

/// Shows one toast and returns (glyph color, disc fill composited on the
/// toast surface).
Future<(Color, Color)> _zeigeToast(
  WidgetTester tester,
  Brightness helligkeit,
  SnackTone ton,
) async {
  late BuildContext ctx;
  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(helligkeit),
    home: Scaffold(
      body: Builder(builder: (context) {
        ctx = context;
        return const SizedBox.shrink();
      }),
    ),
  ));
  // MaterialApp lerps its theme (AnimatedTheme). Without settling first, a
  // second case in the same tester would read a half-mixed palette.
  await tester.pumpAndSettle();

  showAppSnack(
    ctx,
    'Ton-Kanal',
    icon: _testIcon,
    tone: ton,
    duration: const Duration(milliseconds: 300),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));

  final glyph = tester.widget<Icon>(find.byIcon(_testIcon));
  final scheibe = tester.widget<Container>(
    find
        .ancestor(of: find.byIcon(_testIcon), matching: find.byType(Container))
        .first,
  );
  final fuellung = (scheibe.decoration! as BoxDecoration).color!;

  // The surface the toast is really painted on — read from the theme, not
  // assumed, so a theme change fails the test instead of faking a pass.
  final grund = buildEatovaTheme(helligkeit).snackBarTheme.backgroundColor!;

  // Let the toast go so no timer outlives the case.
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pumpAndSettle();

  return (glyph.color!, Color.alphaBlend(fuellung, grund));
}

void main() {
  for (final helligkeit in Brightness.values) {
    final tokens =
        helligkeit == Brightness.light ? AppTokens.light : AppTokens.dark;

    test('Der Toast liegt im $helligkeit wirklich auf forest', () {
      // The premise of every case below.
      expect(
        buildEatovaTheme(helligkeit).snackBarTheme.backgroundColor,
        tokens.forest,
      );
    });

    for (final ton in SnackTone.values) {
      testWidgets('Snack-Icon ${ton.name} traegt 3:1 im $helligkeit',
          (tester) async {
        final (glyph, grund) = await _zeigeToast(tester, helligkeit, ton);

        expect(
          _kontrast(glyph, grund),
          greaterThanOrEqualTo(3.0),
          reason: 'Glyph $glyph auf seiner Scheibe $grund — die rohe '
              'Signalfarbe reicht auf der dunkelgruenen Flaeche nicht',
        );
        expect(
          _kontrast(glyph, tokens.forest),
          greaterThanOrEqualTo(3.0),
          reason: 'Glyph $glyph auf ${tokens.forest}',
        );
      });
    }

    testWidgets('Die vier Toene bleiben im $helligkeit unterscheidbar',
        (tester) async {
      final toene = <SnackTone, Color>{};
      for (final ton in SnackTone.values) {
        toene[ton] = (await _zeigeToast(tester, helligkeit, ton)).$1;
      }

      const liste = SnackTone.values;
      for (var i = 0; i < liste.length; i++) {
        for (var j = i + 1; j < liste.length; j++) {
          expect(
            _deltaE(toene[liste[i]]!, toene[liste[j]]!),
            greaterThanOrEqualTo(20.0),
            reason: '${liste[i].name} ${toene[liste[i]]} vs '
                '${liste[j].name} ${toene[liste[j]]} — der Ton-Kanal darf '
                'nicht auf eine Farbe zusammenfallen',
          );
        }
      }
    });
  }

  testWidgets('Ein Ton, der die Schwelle schon haelt, bleibt unveraendert',
      (tester) async {
    // Lime clears the floor on forest in both modes; the correction must not
    // touch it. Guards the "only as far as needed" property of the lift.
    for (final helligkeit in Brightness.values) {
      final tokens =
          helligkeit == Brightness.light ? AppTokens.light : AppTokens.dark;
      final (glyph, _) =
          await _zeigeToast(tester, helligkeit, SnackTone.positive);
      expect(glyph, tokens.lime, reason: '$helligkeit');
    }
  });

  test('readableOnTint waere hier der falsche Weg', () {
    // Documents why the app-wide helper is NOT used on the toast: it mixes
    // towards `ink`, which is near-black in the light palette, so on the dark
    // green toast it pushes the signal tones further down instead of up.
    // Without this case someone "simplifies" the lift back to readableOnTint.
    const t = AppTokens.light;
    for (final ton in <Color>[t.danger, t.warning, t.ink2]) {
      final korrigiert = t.readableOnTint(ton);
      final scheibe = Color.alphaBlend(
        korrigiert.withValues(alpha: 0.18),
        t.forest,
      );
      expect(
        _kontrast(korrigiert, scheibe),
        lessThan(3.0),
        reason: 'readableOnTint($ton) = $korrigiert liegt auf dem Toast unter '
            'der Schwelle — der Helfer ist fuer helle Karten gebaut',
      );
    }
  });
}
