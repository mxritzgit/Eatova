import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'motion.dart';

/// Standard toast durations — deliberately short.
///
/// These are DWELL times, not motion: they must NOT run through
/// [motionDuration]. Reduced to 0 under "reduce motion" the toast would be gone
/// before anyone can read it — a behaviour bug, not an a11y fix.
const Duration kSnackShort = Duration(milliseconds: 1600); // plain confirmation
const Duration kSnackAction = Duration(milliseconds: 2200); // with action (undo)
// — short enough to clearly self-dismiss, long enough to still hit the undo.
const Duration kSnackError = Duration(milliseconds: 3000);

/// Meaning instead of color: non-visual layers say WHAT a toast is, the theme
/// decides the tone. Passing `Color` constants ruled out light mode and spread
/// design decisions into the logic.
enum SnackTone { positive, neutral, warning, error }

Color _toneColor(AppTokens t, SnackTone tone) => switch (tone) {
      SnackTone.positive => t.lime,
      SnackTone.neutral => t.ink2,
      SnackTone.warning => t.warning,
      SnackTone.error => t.danger,
    };

/// Shows a short floating toast. ALWAYS removes the current one first so
/// snackbars do not stack on rapid actions.
///
/// Auto-dismiss: Flutter's built-in snackbar timer does NOT fire reliably when
/// system animations are off ("reduce motion") — the entrance completes
/// synchronously and the timer never starts. Hence an own dismiss timer on the
/// content's lifecycle ([_AutoDismiss]), cancelled on dispose.
void showAppSnack(
  BuildContext context,
  String message, {
  IconData? icon,
  SnackTone tone = SnackTone.positive,
  Color? accent,
  SnackBarAction? action,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.removeCurrentSnackBar();
  // The toast sits on the brand surface (snackBarTheme), so the icon takes the
  // lime accent, not the card accent, which would be invisible here. [accent]
  // stays as a direct override for surfaces that still pass a color.
  final effectiveAccent = accent ?? _toneColor(context.t, tone);
  final effective = duration ?? (action != null ? kSnackAction : kSnackShort);
  messenger.showSnackBar(
    SnackBar(
      duration: effective,
      content: _AutoDismiss(
        duration: effective,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              _SnackIcon(icon: icon, accent: effectiveAccent),
              const SizedBox(width: 10),
            ],
            Flexible(child: Text(message)),
          ],
        ),
      ),
      action: action,
    ),
  );
}

/// Attaches a dismiss timer to the snackbar content, covering the case where
/// the built-in auto-dismiss does not fire (animations off). Bound to the
/// content's state, so dispose cancels it — no dangling timer in tests.
class _AutoDismiss extends StatefulWidget {
  const _AutoDismiss({required this.child, required this.duration});

  final Widget child;
  final Duration duration;

  @override
  State<_AutoDismiss> createState() => _AutoDismissState();
}

class _AutoDismissState extends State<_AutoDismiss> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Slightly after the snackbar duration: gives the built-in timer priority
    // but steps in when it does not fire.
    _timer = Timer(
      widget.duration + const Duration(milliseconds: 400),
      () {
        // removeCurrentSnackBar (not hideCurrentSnackBar): removes IMMEDIATELY
        // without exit animation, so it is gone even with animations off.
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar(
            reason: SnackBarClosedReason.timeout,
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Small icon that pops in on appearance (easeOutBack scale).
class _SnackIcon extends StatelessWidget {
  const _SnackIcon({required this.icon, required this.accent});

  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.5, end: 1.0),
      duration: motionDuration(context, const Duration(milliseconds: 260)),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Transform.scale(scale: t, child: child),
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 15, color: accent),
      ),
    );
  }
}
