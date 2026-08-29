import 'dart:async';
import 'dart:math' as math;

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

/// Alpha of the disc behind the glyph. Glyph and disc share one color, so the
/// disc IS the glyph's ground — the correction below has to know it.
const double _kSnackIconTint = 0.18;

/// Contrast floor for the glyph on that disc: WCAG 1.4.11 asks 3:1 for
/// graphical objects, plus a little headroom.
const double _kSnackIconMinContrast = 3.2;

/// Contrast ratio per WCAG 2.1 (1..21).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// A [tone] that stays legible on the toast.
///
/// The toast is [AppTokens.forest] in BOTH modes, so in the LIGHT palette the
/// signal tones sit dark on dark: neutral 2.05:1, warning 2.20:1, error
/// 2.15:1 on their own disc. The tone channel goes silent — error, warning and
/// a neutral notice look alike. (The message text is unaffected, it runs in
/// `onForest` at 12.28:1.)
///
/// [AppTokens.readableOnTint] is NOT the tool here: it mixes towards
/// [AppTokens.ink], right for a faint tint on a light card but the wrong
/// direction on this surface — in light mode it drives the same three tones
/// down to 1.31…1.38:1. So mix towards the toast's OWN text color instead,
/// and only as far as the floor needs: dark mode already passes and stays
/// untouched, light mode keeps as much hue as the floor allows (the four tones
/// stay ≥ 31 dE76 apart).
Color _legibleOnSnack(Color tone, Color ground, Color onGround) {
  bool holds(Color c) =>
      _contrast(
        c,
        Color.alphaBlend(c.withValues(alpha: _kSnackIconTint), ground),
      ) >=
      _kSnackIconMinContrast;
  if (holds(tone)) return tone;
  // Binary search on the mix. Monotonic: lightening the glyph lifts its disc
  // by only 18 % of the same step. 8 rounds ≈ 1/256, the color resolution.
  var lo = 0.0;
  var hi = 1.0;
  for (var i = 0; i < 8; i++) {
    final mid = (lo + hi) / 2;
    if (holds(Color.lerp(tone, onGround, mid)!)) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return Color.lerp(tone, onGround, hi)!;
}

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
  // A live sheet host wins over the caller's own messenger: the root one
  // paints UNDER a modal sheet's scrim, where an undo button looks alive but
  // is dead (review F3-02). Store toasts arrive with the home page context
  // and are redirected the same way.
  final host = SnackHost._topmost;
  final messenger = host?._messenger ?? ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.removeCurrentSnackBar();
  // The toast sits on the brand surface (snackBarTheme), so the icon takes the
  // lime accent, not the card accent, which would be invisible here. [accent]
  // stays as a direct override for surfaces that still pass a color. Whichever
  // it is, [_SnackIcon] lifts it onto that surface's contrast floor.
  final effectiveAccent = accent ?? _toneColor(context.t, tone);
  final effective = duration ?? (action != null ? kSnackAction : kSnackShort);
  final snackBar = SnackBar(
    duration: effective,
    // Keep the action on the text's row: Material's default wraps a button
    // wider than 25 % onto its own line, which makes an undo toast twice as
    // tall as the strip a [SnackHost] reserves for it. Messages here are
    // short; the text wraps before the action does.
    actionOverflowThreshold: 1,
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
  );
  if (host != null) {
    host._show(snackBar);
  } else {
    messenger.showSnackBar(snackBar);
  }
}

/// Toast surface INSIDE a modal sheet that stays open after actions (add-meal,
/// favorites).
///
/// Wraps the sheet content in its own [ScaffoldMessenger]. While a toast
/// shows, the host reserves a strip below the content and presents the toast
/// there on a transparent [Scaffold] — so it sits below the last row instead
/// of on it, and the content above stays tappable. Without a toast the strip
/// has no height and ignores pointers. While the host's route is on the
/// navigator it is the target of every [showAppSnack] — sheet-local and
/// store-emitted alike — so toasts land above the scrim. Nested hosts stack;
/// the topmost live one wins.
class SnackHost extends StatefulWidget {
  const SnackHost({super.key, required this.child});

