import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import 'controls.dart';

// ---------------------------------------------------------------------------
// SHEETS — scaffold, input field, handle and the opener.
//
// Geometry 1:1 from the design mock; colors from [AppTokens].
// ---------------------------------------------------------------------------

/// A bottom sheet's inside: title, line, fields, one action at the foot.
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    required this.actionLabel,
    this.destructive = false,
    this.onAction,
    this.actionEnabled = true,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final String actionLabel;
  final bool destructive;

  /// Defaults to closing: a sheet without its own action only confirms.
  final VoidCallback? onAction;

  /// Arms the action. Disabled means dimmed and deaf, not invisible.
  final bool actionEnabled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Scrollable, not just shrink-wrapping: a plain Column overflowed by
    // ~101 px at textScaler 2.0.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: AppType.display(
              24,
              color: destructive ? t.danger : t.ink,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: AppType.ui(12.5, color: t.ink2, height: 1.45)),
          const SizedBox(height: 18),
          ...children,
          const SizedBox(height: 20),
          // The SAME primary action as every screen foot (ink/bg, rButton):
          // a forest fill was 1.33:1 against `surf` in dark mode and gave the
          // app two primary-button languages. The button draws its own
          // disabled state, so no Opacity wrapper on top of it.
          PrimaryActionButton(
            label: actionLabel,
            destructive: destructive,
            onTap: actionEnabled
                ? (onAction ?? () => Navigator.of(context).maybePop())
                : null,
          ),
        ],
      ),
    );
  }
}

/// Outline of a [SheetField].
enum SheetFieldShape {
  /// [rControl] corners — the default for labelled form fields.
  capsule,

  /// Fully round ([rPill]) — search fields and inline number inputs.
  pill,
}

/// The borderless input capsule around ANY child (a TextField, a stepper row,
/// a search bar): [AppTokens.field] at rest, [AppTokens.fieldFocus] while
/// [focusNode] has focus (or [focused] is true), [AppTokens.fieldError] with
/// [error]; always [softShadow], never a hairline or ring.
///
/// This is the app-wide focus language — private capsules in screens should
/// wrap their field in this instead of picking surf/surf2/tile themselves.
/// Pass the same [focusNode] the inner TextField uses, or drive [focused]
/// yourself when the caller already tracks focus.
class FieldCapsule extends StatefulWidget {
  const FieldCapsule({
    super.key,
    required this.child,
    this.focusNode,
    this.focused,
    this.error = false,
    this.enabled = true,
    this.shape = SheetFieldShape.capsule,
    this.padding = const EdgeInsets.symmetric(horizontal: 15),
    this.constraints,
    this.shadow = true,
    this.alignment,
  });

  final Widget child;

  /// Listened to for the focus fill; ignored when [focused] is given.
  final FocusNode? focusNode;

  /// Explicit focus state for callers that track it themselves.
  final bool? focused;

  /// Error tint instead of the rest/focus fill.
  final bool error;

  /// Dims the capsule (0.55) — matches [SheetField.enabled].
  final bool enabled;

  final SheetFieldShape shape;
  final EdgeInsets padding;
  final BoxConstraints? constraints;

  /// `false` for capsules that already sit on a raised surface.
  final bool shadow;

  final AlignmentGeometry? alignment;

  @override
  State<FieldCapsule> createState() => _FieldCapsuleState();
}

class _FieldCapsuleState extends State<FieldCapsule> {
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _listen(widget.focusNode);
  }

  @override
  void didUpdateWidget(FieldCapsule old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode?.removeListener(_onFocus);
      _listen(widget.focusNode);
    }
  }

  void _listen(FocusNode? node) {
    node?.addListener(_onFocus);
    _hasFocus = node?.hasFocus ?? false;
  }

  void _onFocus() {
    final now = widget.focusNode?.hasFocus ?? false;
    if (now != _hasFocus) setState(() => _hasFocus = now);
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final focused = widget.focused ?? _hasFocus;
    final fill = widget.error
        ? t.fieldError
        : focused
            ? t.fieldFocus
            : t.field;
    final radius = widget.shape == SheetFieldShape.pill ? rPill : rControl;
    return Opacity(
      opacity: widget.enabled ? 1 : 0.55,
      child: AnimatedContainer(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
        curve: Curves.easeOut,
        constraints: widget.constraints,
        alignment: widget.alignment,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(radius),
          boxShadow: widget.shadow ? softShadow(t) : null,
        ),
        padding: widget.padding,
        child: widget.child,
      ),
    );
  }
}

