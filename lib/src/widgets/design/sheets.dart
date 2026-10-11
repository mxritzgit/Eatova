import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import 'controls.dart';
import 'surfaces.dart';

// ---------------------------------------------------------------------------
// SHEETS — header, scaffold, input field, handle and the opener.
//
// Geometry 1:1 from the design mock; colors from [AppTokens].
// ---------------------------------------------------------------------------

/// The ONE close control of a sheet header: a 44 px [AppTokens.surf] disc
/// with a 1 px [AppTokens.lineStrong] ring and an [AppTokens.inkMuted] glyph,
/// drawn inside Material's 48 px touch target — the Food tab's round header
/// button. The ring keeps it visible on the sheet ground in light mode,
/// where the old `surf2` disc measured 1.05:1.
///
/// A null [onTap] renders the disabled state (e.g. while saving).
class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({
    super.key,
    required this.onTap,
    this.buttonKey,
    this.tooltip,
    this.icon = Icons.close_rounded,
  });

  /// Visible diameter; the touch target is Material's 48 px.
  static const double size = 44;

  final VoidCallback? onTap;

  /// Goes on the inner [IconButton], so a test can read `onPressed` by key.
  final Key? buttonKey;

  /// Tooltip and spoken name; null is Material's localized "Close".
  final String? tooltip;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return PressScale(
      enabled: onTap != null,
      child: IconButton(
        key: buttonKey,
        onPressed: onTap,
        tooltip:
            tooltip ?? MaterialLocalizations.of(context).closeButtonTooltip,
        style: IconButton.styleFrom(
          backgroundColor: t.surf,
          foregroundColor: t.inkMuted,
          disabledBackgroundColor: t.surf,
          disabledForegroundColor: t.inkDisabled,
          fixedSize: const Size.square(size),
          minimumSize: const Size.square(size),
          padding: EdgeInsets.zero,
          shape: CircleBorder(side: BorderSide(color: t.lineStrong)),
        ),
        icon: Icon(icon, size: 20),
      ),
    );
  }
}

/// Size of a sheet's level-1 title; [kSheetTitleCompactSize] where the
/// height belongs to the content (camera and scanner viewfinders).
const double kSheetTitleSize = 24;
const double kSheetTitleCompactSize = 20;

/// The style of a sheet's level-1 title, for headers that lay it out
/// themselves; [SheetTitle] wraps it with the heading semantics.
TextStyle sheetTitleStyle(AppTokens t, {bool compact = false}) =>
    AppType.display(
      compact ? kSheetTitleCompactSize : kSheetTitleSize,
      color: t.ink,
      height: 1.15,
    );

/// A sheet's title: [sheetTitleStyle], announced as a level-1 heading.
///
/// Large text never splits a word: where the widest word would not fit the
/// column at the current text scale, the scale drops just enough that it
/// does, but never below the title's own size. Next to a slot tile and the
/// close ring, "Review analysis" broke into "Revie/w/analysi/s" at 2x on a
/// 320 px phone. Titles that fit keep the full scale, so they stay above
/// the sheet's section headings.
class SheetTitle extends StatelessWidget {
  const SheetTitle(
    this.text, {
    super.key,
    this.compact = false,
    this.textKey,
    this.textScaler,
  });

  final String text;
  final bool compact;

  /// Goes on the inner [Text] (tests read its style by key).
  final Key? textKey;

  /// The scale before the whole-word fit, e.g. [AppType.pageTitleScaler];
  /// null follows the text scale of the context.
  final TextScaler? textScaler;

  @override
  Widget build(BuildContext context) {
    final style = sheetTitleStyle(context.t, compact: compact);
    final scaler = textScaler ?? MediaQuery.textScalerOf(context);
    return HeadingSemantics(
      level: 1,
      child: LayoutBuilder(
        builder: (context, constraints) => Text(
          text,
          key: textKey,
          textScaler: AppType.wholeWordScaler(
            context,
            text: text,
            style: style,
            scaler: scaler,
            maxWidth: constraints.maxWidth,
            minScaleFactor: 1,
          ),
          style: style,
        ),
      ),
    );
  }
}

