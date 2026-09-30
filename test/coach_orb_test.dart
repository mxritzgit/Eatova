// CoachOrb — the dark redesign's violet sphere (2026-09-28): a static glow,
// a breathing core and a pulsing halo.
//
// Two halves. The SHAPE of the tree (perf audit 2026-09-01, B5): whether a
// blur is rasterised once or sixty times a second is invisible on screen and
// only shows up as heat and battery drain, so no rendering test would catch a
// regression. This file pins the structure that keeps the cost down:
//
//   * the glow's 36 px shadow blur sits outside both animated layers, so it
//     is recorded once and never repainted while the orb breathes,
//   * each animated layer (halo, core) sits behind its own RepaintBoundary,
//     so its per-frame change never dirties the Stack layer,
//   * the animated layers keep their decoration as the transition's child:
//     built once, never per frame.
//
// And the LOOK the design specifies: the gradient stops, the 5 s breath and
// the reduced-motion contract.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, debugOnProfilePaint;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import 'support/harness.dart';

Finder get _halo => find.byKey(const ValueKey('coach-orb-halo'));
Finder get _glow => find.byKey(const ValueKey('coach-orb-glow'));
Finder get _core => find.byKey(const ValueKey('coach-orb-core'));

/// Widget types on the path from [start] up to (and including) [CoachOrb].
/// Index 0 is the immediate parent, so a smaller index means "further inside".
List<Type> _pathUp(WidgetTester tester, Finder start) {
  final types = <Type>[];
  tester.element(start).visitAncestorElements((e) {
    types.add(e.widget.runtimeType);
    return e.widget.runtimeType != CoachOrb;
  });
  return types;
}

RenderRepaintBoundary _boundaryAbove(WidgetTester tester, Finder layer) =>
    tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: layer, matching: find.byType(RepaintBoundary)).first,
    );

double _coreScale(WidgetTester tester) => tester
    .widget<ScaleTransition>(
      find.ancestor(of: _core, matching: find.byType(ScaleTransition)).first,
    )
    .scale
    .value;

double _haloOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.ancestor(of: _halo, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

/// One mounted, freely animating orb whose ticker has had its first tick.
Future<void> _pumpOrb(WidgetTester tester) async {
  await pumpLocalized(tester, const CoachOrb(), reducedMotion: false);
  await tester.pump();
}

void main() {
  group('the animated layers pay for themselves only', () {
    testWidgets('the glow\'s shadow blur is not repainted while it breathes', (
      tester,
    ) async {
      await _pumpOrb(tester);
      final glow = tester.renderObject(_glow);

      var paints = 0;
      debugOnProfilePaint = (ro) {
        if (identical(ro, glow)) paints += 1;
      };
      try {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      } finally {
        // flutter_test fails a test that leaves a render debug variable set.
        debugOnProfilePaint = null;
      }

      expect(
        paints,
        0,
        reason:
            'an animation drags the Stack layer along and re-records '
            'the shadow blur every frame',
      );
      expect(
        _pathUp(tester, _glow),
        isNot(contains(ScaleTransition)),
        reason: 'the glow must not scale with the core',
      );
    });

    // The halo's fade is a repaint boundary of its own while its opacity is
    // between 0 and 1, so the explicit boundary above it only has to keep the
    // Stack out (at full opacity it is the one that catches the scale).
    for (final (name, layer, transition, ownRepaints)
        in <(String, Finder, Type, bool)>[
          ('halo', _halo, ScaleTransition, false),
          ('core', _core, ScaleTransition, true),
        ]) {
      testWidgets('the $name repaints behind its own boundary', (tester) async {
        await _pumpOrb(tester);
        final path = _pathUp(tester, layer);
        expect(path.indexOf(transition), isNonNegative);
        expect(
          path.indexOf(RepaintBoundary),
          greaterThan(path.indexOf(transition)),
          reason: 'the boundary sits ABOVE the animation',
        );

        final boundary = _boundaryAbove(tester, layer)..debugResetMetrics();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          boundary.debugSymmetricPaintCount,
          0,
          reason: 'the $name was painted together with its parent',
        );
        if (ownRepaints) {
          expect(
            boundary.debugAsymmetricPaintCount,
            greaterThan(0),
            reason: 'the $name never repainted on its own — not animating?',
          );
        }
      });

      testWidgets('the $name decoration is built once, not per frame', (
        tester,
      ) async {
        await _pumpOrb(tester);
        final before = tester.widget(layer);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(identical(tester.widget(layer), before), isTrue);
      });
    }
  });

  group('look (design: coach/template.html)', () {
    testWidgets('76 px sphere lit from the upper left, 180 px halo', (
      tester,
    ) async {
      await pumpLocalized(tester, const CoachOrb());
      const t = AppTokens.dark;
      expect(tester.getSize(find.byType(CoachOrb)), const Size(76, 76));
      expect(tester.getSize(_halo).width, closeTo(180, 0.01));

      final core =
          tester.widget<DecoratedBox>(_core).decoration as BoxDecoration;
      final gradient = core.gradient! as RadialGradient;
      expect(gradient.colors, [t.orbLight, t.accentFill, t.orbMid, t.orbDeep]);
      expect(gradient.stops, const [0, 0.26, 0.62, 1]);
      expect(gradient.center, const Alignment(-0.32, -0.44));

      final glow =
          tester.widget<DecoratedBox>(_glow).decoration as BoxDecoration;
      expect(glow.boxShadow!.single.blurRadius, 36);
      expect(
        glow.boxShadow!.single.color,
        t.accentGlow.withValues(alpha: 0.55),
      );
    });

    testWidgets('one breath takes five seconds: 1 -> 1.06 -> 1', (
      tester,
    ) async {
      await _pumpOrb(tester);
      expect(_coreScale(tester), closeTo(1, 0.001));
      expect(_haloOpacity(tester), closeTo(0.55, 0.001));

      await tester.pump(CoachOrb.period ~/ 2);
      expect(_coreScale(tester), closeTo(1.06, 0.001));
      expect(_haloOpacity(tester), closeTo(1, 0.001));

      await tester.pump(CoachOrb.period ~/ 2);
      expect(_coreScale(tester), closeTo(1, 0.001));
    });

    testWidgets('under reduced motion the orb holds still', (tester) async {
      // Harness default: disableAnimations = true.
      await pumpLocalized(tester, const CoachOrb());
      await tester.pump();
      await tester.pump(CoachOrb.period ~/ 2);
      expect(_coreScale(tester), 1);
      expect(_haloOpacity(tester), 0.55);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