  final Widget child;

  static final List<_SnackHostState> _hosts = <_SnackHostState>[];

  static _SnackHostState? get _topmost {
    for (final host in _hosts.reversed) {
      if (host._isLive) return host;
    }
    return null;
  }

  /// Is some sheet host currently the toast target? For tests that pin the
  /// routing without inspecting the tree.
  @visibleForTesting
  static bool get hasLiveHost => _topmost != null;

  /// Empties the registry — for tests whose tree is not unmounted between
  /// cases. Hosts unregister themselves in `dispose` otherwise.
  @visibleForTesting
  static void debugResetHosts() => _hosts.clear();

  @override
  State<SnackHost> createState() => _SnackHostState();
}

class _SnackHostState extends State<SnackHost> {
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  ModalRoute<dynamic>? _route;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _current;
  bool _visible = false;

  ScaffoldMessengerState? get _messenger => _messengerKey.currentState;

  /// Live only while the host's route is on the navigator: a popped sheet
  /// stays in the tree for its exit animation but must not catch toasts, and
  /// a host without a route is never a target.
  bool get _isLive => mounted && (_route?.isActive ?? false);

  @override
  void initState() {
    super.initState();
    SnackHost._hosts.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    assert(
      _route != null,
      'SnackHost needs a route (ModalRoute.of) to know when it stops being live',
    );
  }

  @override
  void dispose() {
    SnackHost._hosts.remove(this);
    super.dispose();
  }

  /// Presents [snackBar] and keeps the strip reserved until it has closed —
  /// the controller's `closed` future is the only lifecycle signal needed.
  void _show(SnackBar snackBar) {
    final messenger = _messenger;
    if (messenger == null) return;
    setState(() => _visible = true);
    final controller = messenger.showSnackBar(snackBar);
    _current = controller;
    controller.closed.then((_) {
      if (!mounted || !identical(_current, controller)) return;
      setState(() {
        _visible = false;
        _current = null;
      });
    });
  }

  /// Height reserved for the toast: two lines of snackbar text plus its
  /// 14 px vertical padding, the floating margins and some slack. An estimate
  /// on purpose — generous rather than exact, so the toast never lands on
  /// content. The action shares the text row (see [showAppSnack]).
  static double _toastReserve(BuildContext context) {
    final line = MediaQuery.textScalerOf(context).scale(13.5) * 1.5;
    return math.max(48.0, 2 * line + 28) + 24;
  }

  @override
  Widget build(BuildContext context) {
    final reserve = _visible ? _toastReserve(context) : 0.0;
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Stack(
        children: <Widget>[
          AnimatedPadding(
            duration:
                motionDuration(context, const Duration(milliseconds: 160)),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: reserve),
            child: widget.child,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: reserve,
            child: IgnorePointer(
              ignoring: !_visible,
              child: const Scaffold(
                backgroundColor: Colors.transparent,
                // The sheet already lifts itself above the keyboard.
                resizeToAvoidBottomInset: false,
                body: SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }
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
    // The ground comes from the theme rather than from a token guess, so the
    // math follows if the toast surface is ever repainted.
    final snackTheme = Theme.of(context).snackBarTheme;
    final ground = snackTheme.backgroundColor ?? context.t.forest;
    final onGround = snackTheme.contentTextStyle?.color ?? context.t.onForest;
    final tone = _legibleOnSnack(accent, ground, onGround);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.5, end: 1.0),
      duration: motionDuration(context, const Duration(milliseconds: 260)),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Transform.scale(scale: t, child: child),
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: tone.withValues(alpha: _kSnackIconTint),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 15, color: tone),
      ),
    );
  }
}
