import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import 'controls.dart';
import 'surfaces.dart' show HeadingSemantics;

// ---------------------------------------------------------------------------
// DECISION CARDS — depth and light, with a pulse (polish 2026-10-25).
//
// A decision floats: a lit surface (`surfLit` falling off into `surf`) on a
// contact and an ambient shadow, never a hairline. It rises out of the
// bottom and settles on a soft spring while the scrim fades; its content
// follows a beat later, the actions last, and its glyph acts the decision
// out once (the sign-out arrow leaves its door). One lit action casts its
// colour; the safe way out stays quiet. Nothing loops. Reduced motion:
// everything at rest on the first frame, with the same widget tree.
// ---------------------------------------------------------------------------

/// How far the card rises while it lands, and sinks while it leaves.
const double _kRiseDistance = 36;
const double _kSinkDistance = 16;

/// Route behavior with Eatova's scrim and reduced-motion preference. The
/// route fades in over the first part of [kMotionDecisionIn] and out over
/// [kMotionDecisionOut]; [EatovaDialog] rides the same animation with its
/// spring, its content stagger and its glyph.
Future<T?> showEatovaDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    _DecisionRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      barrierColor: context.t.scrim,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      animationStyle: AnimationStyle(
        duration: motionDuration(context, kMotionDecisionIn),
        reverseDuration: motionDuration(context, kMotionDecisionOut),
        // The card's opacity: whole within the first 30 % (140 ms), while
        // the spring still carries it, so the page never shows through a
        // half-faded card. The scrim fades on its own over the whole entry.
        curve: const Interval(0, 0.3, curve: Curves.easeOutCubic),
        reverseCurve: Curves.easeInCubic,
      ),
    ),
  );
}

/// [showDialog]'s [DialogRoute] with the exit its style names: DialogRoute
/// reuses the entrance duration for the way out, so the card would leave as
/// slowly as it arrives.
class _DecisionRoute<T> extends DialogRoute<T> {
  _DecisionRoute({
    required super.context,
    required super.builder,
    required super.barrierDismissible,
    required super.barrierColor,
    required super.themes,
    required AnimationStyle animationStyle,
  }) : _exit = animationStyle.reverseDuration,
       super(
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
         animationStyle: animationStyle,
       );

  final Duration? _exit;

  @override
  Duration get reverseTransitionDuration => _exit ?? transitionDuration;
}

/// Room around the decision card: 12 px at the sides, so the card reads as
/// a surface lifted off the whole screen rather than a box on the page, and
/// a 12 px lift off the safe area (or the keyboard) at the bottom.
const EdgeInsets _kCardInset = EdgeInsets.fromLTRB(12, 24, 12, 12);

/// "Discard changes?" for every way of closing a filled form: the decision
/// card with the food copy, the edit-off glyph and the shared keys as
/// defaults. Returns `true` to discard; any dismissal keeps editing.
///
/// `barrierDismissible` stays true: a tap beside the card means "keep
/// editing", and the card's own barrier swallows it, so the sheet or page it
/// protects never sees that tap.
Future<bool> confirmDiscardChanges(
  BuildContext context, {
  required String body,
  String? title,
  String? confirmLabel,
  String? keepLabel,
  IconData icon = Icons.edit_off_rounded,
  Key? dialogKey,
  Key? confirmKey,
  Key? keepKey,
}) async {
  final l10n = context.l10n;
  final discard = await showEatovaDialog<bool>(
    context: context,
    builder: (dialogContext) => EatovaConfirmDialog(
      key: dialogKey ?? const ValueKey('discard-changes-dialog'),
      title: title ?? l10n.foodDiscardChangesTitle,
      body: body,
      icon: icon,
      destructive: true,
      cancelKey: keepKey ?? const ValueKey('discard-changes-cancel'),
      cancelLabel: keepLabel ?? l10n.foodDiscardChangesKeepEditing,
      onCancel: () => Navigator.of(dialogContext).pop(false),
      confirmKey: confirmKey ?? const ValueKey('discard-changes-confirm'),
      confirmLabel: confirmLabel ?? l10n.foodDiscardChangesConfirm,
      onConfirm: () => Navigator.of(dialogContext).pop(true),
    ),
  );
  return discard ?? false;
}

