// CoachOrb — the SHAPE of the tree, not the look (perf audit 2026-09-01, B5).
//
// The orb stacks three layers, two of them animated endlessly and two of them
// blurred: a 40px shadow glow, a Gaussian-blurred sweep gradient that rotates,
// and a gradient core that breathes. Whether those blurs are rasterised once
// or sixty times a second is invisible on screen — it only shows up as heat
// and battery drain — so no rendering test would ever catch a regression here.
// This file pins the structure that keeps the cost down:
//
//   * the blurred sweep hangs on the AnimatedBuilder's `child`, so it is BUILT
//     once instead of once per frame,
//   * a RepaintBoundary sits between the rotation and the blur, so it is
//     PAINTED once and every frame only swaps the transform matrix,
//   * both animated layers sit behind their own boundary, so neither drags the
//     glow's 40px shadow blur into a per-frame repaint.
//
// The last two tests pin the look the restructure had to leave alone (sigma,
// gradient, one turn per seven seconds) and the reduced-motion contract.

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, debugOnProfilePaint;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/coach/coach_chat_screen.dart';

import 'support/harness.dart';

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

Finder get _blur => find.byType(ImageFiltered);

/// The one AnimatedBuilder driving the ring.
AnimatedBuilder _ringBuilder(WidgetTester tester) =>
    tester.widget<AnimatedBuilder>(
      find.ancestor(of: _blur, matching: find.byType(AnimatedBuilder)).first,
    );

/// The glow: the only DecoratedBox in the orb carrying a box shadow.
Finder get _glow => find.descendant(
      of: find.byType(CoachOrb),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).boxShadow != null,
      ),
    );

/// The breathing core: the radial gradient. Not `gradient != null` — the
/// ring's Container builds a DecoratedBox of its own (sweep gradient).
Finder get _core => find.descendant(
      of: find.byType(CoachOrb),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient is RadialGradient,
      ),
    );

/// Widget types on the path from [start] up to (and including) [CoachOrb].
/// Index 0 is the immediate parent, so a smaller index means "further inside".
List<Type> _pfadNachOben(WidgetTester tester, Finder start) {
  final typen = <Type>[];
  tester.element(start).visitAncestorElements((e) {
    typen.add(e.widget.runtimeType);
    return e.widget.runtimeType != CoachOrb;
  });
  return typen;
}

/// Rotation of the ring, read back out of the Transform's matrix.
double _ringWinkel(WidgetTester tester) {
  final t = tester.widget<Transform>(
    find.ancestor(of: _blur, matching: find.byType(Transform)).first,
  );
  final m = t.transform.storage; // [cos, sin, ...] for a rotation about Z
  return math.atan2(m[1], m[0]);
}

/// One mounted, freely animating orb whose ticker has already had its first
/// (zero-elapsed) tick — from here on `pump(d)` advances the spin by exactly
/// `d`.
Future<void> _pumpOrb(WidgetTester tester) async {
  await pumpLocalized(tester, const CoachOrb(), reducedMotion: false);
  await tester.pump();
}

