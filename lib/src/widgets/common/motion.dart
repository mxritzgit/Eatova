import 'package:flutter/widgets.dart';

/// True when the platform asks for reduced motion.
bool reducedMotion(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;

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
