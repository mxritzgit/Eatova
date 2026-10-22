import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import 'controls.dart';
import 'surfaces.dart' show HeadingSemantics;

/// Material route behavior with Eatova's scrim and reduced-motion preference.
/// The route fades; [EatovaDialog] adds the short rise of the decision card.
Future<T?> showEatovaDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  builder: builder,
  barrierDismissible: barrierDismissible,
  barrierColor: context.t.scrim,
  animationStyle: AnimationStyle(
    duration: motionDuration(context, const Duration(milliseconds: 240)),
    reverseDuration: motionDuration(context, const Duration(milliseconds: 150)),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  ),
);

/// Room around the decision card: the page's 20 px gutter at the sides and a
/// 12 px lift off the safe area (or the keyboard) at the bottom.
const EdgeInsets _kCardInset = EdgeInsets.fromLTRB(20, 24, 20, 12);

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

/// The app's decision card: a bottom-anchored [rSheet] card in the sheets'
/// language (surf, 1 px lineStrong edge) that rises a few pixels while the
/// route fades in. A scrollable message keeps the decision in view; on short,
/// keyboard-constrained windows the actions join the scroll instead of
/// overflowing, and so do three actions on a narrow phone with large text.
/// Material retains route naming, focus traversal and safe-area placement.
class EatovaDialog extends StatelessWidget {
  const EatovaDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.icon,
    this.destructive = false,
    this.busy = false,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;
  final IconData? icon;
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
    final actionColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          actions[i],
        ],
      ],
    );
    return PopScope(
      canPop: !busy,
      child: _DecisionCardRise(
        child: AlertDialog(
          semanticLabel: title,
          scrollable: true,
          alignment: Alignment.bottomCenter,
          insetPadding: _kCardInset,
          constraints: const BoxConstraints(maxWidth: 420),
          backgroundColor: t.surf,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          // The same edge [showEatovaSheet] draws, closed on all four sides.
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rSheet),
            side: BorderSide(color: t.lineStrong),
          ),
          contentPadding: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          content: Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, pinActions ? 0 : 24),
            child: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (icon != null && !compactText) ...[
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: ExcludeSemantics(
                        child: IconTile(
                          icon: icon!,
                          color: destructive ? t.danger : t.accent,
                          size: 48,
                          glyphSize: 22,
                          radius: rControl,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  HeadingSemantics(
                    level: 1,
                    child: Text(
                      title,
                      style: AppType.display(
                        compactText ? 20 : 24,
                        weight: FontWeight.w700,
                        color: t.ink,
                        height: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DefaultTextStyle(
                    style: AppType.ui(15, color: t.ink2, height: 1.5),
                    child: content,
                  ),
                  if (!pinActions) ...[
                    const SizedBox(height: 24),
                    actionColumn,
                  ],
                ],
              ),
            ),
          ),
          actionsPadding: const EdgeInsets.all(24),
          actions: pinActions
              ? [SizedBox(width: double.maxFinite, child: actionColumn)]
              : null,
        ),
      ),
    );
  }
}

/// The card's entrance: rises 6 % of the dialog area while the route fades
/// in (ease-out), sinks back on the way out (ease-in). Under reduced motion
/// the route has no duration and the card stays put. The transition widget
/// stays mounted in both cases, so toggling the setting keeps field state.
class _DecisionCardRise extends StatefulWidget {
  const _DecisionCardRise({required this.child});

  final Widget child;

  @override
  State<_DecisionCardRise> createState() => _DecisionCardRiseState();
}

class _DecisionCardRiseState extends State<_DecisionCardRise> {
  static final Tween<Offset> _rise = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  );

  Animation<double>? _route;
  CurvedAnimation? _curve;
  Animation<Offset> _offset = const AlwaysStoppedAnimation(Offset.zero);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (route == _route) return;
    _curve?.dispose();
    _route = route;
    _curve = route == null
        ? null
        : CurvedAnimation(
            parent: route,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
    _offset = _curve == null
        ? const AlwaysStoppedAnimation(Offset.zero)
        : _rise.animate(_curve!);
  }

  @override
  void dispose() {
    _curve?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SlideTransition(
    position: reducedMotion(context)
        ? const AlwaysStoppedAnimation(Offset.zero)
        : _offset,
    child: widget.child,
  );
}

/// A confirmation only reports the explicit choice; its caller owns mutation.
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
  final bool destructive;
  final bool busy;
  final String? busyLabel;

  @override
  Widget build(BuildContext context) => EatovaDialog(
    title: title,
    content: Text(body),
    icon: icon,
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
        // Keyboard confirmation defaults to the safe way out.
        autofocus: true,
      ),
    ],
  );
}

/// Full-width, wrapping actions in the sheets' button language:
/// - primary: the [PrimaryActionButton] pill (54 px, accent fill, 15/800);
/// - [destructive] primary: the same pill in `danger` with a `bg` label;
/// - [secondary]: the 48 px safe way out on a `field` fill with an `ink`
///   label;
/// - [secondary] and [destructive]: a soft danger tint with a `danger` label
///   ([SoftPillTone.danger]'s pair), for a risky alternative next to a primary.
///
/// A disabled action dims its own fill and label (the [PrimaryActionButton]
/// recipe), so it never changes hue when it arms. Busy keeps full colour.
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

  @override
  State<EatovaDialogAction> createState() => _EatovaDialogActionState();
}

class _EatovaDialogActionState extends State<EatovaDialogAction> {
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

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (background, foreground) = switch ((
      widget.secondary,
      widget.destructive,
    )) {
      (true, true) => (t.danger.withValues(alpha: 0.12), t.danger),
      (true, false) => (t.field, t.ink),
      (false, true) => (t.danger, t.bg),
      (false, false) => (t.accentFill, t.onAccentFill),
    };
    final label = Text(widget.label, textAlign: TextAlign.center);
    return Semantics(
      liveRegion: widget.busy,
      child: FilledButton(
        key: widget.buttonKey,
        autofocus: widget.autofocus,
        onPressed: widget.busy ? null : widget.onPressed,
        style:
            FilledButton.styleFrom(
              backgroundColor: background,
              foregroundColor: foreground,
              disabledBackgroundColor: widget.busy
                  ? background
                  : background.withValues(
                      alpha: background.a * kDisabledFillAlpha,
                    ),
              disabledForegroundColor: widget.busy
                  ? foreground
                  : foreground.withValues(alpha: foreground.a * 0.8),
              minimumSize: Size(
                double.infinity,
                widget.secondary ? kButtonMinHeight : kPrimaryButtonHeight,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              textStyle: AppType.ui(
                15,
                weight: widget.secondary ? FontWeight.w700 : FontWeight.w800,
                height: 1.25,
              ),
            ).copyWith(
              side: WidgetStateProperty.resolveWith(
                (states) => BorderSide(
                  color:
                      states.contains(WidgetState.focused) &&
                          FocusManager.instance.highlightMode ==
                              FocusHighlightMode.traditional
                      ? foreground
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
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
    );
  }
}
