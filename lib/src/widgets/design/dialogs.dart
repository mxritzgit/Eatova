import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import 'controls.dart';
import 'surfaces.dart' show HeadingSemantics;

/// Material route behavior with Eatova's scrim and reduced-motion preference.
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
    duration: motionDuration(context, const Duration(milliseconds: 200)),
    reverseDuration: motionDuration(context, const Duration(milliseconds: 150)),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  ),
);

/// A scrollable message with the decision kept in view. On short, keyboard-
/// constrained windows the actions join the scroll instead of overflowing.
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
        48;
    final pinActions = availableHeight >= 400;
    final compactText =
        media.size.width < 360 && media.textScaler.scale(14) > 21;
    final actionColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          actions[i],
        ],
      ],
    );
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        semanticLabel: title,
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        constraints: const BoxConstraints(maxWidth: 420),
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
                        size: 44,
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
                const SizedBox(height: 12),
                DefaultTextStyle(
                  style: AppType.ui(15, color: t.ink2, height: 1.5),
                  child: content,
                ),
                if (!pinActions) ...[const SizedBox(height: 24), actionColumn],
              ],
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.all(24),
        actions: pinActions
            ? [SizedBox(width: double.maxFinite, child: actionColumn)]
            : null,
      ),
    );
  }
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

/// Full-width, wrapping actions with the app's primary/soft-fill hierarchy.
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
  });

  final Key? buttonKey;
  final String label;
  final VoidCallback? onPressed;
  final bool secondary;
  final bool destructive;
  final bool autofocus;
  final bool busy;

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
    final foreground = widget.secondary ? t.ink : t.bg;
    final background = widget.secondary
        ? t.field
        : widget.destructive
        ? t.danger
        : t.ink;
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
              disabledBackgroundColor: widget.busy ? background : null,
              disabledForegroundColor: widget.busy ? foreground : null,
              minimumSize: Size(
                double.infinity,
                widget.secondary ? kButtonMinHeight : kPrimaryButtonHeight,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              textStyle: AppType.ui(15, weight: FontWeight.w700, height: 1.25),
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
                  Flexible(
                    child: Text(widget.label, textAlign: TextAlign.center),
                  ),
                ],
              )
            : Text(widget.label, textAlign: TextAlign.center),
      ),
    );
  }
}
