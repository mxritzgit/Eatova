import 'package:flutter/widgets.dart';

/// A11y helper for "reduce motion": returns [base], or `Duration.zero` when
/// the user reduced motion, collapsing intro gates and decorative animations.
Duration motionDuration(BuildContext context, Duration base) {
  final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  return reduce ? Duration.zero : base;
}

/// Like [motionDuration], but for a pause (e.g. a `Future.delayed` hold).
Duration motionDelay(BuildContext context, Duration base) =>
    motionDuration(context, base);