/// The app's decision card: a bottom-anchored, lit [rSheet] surface that
/// floats on its own shadow (see the file header). A scrollable message
/// keeps the decision in view; on short, keyboard-constrained windows the
/// actions join the scroll instead of overflowing, and so do three actions
/// on a narrow phone with large text. Material's [Dialog] keeps focus
/// traversal and safe-area placement; the route semantics are set here.
class EatovaDialog extends StatelessWidget {
  const EatovaDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.icon,
    this.lead,
    this.destructive = false,
    this.busy = false,
  });

  final String title;
  final Widget content;

  /// Stacked full width in the order given: the lit action first, then any
  /// secondary one, the quiet way out last.
  final List<Widget> actions;

  /// The glyph of the [DecisionMedallion] above the title.
  final IconData? icon;

  /// What the decision is about, in place of the [icon] medallion: the
  /// account a sign-out leaves ([DecisionAccountCapsule]), for instance.
  final Widget? lead;
  final bool destructive;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final media = MediaQuery.of(context);
    final availableHeight =
        media.size.height -
        media.viewInsets.bottom -
        media.padding.vertical -
        _kCardInset.vertical;
    final compactText =
        media.size.width < 360 && media.textScaler.scale(14) > 21;
    // Three pinned actions at 320 px and large text left the message a strip
    // its title filled; they join the scroll then, after the message.
    final pinActions =
        availableHeight >= 400 && !(compactText && actions.length > 2);
    final actionColumn = _ContentArrival(
      at: 0.30,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            actions[i],
          ],
        ],
      ),
    );
    // The medallion is decoration: with large text on a narrow phone it
    // gives its room to the decision itself. A [lead] names what the decision
    // is about (the account a sign-out leaves) and stays.
    final Widget? mark =
        lead ??
        (compactText || icon == null
            ? null
            : Align(
                alignment: AlignmentDirectional.centerStart,
                child: DecisionMedallion(icon: icon!, destructive: destructive),
              ));
    final message = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mark != null) ...[
          _ContentArrival(at: 0.10, child: mark),
          const SizedBox(height: 18),
        ],
        _ContentArrival(
          at: 0.18,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HeadingSemantics(
                level: 1,
                child: Text(
                  title,
                  style: AppType.display(
                    compactText ? 20 : 25,
                    weight: FontWeight.w800,
                    color: t.ink,
                    height: 1.12,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              DefaultTextStyle(
                style: AppType.ui(15, color: t.ink2, height: 1.5),
                child: content,
              ),
            ],
          ),
        ),
      ],
    );
    // The text column sits 8 px inside the actions, which reach wider.
    final body = pinActions
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 26, 24, 0),
                  child: message,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                child: actionColumn,
              ),
            ],
          )
        : SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 26, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: message,
                ),
                const SizedBox(height: 24),
                actionColumn,
              ],
            ),
          );
    return PopScope(
      canPop: !busy,
      child: _DecisionCardRise(
        child: Dialog(
          alignment: Alignment.bottomCenter,
          insetPadding: _kCardInset,
          constraints: const BoxConstraints(maxWidth: 420),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rSheet),
          ),
          semanticsRole: SemanticsRole.alertDialog,
          // What AlertDialog said for the route: a named, scoped dialog.
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            namesRoute: true,
            label: title,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: litSurface(t),
                borderRadius: BorderRadius.circular(rSheet),
                boxShadow: decisionShadow(t),
              ),
              // Ink of the content paints above the lit fill, not under it.
              child: Material(type: MaterialType.transparency, child: body),
            ),
          ),
        ),
      ),
    );
  }
}

