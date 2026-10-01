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

/// Like [motionDuration], but for a pause (e.g. a `Future.delayed` hold).
Duration motionDelay(BuildContext context, Duration base) =>
    motionDuration(context, base);

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
