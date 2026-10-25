import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// True when the platform asks for reduced motion.
///
/// Aspect lookup, NOT a `maybeOf` read of the flag: the full lookup depends
/// on the whole MediaQueryData, so every keyboard-inset frame rebuilt all ~42
/// call sites of this helper. The aspect variant rebuilds only when the flag
/// itself flips (pinned in motion_media_query_test.dart).
bool reducedMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// A11y helper for "reduce motion": returns [base], or `Duration.zero` when
/// the user reduced motion, collapsing intro gates and decorative animations.
Duration motionDuration(BuildContext context, Duration base) =>
    reducedMotion(context) ? Duration.zero : base;

/// [AnimatedSize] that steps aside under "reduce motion" instead of animating
/// with `Duration.zero`.
///
/// RenderAnimatedSize handles a zero duration by resizing inside its own
/// `performLayout`, which trips "A RenderAnimatedSize was mutated in its own
/// performLayout implementation" (debug assertion; silent layout risk in
/// release). So the widget is dropped entirely and [child] renders directly —
/// the end state is identical, only the transition is gone.
///
/// [duration] is the BASE duration; do NOT wrap it in [motionDuration].
Widget maybeAnimatedSize(
  BuildContext context, {
  required Widget child,
  required Duration duration,
  Curve curve = Curves.linear,
  AlignmentGeometry alignment = Alignment.center,
  Clip clipBehavior = Clip.hardEdge,
}) {
  if (reducedMotion(context)) return child;
  return AnimatedSize(
    duration: duration,
    curve: curve,
    alignment: alignment,
    clipBehavior: clipBehavior,
    child: child,
  );
}

// ---------------------------------------------------------------------------
// The motion language of the tabs (2026-10-01): one curve, one family of
// durations. Every widget in `lively.dart` and every value tween in the tab
// roots uses these, always through [motionDuration].
// ---------------------------------------------------------------------------

/// The one curve: fast start, soft landing, no overshoot.
const Curve kMotionCurve = Curves.easeOutCubic;

/// A value moving to its new state: the calorie arc, bars, counting numbers.
const Duration kMotionValue = Duration(milliseconds: 520);

/// A section or a list row entering. Short on purpose: on a tab's first
/// visit the sections enter inside the shell's fade-through, and the whole
/// stagger (4 × [kMotionStagger] + this = 300 ms) is visually done when the
/// fade settles at 260 ms, so the two read as one arrival.
const Duration kMotionEnter = Duration(milliseconds: 220);

/// Delay between two sections of a first-view entrance.
const Duration kMotionStagger = Duration(milliseconds: 20);

/// Press feedback: sinking in, and easing back out.
const Duration kMotionPressIn = Duration(milliseconds: 90);
const Duration kMotionPressOut = Duration(milliseconds: 160);

// ---------------------------------------------------------------------------
// Objects that arrive and respond (polish 2026-10-25): a decision surface
// settles on a soft spring, a glyph or a check pops, a pressed control
// rebounds a hair past rest. Every spring settles at t = 1, so nothing loops
// and `pumpAndSettle` terminates.
// ---------------------------------------------------------------------------

/// An under-damped spring's step response, normalised so it settles at
/// t = 1: it overshoots 1 once (by `exp(-ζπ/√(1-ζ²))`) and comes back. Use
/// it on a linear driver (a route's animation, a one-shot controller).
class SpringCurve extends Curve {
  const SpringCurve({this.dampingRatio = 0.72});

  /// ζ: 0.72 overshoots about 4 %, 0.55 about 12 %, 0.45 about 20 %.
  final double dampingRatio;

  @override
  double transformInternal(double t) {
    final zeta = dampingRatio.clamp(0.05, 0.999);
    // The envelope is down to 0.2 % at t = 1.
    final omega = math.log(500) / zeta;
    final damped = omega * math.sqrt(1 - zeta * zeta);
    final envelope = math.exp(-zeta * omega * t);
    return 1 -
        envelope *
            (math.cos(damped * t) +
                (zeta * omega / damped) * math.sin(damped * t));
  }
}

/// A surface or content landing: about 4 % past rest, then back.
const Curve kSpringSettle = SpringCurve(dampingRatio: 0.72);

/// A glyph or a check that lands: about 12 % past rest.
const Curve kSpringPop = SpringCurve(dampingRatio: 0.55);

/// A decision card arriving (the route, its rise and its content).
const Duration kMotionDecisionIn = Duration(milliseconds: 460);

/// A decision card leaving: quick, no bounce.
const Duration kMotionDecisionOut = Duration(milliseconds: 180);

/// A locked primary action lighting up as it arms; a label taking on a new
/// job.
const Duration kMotionLightUp = Duration(milliseconds: 240);