void main() {
  // -------------------------------------------------------------------------
  // Rotating ring
  // -------------------------------------------------------------------------
  group('Ring: der Weichzeichner haengt ausserhalb des Frame-Rumpfs', () {
    testWidgets('der Blur ist das child des AnimatedBuilders, nicht sein Rumpf',
        (tester) async {
      await _pumpOrb(tester);

      final kind = _ringBuilder(tester).child;
      expect(kind, isNotNull,
          reason: 'ohne child baut der Builder den Blur pro Frame neu');
      expect(kind, isA<RepaintBoundary>());
      expect((kind! as RepaintBoundary).child, isA<ImageFiltered>());
    });

    testWidgets('ueber Frames hinweg bleibt es dieselbe Widget-Instanz',
        (tester) async {
      await _pumpOrb(tester);
      final vorher = tester.widget<ImageFiltered>(_blur);

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(identical(tester.widget<ImageFiltered>(_blur), vorher), isTrue,
          reason: 'eine neue Instanz heisst: der Builder-Rumpf baut ihn wieder');
    });

    testWidgets('zwischen Drehung und Blur steht eine RepaintBoundary',
        (tester) async {
      await _pumpOrb(tester);
      final pfad = _pfadNachOben(tester, _blur);

      final innen = pfad.indexOf(RepaintBoundary);
      final drehung = pfad.indexOf(Transform);
      expect(innen, isNonNegative);
      expect(drehung, isNonNegative);
      expect(innen, lessThan(drehung),
          reason: 'die Boundary muss UNTER der Drehung liegen, sonst gibt es '
              'kein Raster, das die Drehung wiederverwenden kann');
      // Inner boundary plus the outer one around the whole AnimatedBuilder.
      expect(pfad.where((t) => t == RepaintBoundary).length,
          greaterThanOrEqualTo(2));
    });

    testWidgets('der Blur wird einmal gezeichnet, danach nur noch gedreht',
        (tester) async {
      await _pumpOrb(tester);

      final innen = tester.renderObject<RenderRepaintBoundary>(
        find.byWidget(_ringBuilder(tester).child!),
      )..debugResetMetrics();
      final aussen = tester.renderObject<RenderRepaintBoundary>(
        find
            .ancestor(
                of: find.byType(AnimatedBuilder),
                matching: find.byType(RepaintBoundary))
            .first,
      )..debugResetMetrics();

      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // symmetric = "repainted together with the parent" = the boundary bought
      // nothing that frame; asymmetric = parent and child went separate ways.
      expect(innen.debugSymmetricPaintCount, 0,
          reason: 'der Blur wurde waehrend der Drehung neu gezeichnet');
      expect(innen.debugAsymmetricPaintCount, greaterThan(0),
          reason: 'das gehaltene Raster wurde nie wiederverwendet');

      // The outer boundary earns its place by repainting WITHOUT its parent:
      // the per-frame rotation stops here instead of dirtying the Stack layer.
      expect(aussen.debugSymmetricPaintCount, 0);
      expect(aussen.debugAsymmetricPaintCount, greaterThan(0));
    });
  });

  // -------------------------------------------------------------------------
  // Glow and breathing core
  // -------------------------------------------------------------------------
  group('Die beiden anderen Lagen zahlen nicht fuer die Animationen', () {
    testWidgets('der 40px-Schattenblur wird waehrend der Animation nicht neu '
        'gezeichnet', (tester) async {
      await _pumpOrb(tester);
      final glow = tester.renderObject(_glow);

      var male = 0;
      debugOnProfilePaint = (ro) {
        if (identical(ro, glow)) male += 1;
      };
      try {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      } finally {
        // Must be reset: flutter_test fails a test that leaves a render debug
        // variable set.
        debugOnProfilePaint = null;
      }

      expect(male, 0,
          reason: 'eine der Animationen zieht die Stack-Ebene mit hoch und '
              'laesst den Schattenblur pro Frame neu aufzeichnen');
    });

    testWidgets('der atmende Kern haelt seine Neuzeichnung bei sich',
        (tester) async {
      await _pumpOrb(tester);
      final pfad = _pfadNachOben(tester, _core);

      // Opposite of the ring on purpose: the boundary sits ABOVE the scale.
      // The core carries no filter and has to be redrawn at the new scale
      // anyway, so a cached layer under the scale would only add compositing;
      // what is worth having is the isolation from the glow next door.
      final skalierung = pfad.indexOf(ScaleTransition);
      final boundary = pfad.indexOf(RepaintBoundary);
      expect(skalierung, isNonNegative);
      expect(boundary, greaterThan(skalierung));

      final kern = tester.renderObject<RenderRepaintBoundary>(
        find.ancestor(of: _core, matching: find.byType(RepaintBoundary)).first,
      )..debugResetMetrics();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(kern.debugSymmetricPaintCount, 0,
          reason: 'die Atmung wurde zusammen mit ihrer Elternebene gezeichnet');
    });
  });

  // -------------------------------------------------------------------------
  // What the restructure had to leave alone
  // -------------------------------------------------------------------------
  group('Aussehen unveraendert', () {
    testWidgets('Sigma 1.5 isotrop auf einem Sweep-Kreis', (tester) async {
      await _pumpOrb(tester);

      expect(tester.widget<ImageFiltered>(_blur).imageFilter,
          ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5));

      final ring = tester.widget<Container>(
        find.descendant(of: _blur, matching: find.byType(Container)),
      );
      final deko = ring.decoration! as BoxDecoration;
      expect(deko.shape, BoxShape.circle);
      expect(deko.gradient, isA<SweepGradient>(),
          reason: 'nur ein voller, mittig gedrehter Kreis darf ueberhaupt '
              'vorgerastert und dann gedreht werden');
    });

    testWidgets('ein Umlauf dauert weiterhin sieben Sekunden', (tester) async {
      await _pumpOrb(tester);
      final start = _ringWinkel(tester);

      // A quarter of 7 s must be a quarter turn.
      await tester.pump(const Duration(milliseconds: 1750));

      expect(_ringWinkel(tester) - start, closeTo(math.pi / 2, 0.05));
    });

    testWidgets('bei reduzierter Bewegung steht der Ring still',
        (tester) async {
      // Harness default: disableAnimations = true.
      await pumpLocalized(tester, const CoachOrb());
      await tester.pump();
      final start = _ringWinkel(tester);

      await tester.pump(const Duration(milliseconds: 1750));

      expect(_ringWinkel(tester), start);
    });
  });
}
