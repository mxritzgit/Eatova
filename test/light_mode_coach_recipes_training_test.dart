// Light mode for Coach, Recipes and Training (2026-10-04): the three places
// where a dark-only assumption survived the token switch.
//
//   * The recipe hero's bookmark drew an always-white glyph on a frosted
//     glass in the page tone; in light the glass is near-white and the glyph
//     vanished. It is `ink` now, like the AI label on the same glass.
//   * The night-studio artwork is a dark photo; faded into a white card it
//     became a grey fog. On a light backdrop it is re-toned as a duotone.
//   * The coach orb's body stop was the accent fill: lavender in dark, a
//     deep iris in light, which flattened the sphere into a dark ball. The
//     body is the `orbBody` token now (dark: still the accent fill).

import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/training/training_studio_widgets.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import 'support/harness.dart';
import 'support/recipes_design_fixtures.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

Future<List<Color>> _pixels(
  WidgetTester tester,
  GlobalKey boundary,
  List<Offset> at,
) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final colors = <Color>[];
  await tester.runAsync(() async {
    final image = await render.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    for (final p in at) {
      final i = (p.dy.toInt() * image.width + p.dx.toInt()) * 4;
      colors.add(
        Color.fromARGB(
          data.getUint8(i + 3),
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        ),
      );
    }
    image.dispose();
  });
  return colors;
}

Matcher _near(Color expected) => predicate<Color>(
  (c) =>
      (c.r - expected.r).abs() * 255 <= 2 &&
      (c.g - expected.g).abs() * 255 <= 2 &&
      (c.b - expected.b).abs() * 255 <= 2,
  'within 2/255 of $expected',
);

void main() {
  group('Rezept-Hero: Lesezeichen auf dem Foto', () {
    for (final brightness in Brightness.values) {
      testWidgets('$brightness: das Zeichen traegt auf dem Glas', (
        tester,
      ) async {
        final t = brightness == Brightness.light
            ? AppTokens.light
            : AppTokens.dark;
        await withClock(Clock.fixed(DateTime(2026, 9, 28, 18, 30)), () async {
          await pumpDesignRecipes(tester, brightness: brightness);
          final glyph = find.descendant(
            of: find.byKey(const ValueKey('recipe-hero-save')),
            matching: find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter != null,
            ),
          );
          final ink = t.ink;
          expect(tester.renderObject(glyph), paints..path(color: ink));
          // The glass (page tone at 60 %) over the darkest and the brightest
          // photo: the glyph keeps 3:1 on both.
          for (final photo in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
            final glass = Color.alphaBlend(t.bg.withValues(alpha: 0.6), photo);
            expect(
              _contrast(ink, glass),
              greaterThanOrEqualTo(3),
              reason: 'over $photo',
            );
          }
        });
      });
    }
  });

  group('Studio-Grafik', () {
    testWidgets('das Duoton fuehrt Schwarz zum Schatten, Licht zum Grund', (
      tester,
    ) async {
      const t = AppTokens.light;
      final key = GlobalKey();
      const grey = Color(0xFF404040); // luminance 0.25: the ramp's middle
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: ColorFiltered(
                colorFilter: studioDuotone(t.arcStart, t.surf),
                child: const SizedBox(
                  width: 30,
                  height: 10,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: ColoredBox(color: Color(0xFF000000))),
                      Expanded(child: ColoredBox(color: grey)),
                      Expanded(child: ColoredBox(color: Color(0xFFFFFFFF))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final [black, mid, white] = await _pixels(tester, key, const [
        Offset(5, 5),
        Offset(15, 5),
        Offset(25, 5),
      ]);
      expect(black, _near(t.arcStart));
      expect(mid, _near(Color.lerp(t.arcStart, t.surf, 0.5)!));
      expect(white, _near(t.surf));
    });

    for (final brightness in Brightness.values) {
      testWidgets('$brightness: getoent nur auf hellem Grund', (tester) async {
        final t = brightness == Brightness.light
            ? AppTokens.light
            : AppTokens.dark;
        await pumpLocalized(
          tester,
          SizedBox(
            width: 350,
            height: 190,
            child: TrainingStudioArtwork(backgroundColor: t.surf),
          ),
          brightness: brightness,
        );
        final toned = find.byKey(const ValueKey('training-studio-duotone'));
        if (brightness == Brightness.light) {
          expect(
            tester.widget<ColorFiltered>(toned).colorFilter,
            studioDuotone(t.arcStart, t.surf),
          );
        } else {
          // The dark card shows the photo as shot.
          expect(toned, findsNothing);
          expect(find.byType(ColorFiltered), findsNothing);
        }
      });
    }
  });

  group('Coach-Orb', () {
    for (final brightness in Brightness.values) {
      testWidgets('$brightness: die Kugel bleibt leuchtend', (tester) async {
        final t = brightness == Brightness.light
            ? AppTokens.light
            : AppTokens.dark;
        await pumpLocalized(tester, const CoachOrb(), brightness: brightness);
        final core =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(const ValueKey('coach-orb-core')),
                    )
                    .decoration
                as BoxDecoration;
        final body = (core.gradient! as RadialGradient).colors[1];
        expect(body, t.orbBody);
        // A lit lavender body (dark: 0.44, light: 0.42), not the deep iris
        // of the light accent fill (0.11) that read as a dark ball.
        expect(body.computeLuminance(), greaterThan(0.35));
      });
    }

    test('dunkel bleibt die Akzent-Fuellung des Designs', () {
      expect(AppTokens.dark.orbBody, AppTokens.dark.accentFill);
    });
  });
}