/// The glyph of a decision: a 46 px disc on its own contact shadow, lit
/// with the accent tint, the glyph in accent. A destructive decision keeps
/// the disc neutral (`tile`) with a danger glyph: a danger tint on the dark
/// card mixed a muddy brown; the glyph and the lit action carry the warning.
///
/// It pops in as its route arrives; with [act] the sign-out glyph acts the
/// decision out once (the arrow slides out of its door). The decision card
/// and [SheetScaffold] share it; [ground] is the surface it sits on (the
/// card's lit top by default).
class DecisionMedallion extends StatelessWidget {
  const DecisionMedallion({
    super.key,
    required this.icon,
    this.destructive = false,
    this.ground,
    this.act = true,
  });

  final IconData icon;
  final bool destructive;
  final Color? ground;
  final bool act;

  static const Interval _pop = Interval(0.10, 0.65, curve: kSpringPop);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final tone = destructive ? t.danger : t.accentText;
    final glyph = act && icon == Icons.logout_rounded
        ? _ActingExitGlyph(size: 21, color: tone)
        : Icon(icon, size: 21, color: tone);
    return ExcludeSemantics(
      child: _RouteProgress(
        builder: (context, progress, leaving, child) => Transform.scale(
          scale: 0.6 + 0.4 * (leaving ? 1 : _pop.transform(progress)),
          child: child,
        ),
        child: Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color.alphaBlend(
              destructive ? t.tile : t.accentTintStrong,
              ground ?? t.surfLit,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: t.shadowTint,
                blurRadius: 8,
                offset: const Offset(0, 3),
                spreadRadius: -3,
              ),
            ],
          ),
          child: glyph,
        ),
      ),
    );
  }
}

/// The account a decision acts on, as one capsule above the title: the lit
/// initial, [label] ("Angemeldet als") over the [account] address, and the
/// exit glyph whose arrow leaves its door once as the card arrives ("you
/// are leaving this account"). One semantics node; the glyph turns `danger`
/// with [destructive]. The sign-out card's lead.
class DecisionAccountCapsule extends StatelessWidget {
  const DecisionAccountCapsule({
    super.key,
    required this.label,
    required this.account,
    this.destructive = false,
  });

  final String label;
  final String account;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final initial = account.isEmpty
        ? ''
        : account.characters.first.toUpperCase();
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
        decoration: BoxDecoration(
          color: Color.alphaBlend(t.tile, t.surfLit),
          borderRadius: BorderRadius.circular(rPill),
        ),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.accentFill,
                  shape: BoxShape.circle,
                  boxShadow: castLight(t, t.accentGlow),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    initial,
                    style: AppType.display(
                      17,
                      weight: FontWeight.w800,
                      color: t.onAccentFill,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppType.ui(
                      12,
                      weight: FontWeight.w600,
                      color: t.ink2,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    account,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      15,
                      weight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            ExcludeSemantics(
              child: _ActingExitGlyph(
                size: 20,
                color: destructive ? t.danger : t.accentText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One consequence of a decision: an 18 px glyph in its [color] (`success`
/// kept safe, `accentText` waiting, `danger` lost, `ink2` unknown) beside
/// the sentence in `ink2`. Stack them in [DecisionConsequences].
class DecisionConsequence extends StatelessWidget {
  const DecisionConsequence({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Centres the glyph on the first line at any text scale.
    final line = MediaQuery.textScalerOf(context).scale(14.5) * 1.45;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: EdgeInsets.only(top: math.max(0, (line - 18) / 2)),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: AppType.ui(14.5, color: t.ink2, height: 1.45),
          ),
        ),
      ],
    );
  }
}

/// A decision's message as one line per consequence, 12 px apart.
class DecisionConsequences extends StatelessWidget {
  const DecisionConsequences({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: 12),
        children[i],
      ],
    ],
  );
}

/// The enclosing route's entrance as raw progress (0 → 1) for the pieces
/// that ride it, and whether the route is leaving. Once the route has
/// arrived the progress stays 1 (a dragged sheet does not shrink its glyph
/// again). Outside a route and under reduced motion it is 1 from the first
/// frame; the tree is the same either way.
class _RouteProgress extends StatefulWidget {
  const _RouteProgress({required this.builder, this.child});

  final Widget Function(
    BuildContext context,
    double progress,
    bool leaving,
    Widget? child,
  )
  builder;
  final Widget? child;