/// The header row of a sheet: optional [leading] tile, an optional
/// [eyebrow] line, the [SheetTitle], an optional [subtitle] and the
/// [SheetCloseButton].
///
/// Top-aligned, so a title that wraps at large text never pushes the close
/// button down; a short block is centred on the 48 px button. The default
/// right padding is 2 px short of the 20 px gutter because the 44 px ring
/// sits inside its 48 px target, so the ring lines up with the content.
class SheetHeader extends StatelessWidget {
  const SheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleMaxLines,
    this.eyebrow,
    this.leading,
    this.onClose,
    this.closeEnabled = true,
    this.closeKey,
    this.closeTooltip,
    this.titleKey,
    this.titleScaler,
    this.compact = false,
    this.padding = defaultPadding,
  });

  /// [SheetHeader]'s default padding.
  static const EdgeInsets defaultPadding = EdgeInsets.fromLTRB(
    20,
    4,
    18,
    14,
  );

  final String title;
  final String? subtitle;

  /// Caps the subtitle (ellipsis), e.g. a meal name under "Edit meal".
  final int? subtitleMaxLines;

  /// A small line above the title (the slot of a review sheet).
  final Widget? eyebrow;

  /// A tile in front of the text, centred on the first 48 px.
  final Widget? leading;

  /// Null hides the close button.
  final VoidCallback? onClose;

  /// False keeps the button visible but disabled (e.g. while saving).
  final bool closeEnabled;

  /// Goes on the close button's [IconButton].
  final Key? closeKey;
  final String? closeTooltip;
  final Key? titleKey;

  /// See [SheetTitle.textScaler]; the whole-word fit applies either way.
  final TextScaler? titleScaler;
  final bool compact;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final close = onClose;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) ...[
            SizedBox(
              height: kMinInteractiveDimension,
              child: Center(child: leading),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (eyebrow != null) ...[
                    eyebrow!,
                    const SizedBox(height: 2),
                  ],
                  SheetTitle(
                    title,
                    compact: compact,
                    textKey: titleKey,
                    textScaler: titleScaler,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      maxLines: subtitleMaxLines,
                      overflow: subtitleMaxLines == null
                          ? null
                          : TextOverflow.ellipsis,
                      style: AppType.ui(
                        13,
                        weight: FontWeight.w500,
                        color: t.ink2,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (close != null) ...[
            const SizedBox(width: 8),
            SheetCloseButton(
              buttonKey: closeKey,
              tooltip: closeTooltip,
              onTap: closeEnabled ? close : null,
            ),
          ],
        ],
      ),
    );
  }
}

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
    this.icon,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final String actionLabel;

  /// Danger action at the foot. The title stays `ink`: the red belongs to
  /// the header glyph and the action, not to a whole line of text.
  final bool destructive;

  /// Optional 48 px header tile above the title (danger tint when
  /// [destructive], accent otherwise) — the decision card's header.
  final IconData? icon;

  /// Defaults to closing: a sheet without its own action only confirms.
  final VoidCallback? onAction;

  /// Arms the action. Disabled means dimmed and deaf, not invisible.
  final bool actionEnabled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The tile is decoration: with large text it gives its room to the
    // field and the action, which must stay in reach.
    final showIcon =
        icon != null && MediaQuery.textScalerOf(context).scale(14) <= 21;
    // Scrollable, not just shrink-wrapping: a plain Column overflowed by
    // ~101 px at textScaler 2.0.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (showIcon) ...<Widget>[
            ExcludeSemantics(
              child: IconTile(
                icon: icon!,
                color: destructive ? t.danger : t.accent,
                size: 48,
                glyphSize: 22,
                radius: rControl,
              ),
            ),
            const SizedBox(height: 14),
          ],
          HeadingSemantics(
            level: 1,
            child: Text(
              title,
              style: AppType.display(24, color: t.ink, height: 1.15),
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: AppType.ui(12.5, color: t.ink2, height: 1.45)),
          const SizedBox(height: 18),
          ...children,
          const SizedBox(height: 20),
          // The SAME primary action as every screen foot (accent, rButton):
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
///
/// [onBrand] is the variant for a field inside an [AppTokens.brandSurface]
/// panel, where `field` and `fieldFocus` all but vanish (1.00:1 light,
/// 1.09:1 dark) and focus even moved the fill closer to the panel. It rests
/// on `bg` (1.16:1 light, 1.43:1 dark against the panel) and focuses to
/// `surf`, one step lighter in both palettes like the field/fieldFocus step.
/// An error tints `surf` with `danger` (20 %), a clear step from rest and
/// focus in both palettes with the hint still above 4.5:1.
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
    this.onBrand = false,
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

  /// The ground of a field on a `brandSurface` panel (see the class doc).
  final bool onBrand;

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
    final fill = widget.onBrand
        ? widget.error
              // fieldError is ~1.0:1 on the panel; the danger line under the
              // field carries the message, the tint marks the field. Over
              // surf, not bg: 12 % on the near-black dark bg stayed a dark
              // well (1.16:1 to rest); 20 % on surf reads red in both modes.
              ? Color.alphaBlend(t.danger.withValues(alpha: 0.2), t.surf)
              : focused
              ? t.surf
              : t.bg
        : widget.error
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

  /// Spoken name of the field for screen readers. Where it already says
  /// what [label] says, the eyebrow is not read on its own, so the field is
  /// one stop; otherwise the eyebrow stays readable before the field.
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
    final label = widget.label;
    final spoken = widget.semanticLabel;
    if (spoken != null) {
      field = Semantics(label: spoken, child: field);
    }
    // Where the field's own name says it, a screen reader skips the all-caps
    // eyebrow instead of stopping on the same word twice.
    final eyebrowSaid =
        label != null &&
        spoken != null &&
        spoken.toLowerCase().contains(label.toLowerCase());

    return Padding(
      padding: EdgeInsets.only(bottom: widget.bottomGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (label != null) ...<Widget>[
            ExcludeSemantics(
              excluding: eyebrowSaid,
              child: Text(
                label.toUpperCase(),
                style: AppType.eyebrow(t.ink2, size: 9.5),
              ),
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
/// ONE geometry app-wide: 40 x 4 — the same as the themed Material handle.
///
/// Colored [AppTokens.inkDisabled], not [AppTokens.line]: the 6 % hairline
/// measured 1.15:1 on the sheet ground and read as no handle at all; this
/// grey is 3.0:1 on the dark `bg`.
///
/// Decoration only by default ([ExcludeSemantics]): Material's handle also
/// carries a "dismiss" semantics action, and that goes away with
/// `dragHandle: false`. A sheet without it must offer another close path a
/// screen reader can reach (close button, the sheet action, or the barrier).
/// A sheet with none of those passes [onDismiss], and the handle carries that
/// action itself.
class SheetHandle extends StatelessWidget {
  const SheetHandle({
    super.key,
    this.padding = const EdgeInsets.only(top: 10, bottom: 6),
    this.onDismiss,
  });

  final EdgeInsets padding;

  /// The screen-reader "dismiss" action, under Material's label
  /// (`modalBarrierDismissLabel`). Pass a `maybePop`, so a discard guard
  /// still asks. On Android the barrier offers no such action, so without
  /// this a sheet with no close button would trap a screen-reader user.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final bar = Padding(
      padding: padding,
      child: Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: t.inkDisabled,
            borderRadius: BorderRadius.circular(rPill),
          ),
        ),
      ),
    );
    final dismiss = onDismiss;
    // Decoration only; a screen reader gains nothing from "handle".
    if (dismiss == null) return ExcludeSemantics(child: bar);
    return Semantics(
      button: true,
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      onTap: dismiss,
      excludeSemantics: true,
      child: SizedBox(width: double.infinity, child: bar),
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
    this.followDrag = false,
  });

  final bool active;
  final VoidCallback onDismissAttempt;
  final Widget child;

  /// Small finger-following feedback for sheets that guard every drag.
  final bool followDrag;

  @override
  State<SheetDismissGuard> createState() => _SheetDismissGuardState();
}