/// Input field in sheet style: eyebrow label above a [FieldCapsule] with a
/// TextField inside. See [AppTokens.field] for the focus language.
class SheetField extends StatefulWidget {
  const SheetField({
    super.key,
    this.label,
    required this.hint,
    this.obscure = false,
    this.controller,
    this.enabled = true,
    this.keyboardType,
    this.onChanged,
    this.errorText,
    this.suffix,
    this.prefix,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
    this.inputFormatters,
    this.maxLines = 1,
    this.maxLength,
    this.shape = SheetFieldShape.capsule,
    this.textInputAction,
    this.onSubmitted,
    this.textAlign = TextAlign.start,
    this.textCapitalization = TextCapitalization.none,
    this.fieldKey,
    this.bottomGap = 12,
  });

  /// All-caps eyebrow above the capsule. `null` for fields that explain
  /// themselves (search) — then [semanticLabel] should carry the name.
  final String? label;

  final String hint;
  final bool obscure;

  /// The static design mock needs no controller; real sheets do.
  final TextEditingController? controller;

  final bool enabled;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  /// One [AppTokens.danger] line under the field; also tints the capsule.
  final String? errorText;

  /// Trailing / leading widget inside the capsule (clear button, icon).
  final Widget? suffix;
  final Widget? prefix;

  final bool autofocus;

  /// External focus node; without one the field owns (and disposes) its own.
  final FocusNode? focusNode;

  /// Spoken name of the field for screen readers.
  final String? semanticLabel;

  final List<TextInputFormatter>? inputFormatters;

  /// `null` grows without limit (multi-line notes).
  final int? maxLines;

  final int? maxLength;
  final SheetFieldShape shape;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final TextAlign textAlign;
  final TextCapitalization textCapitalization;

  /// Goes on the inner [TextField] (tests enter text by key).
  final Key? fieldKey;

  /// Space below the field; 0 for fields that sit in their own row.
  final double bottomGap;

  @override
  State<SheetField> createState() => _SheetFieldState();
}

class _SheetFieldState extends State<SheetField> {
  /// Only created without an external node; the same node goes to the
  /// TextField and to the capsule, which does the focus listening.
  FocusNode? _ownNode;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode());

  @override
  void dispose() {
    _ownNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasError = widget.errorText != null;

    Widget field = TextField(
      key: widget.fieldKey,
      controller: widget.controller,
      focusNode: _node,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      obscureText: widget.obscure,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      maxLines: widget.obscure ? 1 : widget.maxLines,
      maxLength: widget.maxLength,
      textInputAction: widget.textInputAction,
      textAlign: widget.textAlign,
      textCapitalization: widget.textCapitalization,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      cursorColor: t.accent,
      cursorOpacityAnimates: false,
      style: AppType.ui(14, color: t.ink),
      decoration: InputDecoration(
        // The capsule is drawn by the container; the theme's own fill and
        // outline must not draw a second field inside it.
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
        filled: false,
        isDense: true,
        counterText: '',
        contentPadding: const EdgeInsets.symmetric(vertical: 15),
        hintText: widget.hint,
        hintStyle: AppType.ui(14, color: t.ink2),
      ),
    );
    if (widget.semanticLabel != null) {
      field = Semantics(label: widget.semanticLabel, child: field);
    }

    return Padding(
      padding: EdgeInsets.only(bottom: widget.bottomGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (widget.label != null) ...<Widget>[
            Text(
              widget.label!.toUpperCase(),
              style: AppType.eyebrow(t.ink2, size: 9.5),
            ),
            const SizedBox(height: 7),
          ],
          FieldCapsule(
            focusNode: _node,
            error: hasError,
            enabled: widget.enabled,
            shape: widget.shape,
            child: Row(
              children: <Widget>[
                if (widget.prefix != null) ...<Widget>[
                  widget.prefix!,
                  const SizedBox(width: 8),
                ],
                Expanded(child: field),
                if (widget.suffix != null) widget.suffix!,
              ],
            ),
          ),
          if (hasError) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              widget.errorText!,
              style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
            ),
          ],
        ],
      ),
    );
  }
}

/// The drag handle sheets draw themselves when they cannot use Material's
/// (`dragHandle: false` in [showEatovaSheet], e.g. under a discard guard).
/// ONE geometry app-wide: 40 x 4, [AppTokens.line] — the same as the themed
/// Material handle.
///
/// Decoration only ([ExcludeSemantics]): Material's handle also carries a
/// "dismiss" semantics action, and that goes away with `dragHandle: false`.
/// A sheet without it must offer another close path a screen reader can
/// reach (close button, the sheet action, or the barrier).
class SheetHandle extends StatelessWidget {
  const SheetHandle({
    super.key,
    this.padding = const EdgeInsets.only(top: 10, bottom: 6),
  });

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Decoration only; a screen reader gains nothing from "handle".
    return ExcludeSemantics(
      child: Padding(
        padding: padding,
        child: Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: t.line,
              borderRadius: BorderRadius.circular(rPill),
            ),
          ),
        ),
      ),
    );
  }
}