  @override
  State<_RouteProgress> createState() => _RouteProgressState();
}

class _RouteProgressState extends State<_RouteProgress> {
  bool _arrived = false;

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context)?.animation;
    final Animation<double> animation = route == null || reducedMotion(context)
        ? kAlwaysCompleteAnimation
        : route;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final leaving = animation.status == AnimationStatus.reverse;
        if (animation.isCompleted) _arrived = true;
        final progress = _arrived && !leaving ? 1.0 : animation.value;
        return widget.builder(context, progress, leaving, child);
      },
      child: widget.child,
    );
  }
}

/// The card's entrance: rises [_kRiseDistance] px and grows from 97 %
/// (anchored at the bottom) on [kSpringSettle], so it lands a hair past
/// rest and settles; on the way out it sinks [_kSinkDistance] px.
class _DecisionCardRise extends StatelessWidget {
  const _DecisionCardRise({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _RouteProgress(
    builder: (context, progress, leaving, child) {
      if (leaving) {
        final v = Curves.easeInCubic.transform(progress);
        return Transform.translate(
          offset: Offset(0, _kSinkDistance * (1 - v)),
          child: Transform.scale(
            scale: 1,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        );
      }
      final v = kSpringSettle.transform(progress);
      return Transform.translate(
        offset: Offset(0, _kRiseDistance * (1 - v)),
        child: Transform.scale(
          scale: 0.97 + 0.03 * v,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      );
    },
    child: child,
  );
}

/// Content that arrives a beat after the card: from [at] of the route it
/// rises 10 px on [kSpringSettle] and fades in. On the way out it holds,
/// so a closing card never flickers apart. Screen readers find it at once.
class _ContentArrival extends StatelessWidget {
  const _ContentArrival({required this.at, required this.child});

  /// Where in the route's entrance this piece starts (0…1).
  final double at;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final rise = Interval(
      at,
      (at + 0.55).clamp(0.0, 1.0),
      curve: kSpringSettle,
    );
    final fade = Interval(
      at,
      (at + 0.3).clamp(0.0, 1.0),
      curve: Curves.easeOut,
    );
    return _RouteProgress(
      builder: (context, progress, leaving, child) {
        final p = leaving ? 1.0 : progress;
        return Opacity(
          opacity: fade.transform(p).clamp(0.0, 1.0),
          alwaysIncludeSemantics: true,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - rise.transform(p))),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// The sign-out glyph acting once: the door stays, the arrow slides out of
/// it and fades in as the route arrives. Decorative.
class _ActingExitGlyph extends StatelessWidget {
  const _ActingExitGlyph({required this.size, required this.color});

  final double size;
  final Color color;

  static const Interval _act = Interval(0.35, 1, curve: kSpringPop);

  @override
  Widget build(BuildContext context) => _RouteProgress(
    builder: (context, progress, leaving, _) => CustomPaint(
      size: Size.square(size),
      painter: _ExitGlyphPainter(
        color: color,
        arrow: leaving ? 1 : _act.transform(progress),
      ),
    ),
  );
}

/// The sign-out glyph in two parts on the 24-unit icon grid: the door
/// stays, the arrow travels 6 units out of it ([arrow] 0 inside and clear,
/// 1 at rest; the spring overshoots a little).
class _ExitGlyphPainter extends CustomPainter {
  const _ExitGlyphPainter({required this.color, required this.arrow});

  final Color color;
  final double arrow;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    Paint stroke(Color tone) => Paint()
      ..color = tone
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(11 * s, 4 * s)
        ..lineTo(7.5 * s, 4 * s)
        ..quadraticBezierTo(4.5 * s, 4 * s, 4.5 * s, 7 * s)
        ..lineTo(4.5 * s, 17 * s)
        ..quadraticBezierTo(4.5 * s, 20 * s, 7.5 * s, 20 * s)
        ..lineTo(11 * s, 20 * s),
      stroke(color),
    );
    final shown = arrow.clamp(0.0, 1.0);
    if (shown <= 0) return;
    canvas.save();
    canvas.translate((arrow - 1) * 6 * s, 0);
    canvas.drawPath(
      Path()
        ..moveTo(10 * s, 12 * s)
        ..lineTo(20 * s, 12 * s)
        ..moveTo(16.5 * s, 8.5 * s)
        ..lineTo(20 * s, 12 * s)
        ..lineTo(16.5 * s, 15.5 * s),
      stroke(color.withValues(alpha: color.a * shown)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ExitGlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.arrow != arrow;
}

/// A confirmation only reports the explicit choice; its caller owns mutation.
/// The confirm is lit (lit destructive with [destructive]); the cancel is
/// the quiet, autofocused way out.
class EatovaConfirmDialog extends StatelessWidget {
  const EatovaConfirmDialog({
    super.key,
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.onConfirm,
    required this.onCancel,
    this.confirmKey,
    this.cancelKey,
    this.icon,
    this.lead,
    this.destructive = false,
    this.busy = false,
    this.busyLabel,
  }) : assert(!busy || busyLabel != null);

  final String title;
  final String body;
  final String confirmLabel;
  final String cancelLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final Key? confirmKey;
  final Key? cancelKey;
  final IconData? icon;

  /// See [EatovaDialog.lead].
  final Widget? lead;
  final bool destructive;
  final bool busy;
  final String? busyLabel;

  @override
  Widget build(BuildContext context) => EatovaDialog(
    title: title,
    content: Text(body),
    icon: icon,
    lead: lead,
    destructive: destructive,
    busy: busy,
    actions: [
      EatovaDialogAction(
        buttonKey: confirmKey,
        label: busy ? busyLabel! : confirmLabel,
        onPressed: busy ? null : onConfirm,
        destructive: destructive,
        busy: busy,
      ),
      EatovaDialogAction(
        buttonKey: cancelKey,
        label: cancelLabel,
        onPressed: busy ? null : onCancel,
        secondary: true,
        quiet: true,
        // Keyboard confirmation defaults to the safe way out.
        autofocus: true,
      ),
    ],
  );
}

/// Full-width, wrapping actions in the depth-and-light language:
/// - lit (default): the accent pill (54 px, 15/800) casting `accentGlow`
///   onto the card, sinking into it on a press;
/// - lit [destructive]: `dangerFill` with an `onDangerFill` label, casting
///   a red light;
/// - [secondary]: a flush alternative on `field` with an `ink` label, 54 px;
/// - [secondary] and [destructive]: the soft danger pair (danger at 12 %),
///   a risky alternative next to a primary;
/// - [quiet]: the safe way out, no fill at rest (48 px, `inkSoft` 15/700);
///   `softFill` under a finger, `field` with an `ink` label under keyboard
///   focus.
///
/// A locked lit action is "not yet": its own accent at [kLockedFillAlpha]
/// with a dimmed `accentText` label and no light. Busy keeps full colour.
/// Keyboard focus (traditional highlight mode) brightens a lit fill with
/// [kLitFocusOverlay], lays the label tone over the others and lifts a lit
/// action's light; never a ring. Haptics: a lit
/// destructive confirm gives a medium impact, a lit one a light impact.
class EatovaDialogAction extends StatefulWidget {
  const EatovaDialogAction({
    super.key,
    this.buttonKey,
    required this.label,
    required this.onPressed,
    this.secondary = false,
    this.destructive = false,
    this.autofocus = false,
    this.busy = false,
    this.icon,
    this.quiet = false,
  });

  final Key? buttonKey;
  final String label;
  final VoidCallback? onPressed;
  final bool secondary;
  final bool destructive;
  final bool autofocus;
  final bool busy;

  /// Optional 18 px glyph before the label.
  final IconData? icon;

  /// The quiet way out (a cancel, "später"). Explicit, never inferred.
  final bool quiet;

  @override
  State<EatovaDialogAction> createState() => _EatovaDialogActionState();
}

class _EatovaDialogActionState extends State<EatovaDialogAction> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_focusModeChanged);
  }

  void _focusModeChanged(FocusHighlightMode mode) => setState(() {});

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_focusModeChanged);
    super.dispose();
  }

  bool get _lit => !widget.secondary && !widget.quiet;

  void _press(VoidCallback onPressed) {
    if (_lit) {
      unawaited(
        widget.destructive
            ? HapticFeedback.mediumImpact()
            : HapticFeedback.lightImpact(),
      );
    }
    onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final quiet = widget.quiet;
    final lit = _lit;
    final enabled = widget.onPressed != null && !widget.busy;
    final locked = widget.onPressed == null && !widget.busy;
    final (Color fill, Color ink, Color? light) = quiet
        ? (t.softFill.withValues(alpha: 0), t.inkSoft, null)
        : switch ((widget.secondary, widget.destructive)) {
            (true, true) => (t.danger.withValues(alpha: 0.12), t.danger, null),
            (true, false) => (t.field, t.ink, null),
            (false, true) => (
              t.dangerFill,
              t.onDangerFill,
              t.dangerFill.withValues(alpha: 0.38),
            ),
            (false, false) => (t.accentFill, t.onAccentFill, t.accentGlow),
          };
    final (Color background, Color foreground) = !locked
        ? (fill, ink)
        : !lit
        ? (fill.withValues(alpha: fill.a * 0.6), ink.withValues(alpha: 0.45))
        : widget.destructive
        ? (t.danger.withValues(alpha: 0.12), t.danger.withValues(alpha: 0.55))
        : (
            t.accentFill.withValues(alpha: kLockedFillAlpha),
            t.accentText.withValues(alpha: kLockedLabelAlpha),
          );
    final keyboard =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final radius = BorderRadius.circular(rButton);
    final style =
        FilledButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: background,
          disabledForegroundColor: foreground,
          minimumSize: Size(
            double.infinity,
            quiet ? kButtonMinHeight : kPrimaryButtonHeight,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          textStyle: AppType.ui(
            15,
            weight: lit ? FontWeight.w800 : FontWeight.w700,
            height: 1.25,
          ),
          elevation: 0,
          shadowColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          shape: RoundedRectangleBorder(borderRadius: radius),
        ).copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (!quiet || locked) return background;
            if (keyboard && states.contains(WidgetState.focused)) {
              return t.field;
            }
            if (states.contains(WidgetState.pressed)) return t.softFill;
            return background;
          }),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                quiet &&
                    !locked &&
                    keyboard &&
                    states.contains(WidgetState.focused)
                ? t.ink
                : foreground,
          ),
          // The quiet action answers with its fill instead.
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (quiet) return Colors.transparent;
            if (states.contains(WidgetState.pressed)) {
              return foreground.withValues(alpha: 0.10);
            }
            if (keyboard && states.contains(WidgetState.focused)) {
              return lit
                  ? kLitFocusOverlay
                  : foreground.withValues(alpha: 0.16);
            }
            if (states.contains(WidgetState.hovered)) {
              return foreground.withValues(alpha: 0.05);
            }
            return Colors.transparent;
          }),
        );
    final label = Text(widget.label, textAlign: TextAlign.center);
    final onPressed = widget.onPressed;
    final lift = keyboard && _focused ? 1.4 : 1.0;
    return Semantics(
      liveRegion: widget.busy,
      child: PressScale(
        enabled: enabled,
        rebound: true,
        builder: light == null
            ? null
            : (context, press, child) => DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: castLight(
                    t,
                    light,
                    strength: locked ? 0 : lift,
                    press: press,
                  ),
                ),
                child: child,
              ),
        child: FilledButton(
          key: widget.buttonKey,
          autofocus: widget.autofocus,
          onFocusChange: (focused) => setState(() => _focused = focused),
          onPressed: widget.busy || onPressed == null
              ? null
              : () => _press(onPressed),
          style: style,
          child: widget.busy
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ExcludeSemantics(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(child: label),
                  ],
                )
              : widget.icon == null
              ? label
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(widget.icon, size: 18),
                    const SizedBox(width: 8),
                    Flexible(child: label),
                  ],
                ),
        ),
      ),
    );
  }
}