class _SheetDismissGuardState extends State<SheetDismissGuard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _feedback = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// Minimum downward distance counted as "close". Deliberately small: the
  /// guard swallows the gesture either way, the only question is whether the
  /// user gets an answer.
  static const double _closeIntentPx = 32;

  /// Fling threshold, mirroring `_kMinFlingVelocity` from bottom_sheet.dart.
  static const double _flingVelocity = 700;

  double _dy = 0;
  bool _canceled = false;
  int _gesture = 0;

  void _onStart(DragStartDetails details) {
    _gesture++;
    _feedback.stop();
    _dy = 0;
    _canceled = false;
  }

  void _onUpdate(DragUpdateDetails details) {
    _dy += details.primaryDelta ?? 0;
    if (widget.followDrag) _feedback.value = (_dy / 72).clamp(0, 1);
  }

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final commit = velocity.abs() >= _flingVelocity
        ? velocity > 0 && _dy > 0
        : _dy > _closeIntentPx;
    _finish(!_canceled && commit);
  }

  Future<void> _finish(bool dismiss) async {
    final gesture = _gesture;
    final route = ModalRoute.of(context);
    if (widget.followDrag && !MediaQuery.disableAnimationsOf(context)) {
      try {
        await _feedback.animateBack(0, curve: Curves.easeOut).orCancel;
      } on TickerCanceled {
        return;
      }
    } else {
      _feedback.value = 0;
    }
    if (mounted && gesture == _gesture && route?.isCurrent != false && dismiss) {
      widget.onDismissAttempt();
    }
  }

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Accepted Flutter drags report pointer cancellation through onEnd.
      onPointerCancel: (_) => _canceled = true,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: widget.active ? _onStart : null,
        onVerticalDragUpdate: widget.active ? _onUpdate : null,
        onVerticalDragEnd: widget.active ? _onEnd : null,
        onVerticalDragCancel: widget.active ? () => _finish(false) : null,
        child: AnimatedBuilder(
          animation: _feedback,
          child: widget.child,
          builder: (context, child) => Transform.translate(
            offset: Offset(
              0,
              widget.followDrag && !MediaQuery.disableAnimationsOf(context)
                  ? _feedback.value * 24
                  : 0,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The 1 px [AppTokens.lineStrong] edge of a sheet that paints its own
/// shell, for a Container's `foregroundDecoration`. Drawn over the content
/// like the shape side of [showEatovaSheet]; as a border in `decoration` it
/// would pad the content 1 px off the 20 px gutter.
BoxDecoration sheetEdgeDecoration(AppTokens t) => BoxDecoration(
  borderRadius: const BorderRadius.vertical(top: Radius.circular(rSheet)),
  border: Border.all(color: t.lineStrong),
);

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
    // A 1 px [AppTokens.lineStrong] edge lifts the sheet off the scrim: the
    // sheet ground is the page's `bg`, which alone barely differs from the
    // dimmed page behind it. Sides and bottom sit on the screen edge.
    shape: transparentShell
        ? null
        : RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(rSheet),
            ),
            side: BorderSide(color: t.lineStrong),
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