/// Intercepts the drag-down dismiss of a modal bottom sheet.
///
/// A [PopScope] alone covers only half of it: system back and a barrier tap go
/// through `Navigator.maybePop` (which asks the pop disposition), while a drag
/// goes `BottomSheet._handleDragEnd` -> `onClosing` -> `Navigator.pop` and asks
/// nobody. The only lever from inside the sheet is the gesture arena — a
/// vertical drag recognizer in the builder child sits below
/// `_BottomSheetGestureDetector` and wins. Scrollables sit below this guard and
/// stay unaffected.
///
/// Open the sheet with `dragHandle: false` ([showEatovaSheet]) and draw a
/// [SheetHandle] instead: a pull on Material's own handle pops via the same
/// `onClosing` path, above this guard.
///
/// With [active] false no recognizer is registered at all, so a sheet with
/// nothing to lose still drags away.
///
/// Two older private twins exist (`recipe_create_sheet.dart`,
/// `meal_widgets_adjust.dart`); they predate this one and are unchanged.
class SheetDismissGuard extends StatefulWidget {
  const SheetDismissGuard({
    super.key,
    required this.active,
    required this.onDismissAttempt,
    required this.child,
  });

  final bool active;
  final VoidCallback onDismissAttempt;
  final Widget child;

  @override
  State<SheetDismissGuard> createState() => _SheetDismissGuardState();
}

class _SheetDismissGuardState extends State<SheetDismissGuard> {
  /// Minimum downward distance counted as "close". Deliberately small: the
  /// guard swallows the gesture either way, the only question is whether the
  /// user gets an answer.
  static const double _closeIntentPx = 32;

  /// Fling threshold, mirroring `_kMinFlingVelocity` from bottom_sheet.dart.
  static const double _flingVelocity = 700;

  double _dy = 0;

  void _onStart(DragStartDetails details) => _dy = 0;

  void _onUpdate(DragUpdateDetails details) => _dy += details.primaryDelta ?? 0;

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dy > _closeIntentPx || velocity > _flingVelocity) {
      widget.onDismissAttempt();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return GestureDetector(
      // Without translucent, gaps between children stay uncovered.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

/// Gap between the top safe area and a sheet's top edge.
const double kSheetTopGap = 12;

/// Floor for [sheetMaxHeight], so a small screen or tall keyboard cannot
/// collapse the header into a few pixels.
const double kSheetMinHeight = 320;

/// The tallest a sheet may be without sliding under the top safe area, never
/// below [kSheetMinHeight].
///
/// Not a fixed fraction: that ignored the keyboard, so the route clamped the
/// sheet under the status bar and hid its header. Sheets in the tree use
/// [sheetMaxHeightOf].
double sheetMaxHeight(MediaQueryData mediaQuery) {
  final available = mediaQuery.size.height -
      mediaQuery.viewPadding.top -
      mediaQuery.viewInsets.bottom -
      kSheetTopGap;
  return math.max(kSheetMinHeight, available);
}

/// [sheetMaxHeight] for a sheet's build context. Inside
/// `showModalBottomSheet`'s builder `viewPadding.top` is already 0, so the
/// device safe area comes from the [FlutterView]; `useSafeArea: true` zeroes
/// it the same way and eats the gap.
double sheetMaxHeightOf(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  final viewTop = MediaQueryData.fromView(View.of(context)).viewPadding.top;
  if (viewTop <= mediaQuery.viewPadding.top) return sheetMaxHeight(mediaQuery);
  return sheetMaxHeight(
    mediaQuery.copyWith(
      viewPadding: mediaQuery.viewPadding.copyWith(top: viewTop),
    ),
  );
}

/// Opens [sheet] as an Eatova bottom sheet: scroll-controlled, [rSheet] cap,
/// keyboard inset, the safe-area cap ([sheetMaxHeight]) and the app scrim.
///
/// [dragHandle] false skips Material's handle — needed under a discard guard,
/// because a drag on the handle pops via `BottomSheet._handleDragEnd` and
/// bypasses `PopScope`; the sheet then draws a [SheetHandle] itself.
/// [transparentShell] hands the shell to the sheet (camera/scanner sheets
/// that paint their own surface). [barrierColor] defaults to
/// [AppTokens.scrim].
Future<T?> showEatovaSheet<T>(
  BuildContext context,
  Widget sheet, {
  bool dragHandle = true,
  bool transparentShell = false,
  Color? barrierColor,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
}) {
  final t = context.t;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    backgroundColor: transparentShell ? Colors.transparent : t.bg,
    barrierColor: barrierColor ?? t.scrim,
    showDragHandle: dragHandle,
    shape: transparentShell
        ? null
        : const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
          ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        // `showDragHandle` adds a `kMinInteractiveDimension` pad ABOVE the
        // builder content, so it is subtracted here. Without the cap, long
        // content fills the screen up under the status bar.
        constraints: BoxConstraints(
          maxHeight: sheetMaxHeightOf(sheetContext) -
              (dragHandle ? kMinInteractiveDimension : 0),
        ),
        child: sheet,
      ),
    ),
  );
}
