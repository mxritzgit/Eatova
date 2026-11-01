import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import 'app_icon.dart';
import 'readable_width.dart';
import 'spinner.dart';

// ---------------------------------------------------------------------------
// CONTROLS — icon buttons, stepper, icon badges, toggle, filter chip,
// primary action, floating nav bar.
//
// Material carries behavior and semantics, the tokens carry the pixels.
//
// A11y rule for this file (DESIGN_REFACTOR §5): every duration goes through
// [motionDuration]. A hardcoded `Duration` ignores "reduce motion", and these
// blocks appear on EVERY screen.
// ---------------------------------------------------------------------------

/// APP-WIDE SELECTION LANGUAGE of pills, chips and segments.
///
/// Selected = a filled accent capsule ([AppTokens.accentFill]) with an
/// [AppTokens.onAccentFill] label — the dark redesign's selected chip and the
/// same pair [PrimaryActionButton] and the themed `FilledButton` carry.
///
/// History: `forest`/`onForest` failed as a state fill because `forest` is a
/// dark SURFACE in the dark palette (1.34:1 against `surf`, under the 3:1 WCAG
/// 1.4.11 asks of a control's state). The fix has to be one pair that works in
/// both palettes (no brightness branch, DESIGN_REFACTOR §3): the accent fill
/// measures 8.7:1 against the dark `surf` and 6.4:1 against the light one,
/// and its label 8.6:1 / 6.4:1 on it.
extension SelectionTone on AppTokens {
  /// Fill of a SELECTED chip, pill segment or capsule.
  Color get selectedFill => accentFill;

  /// Label, icon and dot on [selectedFill].
  Color get onSelected => onAccentFill;
}

// ---------------------------------------------------------------------------
// ICON BUTTONS, STEPPER AND BADGES (UI polish 2026-11-01)
//
// One icon-only action ([AppIconButton]), one stepper ([AppStepper]) and one
// glyph container ([IconBadge]) for the whole app. The older names below
// ([SquareIconButton], [HeaderIconButton], [IconTile]) are thin wrappers so
// keys, finders and callers keep working.
// ---------------------------------------------------------------------------

/// Emphasis of an [AppIconButton]. The shape is always a circle.
enum IconButtonTone {
  /// A [AppTokens.softFill] disc with an [AppTokens.inkMuted] glyph: back,
  /// close, calendar, history.
  neutral,

  /// Accent tint with an accent glyph: "do something here" (add to a slot,
  /// the stepper's buttons, the mic).
  accent,

  /// Lit: the accent fill casting its own light ([castLight]). The ONE
  /// primary action of a view, never two side by side.
  primary,

  /// No fill at rest, an [AppTokens.ink2] glyph; the disc appears only under
  /// a finger or keyboard focus. For actions inside a row: delete, clear a
  /// field, open a menu.
  plain,

  /// Danger tint with a danger glyph: a destructive shortcut. The red FILL
  /// belongs to the confirming action of the decision card only.
  danger,
}

/// Size of an [AppIconButton]: the drawn disc, the tap target around it and
/// the glyph.
enum IconButtonSize {
  /// A 36 px disc in a 44 px target, 18 px glyph: inside dense rows.
  compact(36, 44, AppIconSize.button),

  /// A 44 px disc and target, 20 px glyph: headers and the default.
  regular(44, 44, AppIconSize.standard),

  /// A 56 px disc and target, 24 px glyph: the player's set check, a dock.
  large(56, 56, AppIconSize.large);

  const IconButtonSize(this.disc, this.target, this.glyph);

  /// Diameter of the drawn disc.
  final double disc;

  /// Edge of the square tap target (at least 44, the HIG floor).
  final double target;

  /// Glyph size ([AppIconSize]).
  final double glyph;
}

/// Opacity of the label and fill of a disabled icon button or stepper.
const double kDisabledAlpha = 0.45;

/// A glyph that carries a state: the concept's contour when [on] is false,
/// its filled form ([AppIcons.filled]) when true. Only an "on" is filled
/// (favourite set, saved, eaten or done, listening), never decoration.
///
/// With a variable icon font the fill axis animates over [kMotionLightUp]
/// (instant under reduced motion); the SDK's Material Icons ignore the axis
/// and swap the glyph.
class StateIcon extends StatelessWidget {
  const StateIcon(
    this.icon, {
    super.key,
    required this.on,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final IconData icon;
  final bool on;

  /// Null takes the surrounding [IconTheme].
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(end: on ? 1 : 0),
    duration: motionDuration(context, kMotionLightUp),
    curve: kMotionCurve,
    builder: (context, fill, _) => Icon(
      on ? AppIcons.filled(icon) : icon,
      size: size,
      color: color,
      fill: fill,
      semanticLabel: semanticLabel,
    ),
  );
}

/// Every icon-only action of the app: a circle in one of five [tone]s and
/// three [size]s, see the enums.
///
/// States, the same for every button: a press sinks the disc and deepens its
/// fill (no ripple); keyboard focus lays its tone over it (a lit one lifts
/// its light), never a ring; `onTap: null` dims label and fill to
/// [kDisabledAlpha] and reports it disabled (a lit one turns into the
/// "not yet" tint of [PrimaryActionButton]); [busy] puts an [AppSpinner] in
/// place of the glyph and ignores taps. [selected] makes it a toggle: the
/// glyph fills ([StateIcon]) and the node is announced `toggled`.
///
/// [semanticLabel] is the spoken name and the long-press tooltip. [key] sits
/// on this widget (so `tester.widget<AppIconButton>(byKey).onTap` works),
/// [buttonKey] on the inner [InkWell].
class AppIconButton extends StatefulWidget {
  const AppIconButton({
    super.key,
    this.icon,
    this.child,
    required this.semanticLabel,
    this.onTap,
    this.onLongPress,
    this.tone = IconButtonTone.neutral,
    this.size = IconButtonSize.regular,
    this.busy = false,
    this.selected,
    this.haptic = false,
    this.buttonKey,
    this.target,
  }) : assert(
         icon != null || child != null,
         'An icon button needs an icon or a child',
       );

  /// The glyph, usually an [AppIcons] constant.
  final IconData? icon;

  /// A custom glyph instead of [icon] (an [AppIcon], [StepsIcon]); it takes
  /// size and colour from the surrounding [IconTheme].
  final Widget? child;

  final String semanticLabel;
  final VoidCallback? onTap;

  /// Disables the tooltip, which would otherwise take the long press.
  final VoidCallback? onLongPress;

  final IconButtonTone tone;
  final IconButtonSize size;
  final bool busy;

  /// Toggle state; null for a plain action.
  final bool? selected;

  /// A light haptic on tap (confirm, add). Off by default: most icon
  /// buttons navigate.
  final bool haptic;

  final Key? buttonKey;

  /// A larger square tap target than [size] gives (e.g. 48 next to a dense
  /// row); never smaller.
  final double? target;

  @override
  State<AppIconButton> createState() => _AppIconButtonState();
}

class _AppIconButtonState extends State<AppIconButton> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_focusModeChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_focusModeChanged);
    super.dispose();
  }

  void _focusModeChanged(FocusHighlightMode mode) {
    if (_focused) setState(() {});
  }

  void _tap() {
    if (widget.haptic) unawaited(HapticFeedback.lightImpact());
    widget.onTap?.call();
  }

  (Color, Color) _rest(AppTokens t) => switch (widget.tone) {
    IconButtonTone.neutral => (t.softFill, t.inkMuted),
    IconButtonTone.accent => (t.accentTintStrong, t.accentText),
    IconButtonTone.primary => (t.accentFill, t.onAccentFill),
    IconButtonTone.plain => (t.softFill.withValues(alpha: 0), t.ink2),
    IconButtonTone.danger => (t.danger.withValues(alpha: 0.12), t.danger),
  };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final size = widget.size;
    final enabled = widget.onTap != null && !widget.busy;
    final lit = widget.tone == IconButtonTone.primary;
    final plain = widget.tone == IconButtonTone.plain;
    final (restFill, restInk) = _rest(t);
    final Color fill;
    final Color ink;
    if (enabled || widget.busy) {
      fill = restFill;
      ink = restInk;
    } else if (lit) {
      fill = t.accentFill.withValues(alpha: kLockedFillAlpha);
      ink = t.accentText.withValues(alpha: kLockedLabelAlpha);
    } else {
      fill = restFill.withValues(alpha: restFill.a * kDisabledAlpha);
      ink = restInk.withValues(alpha: kDisabledAlpha);
    }
    final keyboard =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

    final Widget glyph = widget.busy
        ? ExcludeSemantics(
            child: AppSpinner(
              size: size == IconButtonSize.large ? 22 : 18,
              strokeWidth: 2,
              color: ink,
              trackColor: ink.withValues(alpha: 0.2),
            ),
          )
        : IconTheme.merge(
            data: IconThemeData(
              color: ink,
              size: size.glyph,
              opticalSize: size.glyph >= AppIconSize.large ? 24 : 20,
            ),
            child:
                widget.child ??
                StateIcon(widget.icon!, on: widget.selected ?? false),
          );

    Widget disc = Material(
      color: fill,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: widget.buttonKey,
        onTap: enabled ? _tap : null,
        onLongPress: enabled ? widget.onLongPress : null,
        onFocusChange: (focused) => setState(() => _focused = focused),
        customBorder: const CircleBorder(),
        splashFactory: NoSplash.splashFactory,
        // The plain button shows its disc only while touched or focused.
        highlightColor: plain ? t.softFill : ink.withValues(alpha: 0.10),
        focusColor: lit
            ? kLitFocusOverlay
            : (plain ? t.softFill : ink.withValues(alpha: 0.16)),
        hoverColor: plain
            ? t.softFill.withValues(alpha: 0.6)
            : ink.withValues(alpha: 0.05),
        child: SizedBox.square(
          dimension: size.disc,
          child: Center(child: glyph),
        ),
      ),
    );
    disc = PressScale(
      enabled: enabled,
      rebound: lit,
      builder: lit
          ? (context, press, child) => DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: castLight(
                  t,
                  t.accentGlow,
                  strength: (enabled || widget.busy ? 1.0 : 0.0) *
                      (keyboard ? 1.4 : 1.0),
                  press: press,
                ),
              ),
              child: child,
            )
          : null,
      child: disc,
    );

    final target = math.max(size.target, widget.target ?? 0);
    Widget button = _TapTarget(minSize: Size.square(target), child: disc);
    // The tooltip owns the long press; a long-press action keeps it.
    if (widget.onLongPress == null &&
        widget.semanticLabel.isNotEmpty &&
        Overlay.maybeOf(context) != null) {
      button = Tooltip(
        message: widget.semanticLabel,
        excludeFromSemantics: true,
        child: button,
      );
    }
    // One node over the whole target: the InkWell's tap and focus merge in,
    // and the node's rect is the full 44 px, not the drawn disc.
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      toggled: widget.selected,
      label: widget.semanticLabel,
      child: button,
    );
  }
}

/// Grows [child] to [minSize] and sends taps on the margin to the child's
/// centre — Material's input padding, so a 36 px disc keeps a 44 px target.
class _TapTarget extends SingleChildRenderObjectWidget {
  const _TapTarget({required this.minSize, required super.child});

  final Size minSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTapTarget(minSize);

  @override
  void updateRenderObject(BuildContext context, _RenderTapTarget renderObject) {
    renderObject.minSize = minSize;
  }
}

class _RenderTapTarget extends RenderShiftedBox {
  _RenderTapTarget(this._minSize) : super(null);

  Size _minSize;
  set minSize(Size value) {
    if (value == _minSize) return;
    _minSize = value;
    markNeedsLayout();
  }

  Size _sizeFor(BoxConstraints constraints, Size childSize) =>
      constraints.constrain(
        Size(
          math.max(childSize.width, _minSize.width),
          math.max(childSize.height, _minSize.height),
        ),
      );

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(child?.getMinIntrinsicWidth(height) ?? 0, _minSize.width);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(child?.getMaxIntrinsicWidth(height) ?? 0, _minSize.width);

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(child?.getMinIntrinsicHeight(width) ?? 0, _minSize.height);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(child?.getMaxIntrinsicHeight(width) ?? 0, _minSize.height);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.constrain(_minSize);
    return _sizeFor(constraints, child.getDryLayout(constraints.loosen()));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.constrain(_minSize);
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = _sizeFor(constraints, child.size);
    (child.parentData! as BoxParentData).offset = Alignment.center.alongOffset(
      size - child.size as Offset,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    final child = this.child;
    if (child == null || !size.contains(position)) return false;
    final center = child.size.center(Offset.zero);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(center),
      position: center,
      hitTest: (result, _) => child.hitTest(result, position: center),
    );
  }
}

/// The app's one stepper: `(−)  250 g  (+)`.
///
/// The buttons are accent [AppIconButton]s ([size] `regular`, or `compact`
/// in a dense row); the value sits between them in the display face with
/// tabular figures, at least 56 px wide, the [unit] after it in `subhead`.
/// A null [onDecrement]/[onIncrement] is a reached limit: that button dims
/// and is reported disabled. Every step clicks ([HapticFeedback.
/// selectionClick]).
///
/// Semantics: the whole stepper is ONE adjustable node ([semanticLabel],
/// [semanticValue], [increasedValue]/[decreasedValue]); VoiceOver and
/// TalkBack step it with a swipe up or down. The buttons keep their own
/// labels for exploration by touch ([decrementLabel]/[incrementLabel],
/// defaulting to `commonDecrease`/`commonIncrease`). The keys go on the
/// buttons, so existing tests keep tapping them.
class AppStepper extends StatelessWidget {
  const AppStepper({
    super.key,
    required this.value,
    required this.semanticLabel,
    required this.onDecrement,
    required this.onIncrement,
    required this.increasedValue,
    required this.decreasedValue,
    this.unit,
    this.semanticValue,
    this.onLongPressDecrement,
    this.onLongPressIncrement,
    this.decrementLabel,
    this.incrementLabel,
    this.decrementKey,
    this.incrementKey,
    this.size = IconButtonSize.regular,
  });

  /// The shown value, already formatted ("250", "1,5").
  final String value;

  /// Short unit after the value ("g", "Portionen").
  final String? unit;

  /// What the stepper sets ("Menge", "Portionen").
  final String semanticLabel;

  /// The spoken value; defaults to "[value] [unit]".
  final String? semanticValue;

  /// The spoken value after one step up / down. Required: an adjustable node
  /// says where a swipe leads (Flutter asserts value and both neighbours
  /// together).
  final String increasedValue;
  final String decreasedValue;

  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;
  final VoidCallback? onLongPressDecrement;
  final VoidCallback? onLongPressIncrement;
  final String? decrementLabel;
  final String? incrementLabel;
  final Key? decrementKey;
  final Key? incrementKey;
  final IconButtonSize size;

  static VoidCallback? _clicking(VoidCallback? step) => step == null
      ? null
      : () {
          unawaited(HapticFeedback.selectionClick());
          step();
        };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final down = _clicking(onDecrement);
    final up = _clicking(onIncrement);
    final spoken = semanticValue ?? (unit == null ? value : '$value $unit');
    return Semantics(
      container: true,
      label: semanticLabel,
      value: spoken,
      increasedValue: onIncrement == null ? null : increasedValue,
      decreasedValue: onDecrement == null ? null : decreasedValue,
      onIncrease: up,
      onDecrease: down,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppIconButton(
            key: decrementKey,
            icon: AppIcons.remove,
            semanticLabel: decrementLabel ?? l10n.commonDecrease,
            tone: IconButtonTone.accent,
            size: size,
            onTap: down,
            onLongPress: onDecrement == null ? null : onLongPressDecrement,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSpace8),
              child: ExcludeSemantics(
                child: Text.rich(
                  TextSpan(
                    text: value,
                    style: AppType.numeric(20, color: t.ink),
                    children: <InlineSpan>[
                      if (unit != null)
                        TextSpan(text: ' $unit', style: AppType.subhead(t.ink2)),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          AppIconButton(
            key: incrementKey,
            icon: AppIcons.add,
            semanticLabel: incrementLabel ?? l10n.commonIncrease,
            tone: IconButtonTone.accent,
            size: size,
            onTap: up,
            onLongPress: onIncrement == null ? null : onLongPressIncrement,
          ),
        ],
      ),
    );
  }
}

/// The three edges of an [IconBadge].
enum IconBadgeSize {
  /// 32 px, 16 px glyph, [rChip]: dense rows, plan, sessions.
  sm(32, AppIconSize.small, rChip),

  /// 40 px, 20 px glyph, [rChip]: the standard list row.
  md(40, AppIconSize.standard, rChip),

  /// 44 px, 22 px glyph, [rControl]: tab roots, empty states, option cards.
  lg(44, AppIconSize.tile, rControl);

  const IconBadgeSize(this.edge, this.glyph, this.radius);

  final double edge;
  final double glyph;
  final double radius;

  /// The stage nearest to an older free edge length (30–48 px).
  static IconBadgeSize nearest(double edge) =>
      edge < 36 ? sm : (edge <= 42 ? md : lg);
}

/// Fill of an [IconBadge] when no [IconBadge.color] is given.
enum IconBadgeTone {
  /// `tile` fill, `inkMuted` glyph.
  neutral,

  /// `accentTint` fill, `accentText` glyph.
  accent,

  /// `accentFill` with an `onAccentFill` glyph. Rare, and never next to a
  /// lit action.
  solid,
}

/// The one glyph container: a rounded square in three [size]s. With [color]
/// it is tinted by that colour (macro, slot, warning, success, danger) at
/// 15 % with a glyph in [AppTokens.readableOnTint]; otherwise [tone] picks
/// the fill.
///
/// Always decorative ([ExcludeSemantics]): the row or card next to it says
/// what it means. [child] takes a custom glyph ([StepsIcon], an [AppIcon])
/// and hands it size and colour through [IconTheme].
class IconBadge extends StatelessWidget {
  const IconBadge({
    super.key,
    this.icon,
    this.child,
    this.size = IconBadgeSize.md,
    this.tone = IconBadgeTone.neutral,
    this.color,
  }) : _glyph = null,
       _radius = null,
       assert(icon != null || child != null, 'A badge needs a glyph');

  /// [IconTile]'s legacy overrides.
  const IconBadge._legacy({
    this.icon,
    this.child,
    required this.size,
    this.color,
    double? glyph,
    double? radius,
  }) : tone = IconBadgeTone.neutral,
       _glyph = glyph,
       _radius = radius;

  final IconData? icon;
  final Widget? child;
  final IconBadgeSize size;
  final IconBadgeTone tone;
  final Color? color;
  final double? _glyph;
  final double? _radius;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final tint = color;
    final (fill, ink) = tint != null
        ? (tint.withValues(alpha: 0.15), t.readableOnTint(tint))
        : switch (tone) {
            IconBadgeTone.neutral => (t.tile, t.inkMuted),
            IconBadgeTone.accent => (t.accentTint, t.accentText),
            IconBadgeTone.solid => (t.accentFill, t.onAccentFill),
          };
    final glyphSize = _glyph ?? size.glyph;
    final edge = size.edge;
    return ExcludeSemantics(
      child: Container(
        width: edge,
        height: edge,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(_radius ?? size.radius),
        ),
        child: child == null
            ? Icon(icon, size: glyphSize, color: ink)
            : IconTheme.merge(
                data: IconThemeData(size: glyphSize, color: ink),
                child: child!,
              ),
      ),
    );
  }
}

/// Back, close and menu inside a dense row: since 2026-11-01 a compact
/// [AppIconButton] (a round 36 px disc in a 44 px target).
class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: icon,
    onTap: onTap,
    semanticLabel: semanticLabel ?? '',
    size: IconButtonSize.compact,
  );
}

/// Emphasis of a [HeaderIconButton].
enum HeaderIconTone {
  /// A soft neutral disc: calendar, history, info.
  neutral,

  /// The lit accent disc: the one primary action of a header (e.g. "add").
  primary,
}

/// Round 44 px icon button for headers: a regular [AppIconButton] in the
/// neutral or lit tone. Kept as a name for keys and finders.
class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onTap,
    this.tone = HeaderIconTone.neutral,
  }) : _child = null;

  /// With a custom glyph (e.g. an [AppIcon]); it inherits color and size
  /// from the button's [IconTheme].
  const HeaderIconButton.custom({
    super.key,
    required Widget child,
    required this.semanticLabel,
    this.onTap,
    this.tone = HeaderIconTone.neutral,
  }) : icon = null,
       _child = child;

  /// Diameter, also the touch target.
  static const double size = 44;

  final IconData? icon;
  final Widget? _child;
  final String semanticLabel;
  final VoidCallback? onTap;
  final HeaderIconTone tone;

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: icon,
    semanticLabel: semanticLabel,
    onTap: onTap,
    tone: tone == HeaderIconTone.primary
        ? IconButtonTone.primary
        : IconButtonTone.neutral,
    child: _child,
  );
}

/// Faintly tinted tile behind an icon: since 2026-11-01 an [IconBadge] at
/// the stage nearest to [size] (default `sm`). New code uses [IconBadge].
///
/// [glyphSize] and [radius] stay as overrides for older callers; without
/// them the badge stage decides.
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.color,
    this.size = 34,
    this.glyphSize,
    this.radius,
  }) : _child = null;

  const IconTile.custom({
    super.key,
    required Widget child,
    this.color,
    this.size = 34,
    this.glyphSize,
    this.radius,
  }) : icon = null,
       _child = child;

  final IconData? icon;
  final Widget? _child;
  final Color? color;
  final double size;
  final double? glyphSize;
  final double? radius;

  @override
  Widget build(BuildContext context) => IconBadge._legacy(
    icon: icon,
    size: IconBadgeSize.nearest(size),
    color: color,
    glyph: glyphSize,
    radius: radius,
    child: _child,
  );
}

/// The app's toggle: capsule with a travelling knob.
class AppToggle extends StatelessWidget {
  const AppToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// Locked toggle (e.g. bound to a missing permission): dimmed and deaf.
  /// Deliberately not `onChanged: null`, so the caller keeps its callback.
  final bool enabled;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final motion = motionDuration(context, const Duration(milliseconds: 180));
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: GestureDetector(
          // Opaque so the transparent hit-area margin actually works; the
          // default `deferToChild` ends the target at the drawn capsule.
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onChanged(!value) : null,
          // 46x27 visible, 44 px tall tappable — same floor as
          // [SquareIconButton]. The settings row grows with it; that is the
          // price, and only where a toggle actually sits.
          child: SizedBox(
            width: 46,
            height: 44,
            child: Center(
              child: AnimatedContainer(
                duration: motion,
                curve: Curves.easeOut,
                width: 46,
                height: 27,
                padding: const EdgeInsets.all(3),
                // The app's selection language ([SelectionTone]), as in the
                // settings segments: ON is a solid `selectedFill` track with
                // an `onSelected` knob, OFF a quiet ink2@35 % track with a
                // solid ink2 knob.
                // The OFF track is only 1.7:1 (L) / 2.1:1 (D) against the
                // card; WCAG 1.4.11 asks 3:1 for the component BOUNDARY, and
                // that is the knob: 3.7:1 (L) / 4.1:1 (D) against the track,
                // 6.2:1 / 8.5:1 against the card. A 3:1 track would need
                // ink2@75 % and eat the knob. ON: track 6.4:1 / 8.7:1
                // against the card, knob 6.4:1 / 8.6:1 against the track.
                decoration: BoxDecoration(
                  color: value
                      ? t.selectedFill
                      : t.ink2.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(rPill),
                ),
                child: AnimatedAlign(
                  duration: motion,
                  curve: Curves.easeOut,
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 21,
                    height: 21,
                    decoration: BoxDecoration(
                      color: value ? t.onSelected : t.ink2,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Size of a [FilterChipPill].
enum FilterChipSize {
  /// Dense bars (slot pickers inside sheets).
  sm,

  /// Screen-level filter bars — the default.
  md,
}

/// Tone of a [FilterChipPill].
enum FilterChipTone {
  /// Text only.
  neutral,

  /// A colored dot in front of the label — meal slots, categories. The dot
  /// takes [FilterChipPill.dotColor].
  slot,
}

/// Filter/choice pill for horizontal chip bars (dark redesign, 2026-09-28).
///
/// ONE selection language for every chip in the app ([SelectionTone]):
/// selected = accent fill with an on-accent label (and icon), outline in the
/// fill color; unselected = `surf` with a 1 px `lineStrong` outline and an
/// `inkMuted` label. Fully round; the [FilterChipSize.md] chip is 44 px tall
/// with a 14/700 label.
class FilterChipPill extends StatelessWidget {
  const FilterChipPill({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
    this.icon,
    this.size = FilterChipSize.md,
    this.tone = FilterChipTone.neutral,
    this.dotColor,
    this.semanticLabel,
    this.expand = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// Centres the label in a pill that is wider than its content, e.g. one of
  /// several equal-width pills in an [Expanded]. Off: the pill hugs it.
  final bool expand;

  /// Leading glyph, drawn in the label color.
  final IconData? icon;

  final FilterChipSize size;
  final FilterChipTone tone;

  /// Dot color for [FilterChipTone.slot]; falls back to the label color.
  final Color? dotColor;

  /// Spoken name; defaults to [label].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final small = size == FilterChipSize.sm;
    final fg = selected ? t.onSelected : t.inkMuted;
    final fontSize = small ? 12.0 : 14.0;
    final padding = small
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 9);
    // Selection is carried by fill and text color alone; without `selected` in
    // the semantics tree a screen reader cannot tell which filter is active.
    // With an explicit spoken name the visible label is excluded, otherwise
    // the node would read "name, label" twice over.
    // A null [onTap] is a disabled chip (e.g. while a sheet saves): said so
    // and dimmed, not a live-looking button that does nothing.
    final chip = Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: PressScale(
        enabled: onTap != null,
      child: Material(
        color: selected ? t.selectedFill : t.surf,
        borderRadius: BorderRadius.circular(rPill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rPill),
          child: Container(
            // 44 px including the padding (the tap-target floor); the Row
            // centres its content.
            constraints: BoxConstraints(minHeight: small ? 0 : 44),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(rPill),
              // The selected chip keeps a ring in its own fill colour instead
              // of dropping to transparent: same pixels, but the geometry no
              // longer depends on the state, and the boundary that identifies
              // it is the fill against the ground rather than the faint edge.
              border: Border.all(
                color: selected ? t.selectedFill : t.lineStrong,
              ),
            ),
            padding: padding,
            // Not a Container alignment: that would also stretch the height
            // in a parent with room to spare.
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (tone == FilterChipTone.slot) ...<Widget>[
                  Container(
                    key: const ValueKey('filter-chip-dot'),
                    width: small ? 6 : 8,
                    height: small ? 6 : 8,
                    decoration: BoxDecoration(
                      // On the selected fill the dot would lose its hue
                      // anyway: the label colour is the safe fallback.
                      color: selected ? t.onSelected : (dotColor ?? fg),
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: small ? 6 : 8),
                ],
                if (icon != null) ...<Widget>[
                  Icon(
                    icon,
                    size: small ? AppIconSize.meta : AppIconSize.small,
                    color: fg,
                  ),
                  SizedBox(width: small ? 4 : 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    textAlign: expand ? TextAlign.center : null,
                    style: AppType.ui(
                      fontSize,
                      weight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
    return onTap == null ? Opacity(opacity: 0.45, child: chip) : chip;
  }
}

/// Fill opacity of a disabled control that dims its own fill (the older
/// recipe, kept for screens that still draw their own pill).
const double kDisabledFillAlpha = 0.38;

/// Fill opacity of a locked lit action, "not yet": a soft tint of its own
/// accent that lights up when it arms. ≥ 1.5:1 against `surf` and `bg` in
/// both palettes, ≥ 3.8:1 apart from the lit fill.
const double kLockedFillAlpha = 0.30;

/// Label opacity of a locked lit action (`accentText`).
const double kLockedLabelAlpha = 0.72;

/// [a] towards [b] by [v], exact at both ends: a resting control paints the
/// token itself, never a float-rounded neighbour of it.
Color mixTone(Color a, Color b, double v) =>
    v <= 0 ? a : (v >= 1 ? b : Color.lerp(a, b, v)!);

/// The arming pop of a [PrimaryActionButton]: it grows to 1 + this as it
/// lights up and settles back.
const double _kArmPop = 0.03;
const Duration _kArmPopDuration = Duration(milliseconds: 320);

/// [kSpringPop]'s single overshoot (ζ 0.55), so its peak maps to [_kArmPop].
final double _kSpringPopPeak = math.exp(
  -0.55 * math.pi / math.sqrt(1 - 0.55 * 0.55),
);

/// The wide primary action at the foot of a screen.
///
/// Depth and light (polish 2026-10-25): an armed action is LIT, a filled
/// [AppTokens.accentFill] pill ([AppTokens.dangerFill] when [destructive])
/// that casts its own colour onto the ground ([castLight]). A locked one is
/// "not yet": a soft tint of its own hue ([kLockedFillAlpha]) with a dimmed
/// `accentText` label and no light; a locked destructive one keeps the soft
/// danger pair. Arming lights it up over [kMotionLightUp] with a small pop;
/// a press sinks it into its light and it rebounds a hair past rest. Busy
/// keeps it lit: working, not locked. No ripple: a press darkens the fill a
/// step; keyboard focus brightens it and lifts the light, never a ring.
class PrimaryActionButton extends StatefulWidget {
  const PrimaryActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.destructive = false,
    this.height = kPrimaryButtonHeight,
    this.busy = false,
    this.animateLabel = false,
    this.haptic = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool destructive;

  /// Minimum height; [kPrimaryButtonHeight] is the app-wide default.
  final double height;

  /// Work in flight ("Saving…"): a spinner in place of the icon, taps
  /// ignored, the fill kept at full strength — working, not locked. The
  /// button is the only progress signal; no extra bar above it.
  final bool busy;

  /// A changed [label] cross-fades with a short rise, so the control reads
  /// as taking on a new job (the paywall's buy button). At rest it is
  /// exactly one [Text].
  final bool animateLabel;

  /// A light haptic on tap (the paywall's buy). A destructive action always
  /// gives a medium one; every other primary action stays silent.
  final bool haptic;

  @override
  State<PrimaryActionButton> createState() => _PrimaryActionButtonState();
}

class _PrimaryActionButtonState extends State<PrimaryActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _arm = AnimationController(
    vsync: this,
    duration: _kArmPopDuration,
  );
  bool _focused = false;

  static bool _isLit(PrimaryActionButton button) =>
      button.onTap != null || button.busy;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_focusModeChanged);
  }

  void _focusModeChanged(FocusHighlightMode mode) {
    if (_focused) setState(() {});
  }

  @override
  void didUpdateWidget(PrimaryActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isLit(oldWidget) && _isLit(widget) && !reducedMotion(context)) {
      _arm
        ..duration = motionDuration(context, _kArmPopDuration)
        ..forward(from: 0);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_focusModeChanged);
    _arm.dispose();
    super.dispose();
  }

  void _tap() {
    if (widget.destructive) {
      unawaited(HapticFeedback.mediumImpact());
    } else if (widget.haptic) {
      unawaited(HapticFeedback.lightImpact());
    }
    widget.onTap?.call();
  }

  /// 1 at rest, about 1.03 at the peak of the arming pop.
  double _armScale() {
    final overshoot = kSpringPop.transform(_arm.value) - 1;
    return overshoot <= 0 ? 1 : 1 + _kArmPop * overshoot / _kSpringPopPeak;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = widget.onTap != null && !widget.busy;
    final lit = enabled || widget.busy;
    final (litFill, litInk, light, lockedFill, lockedInk) = widget.destructive
        ? (
            t.dangerFill,
            t.onDangerFill,
            t.dangerFill.withValues(alpha: 0.38),
            // A locked destructive action keeps the soft danger pair: a
            // translucent red over the dark ground mixed a muddy brown.
            t.danger.withValues(alpha: 0.12),
            t.danger.withValues(alpha: 0.55),
          )
        : (
            t.accentFill,
            t.onAccentFill,
            t.accentGlow,
            t.accentFill.withValues(alpha: kLockedFillAlpha),
            t.accentText.withValues(alpha: kLockedLabelAlpha),
          );
    final keyboard =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final radius = BorderRadius.circular(rButton);
    final morph = widget.animateLabel && !reducedMotion(context);
    // A bare InkWell carries neither `isButton` nor an enabled state, so a
    // screen reader would announce the primary action as plain text and a
    // disabled one as a button that does nothing. `onTap == null` is the
    // app-wide disabled convention.
    return Semantics(
      button: true,
      enabled: enabled,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: lit ? 1 : 0),
        duration: motionDuration(context, kMotionLightUp),
        curve: kMotionCurve,
        builder: (context, glow, _) {
          final fill = mixTone(lockedFill, litFill, glow);
          final onFill = mixTone(lockedInk, litInk, glow);
          final style = AppType.ui(
            15,
            weight: FontWeight.w800,
            color: onFill,
            letterSpacing: -0.1,
          );
          return AnimatedBuilder(
            animation: _arm,
            builder: (context, child) =>
                Transform.scale(scale: _armScale(), child: child),
            child: PressScale(
              enabled: enabled,
              rebound: true,
              builder: (context, press, child) => DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: castLight(
                    t,
                    light,
                    strength: glow * (keyboard ? 1.4 : 1),
                    press: press,
                  ),
                ),
                child: child,
              ),
              child: Material(
                color: fill,
                borderRadius: radius,
                elevation: 0,
                child: InkWell(
                  onTap: enabled ? _tap : null,
                  onFocusChange: (focused) =>
                      setState(() => _focused = focused),
                  borderRadius: radius,
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: onFill.withValues(alpha: 0.10),
                  focusColor: kLitFocusOverlay,
                  hoverColor: onFill.withValues(alpha: 0.05),
                  child: ConstrainedBox(
                    // Min height, not a fixed one: at textScaler 2.0 the
                    // label would be taller than the button.
                    constraints: BoxConstraints(minHeight: widget.height),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          if (widget.busy) ...<Widget>[
                            ExcludeSemantics(
                              child: AppSpinner(
                                size: 18,
                                strokeWidth: 2,
                                color: onFill,
                                trackColor: onFill.withValues(alpha: 0.2),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ] else if (widget.icon != null) ...<Widget>[
                            Icon(widget.icon, size: 18, color: onFill),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: morph
                                ? _LabelMorph(label: widget.label, style: style)
                                : Text(
                                    widget.label,
                                    textAlign: TextAlign.center,
                                    style: style,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A button label that cross-fades with a 35 % rise when it changes
/// ("7 Tage gratis testen" → "Premium abonnieren"). At rest it is exactly
/// one [Text]; the caller drops it under reduced motion.
class _LabelMorph extends StatelessWidget {
  const _LabelMorph({required this.label, required this.style});

  final String label;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: motionDuration(context, kMotionLightUp),
    switchInCurve: kMotionCurve,
    switchOutCurve: kMotionCurve.flipped,
    // The outgoing label fades but must not be read: a screen reader would
    // hear both buy labels during the cross-fade.
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.center,
      children: <Widget>[
        for (final child in previous) ExcludeSemantics(child: child),
        if (current != null) current,
      ],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.35),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
    child: Text(
      label,
      key: ValueKey<String>(label),
      textAlign: TextAlign.center,
      style: style,
    ),
  );
}

/// One entry of the [AppNavBar].
@immutable
class AppNavItem {
  const AppNavItem({
    required this.icon,
    required this.label,
    String? keyId,
  }) : keyId = keyId ?? label;

  final AppSymbol icon;

  /// The visible label — comes from the ARB and is translated.
  final String label;

  /// Carries the test key (`ValueKey('nav-$keyId')`). Stays GERMAN even when
  /// [label] is translated — keys are API (DESIGN_REFACTOR §6).
  final String keyId;
}

/// The floating glass tab bar (dark redesign, 2026-09-28).
///
/// Floats [sideGap] from the sides and [bottomOffsetFor] above the screen
/// edge; the design's fade (page color to transparent) sits behind it, so
/// content scrolling under the bar dissolves into the page.
///
/// Its layout height is the band it claims ([reservedHeightFor]: offset, bar
/// and [clearance]). In a `Scaffold(extendBody: true)` the body runs under the
/// bar and receives that band as `MediaQuery.padding.bottom`: scroll views pad
/// their END by it (content scrolls under the glass but can always be scrolled
/// clear of it), and pinned bottom elements (docks, composers, CTAs) sit on
/// top of it, [clearance] above the bar.
///
/// Motion (polish 2026-10-01): the selected-item pill slides over to the new
/// item in [pillDuration], stretching a little on the way; icon and label
/// colours cross-fade and the tapped icon dips to 0.9. A real change clicks
/// ([HapticFeedback.selectionClick]); re-tapping the active item still reports
/// it but stays silent. Everything is paint-only behind its own
/// [RepaintBoundary], so the glass's BackdropFilter is never repainted by it.
class AppNavBar extends StatefulWidget {
  const AppNavBar({
    super.key,
    required this.index,
    required this.onChanged,
    required this.items,
    this.docked = false,
  });

  /// Height of the glass bar itself (it grows with very large text).
  static const double barHeight = 68;

  /// Minimum height of one item, well above the 44 px touch floor.
  static const double itemHeight = 58;

  /// Distance of the bar from the screen sides.
  static const double sideGap = 14;

  /// Distance of the bar from the SCREEN edge while the bottom inset is only a
  /// home indicator or gesture handle: the indicator sits in this gap.
  static const double bottomGap = 22;

  /// Largest bottom inset still treated as indicator/handle (iPhone: 34).
  static const double maxGestureInset = 34;

  /// Gap above a taller inset — Android's 3-button bar keeps its buttons free.
  static const double systemBarGap = 8;

  /// Space between the bar and whatever is pinned above it (the design's
  /// docks sit at 22 + 68 + 12 = 102).
  static const double clearance = 12;

  /// Backdrop blur behind the glass (CSS `blur(24px)`).
  static const double blurSigma = 24;

  /// The design's fade band, measured from the screen edge at the design's
  /// offset: 10 px taller than the claimed band, so it reaches above the
  /// [clearance] line (painted, never laid out or hit-tested).
  static const double fadeHeight = 112;

  /// Opaque foot of the fade: 40 % of [fadeHeight].
  static const double _fadeSolid = fadeHeight * 0.4;

  /// Travel of the selected-item pill to a new item.
  static const Duration pillDuration = Duration(milliseconds: 240);

  /// Distance of the bar's bottom edge from the screen edge for [bottomInset]
  /// (`MediaQuery.padding.bottom` of the window).
  static double bottomOffsetFor(double bottomInset) =>
      bottomInset <= maxGestureInset ? bottomGap : bottomInset + systemBarGap;

  /// The band the bar claims at the bottom of the screen (at the nominal bar
  /// height): what tab bodies receive as `MediaQuery.padding.bottom`.
  static double reservedHeightFor(double bottomInset) =>
      bottomOffsetFor(bottomInset) + barHeight + clearance;

  /// Test hook: the pill's global rect, from the render object found under
  /// `ValueKey('nav-pill')`.
  @visibleForTesting
  static Rect? debugPillRect(RenderObject track) {
    final box = track as _RenderNavPillTrack;
    return box.pillRect?.shift(box.localToGlobal(Offset.zero));
  }

  final int index;
  final ValueChanged<int> onChanged;
  final List<AppNavItem> items;

  /// Whether the shown tab pins a dock on the [clearance] line (Food's entry
  /// dock, Coach's composer). The fade then ends at that line, so it never
  /// veils the dock.
  final bool docked;

  @override
  State<AppNavBar> createState() => _AppNavBarState();
}

class _AppNavBarState extends State<AppNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pill = AnimationController(
    vsync: this,
    duration: AppNavBar.pillDuration,
    value: 1,
  );

  /// Where the pill started its current travel (fractional item index).
  late double _pillFrom = widget.index.toDouble();

  final _PillAnchors _anchors = _PillAnchors();

  @override
  void didUpdateWidget(AppNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    // Retarget from where the pill is now, so rapid taps never jump.
    _pillFrom = _RenderNavPillTrack.positionAt(
      _pillFrom,
      oldWidget.index.toDouble(),
      _pill.value,
    );
    final duration = motionDuration(context, AppNavBar.pillDuration);
    if (duration == Duration.zero) {
      _pill.value = 1;
      return;
    }
    _pill
      ..duration = duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _pill.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (i != widget.index) HapticFeedback.selectionClick();
    widget.onChanged(i);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final items = widget.items;
    final offset = AppNavBar.bottomOffsetFor(
      MediaQuery.paddingOf(context).bottom,
    );
    final fadeOverhang = widget.docked
        ? 0.0
        : AppNavBar.fadeHeight -
              (AppNavBar.bottomGap + AppNavBar.barHeight + AppNavBar.clearance);
    // Reduce-motion aware, like the predecessor bar.
    final motion = motionDuration(context, const Duration(milliseconds: 180));
    const radius = BorderRadius.all(Radius.circular(rNav));

    final bar = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: floatingShadow(t),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppNavBar.blurSigma,
            sigmaY: AppNavBar.blurSigma,
          ),
          child: DecoratedBox(
            key: const ValueKey<String>('nav-glass'),
            decoration: BoxDecoration(
              color: t.navGlass,
              borderRadius: radius,
              border: Border.all(color: t.lineStrong),
            ),
            // Own ink layer: the ripple would otherwise land on the Material
            // underneath the glass and be blurred away.
            child: Material(
              type: MaterialType.transparency,
              // Pill, colour and press frames stop here: the BackdropFilter
              // above is not repainted by them.
              child: RepaintBoundary(
                child: _NavPillTrack(
                  key: const ValueKey<String>('nav-pill'),
                  anchors: _anchors,
                  from: _pillFrom,
                  to: widget.index.toDouble(),
                  animation: _pill,
                  color: t.accentTintStrong,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppNavBar.barHeight,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        children: List<Widget>.generate(items.length, (i) {
                          return Expanded(
                            child: _NavItem(
                              item: items[i],
                              index: i,
                              anchors: _anchors,
                              active: i == widget.index,
                              motion: motion,
                              onTap: () => _select(i),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Stack(
      // The fade's overhang paints above the band.
      clipBehavior: Clip.none,
      children: <Widget>[
        // Decorative and never a hit target: taps in the fade and in the
        // gaps around the bar reach whatever lies underneath.
        Positioned(
          left: 0,
          top: -fadeOverhang,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Column(
              key: const ValueKey<String>('nav-fade'),
              children: <Widget>[
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[t.bg.withValues(alpha: 0), t.bg],
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: AppNavBar._fadeSolid + offset - AppNavBar.bottomGap,
                  width: double.infinity,
                  child: ColoredBox(color: t.bg),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppNavBar.sideGap,
            AppNavBar.clearance,
            AppNavBar.sideGap,
            offset,
          ),
          // Keeps the bar under the content column on large windows.
          child: ReadableWidth(child: bar),
        ),
      ],
    );
  }
}

/// One tab of the [AppNavBar]: icon in a 48x28 capsule over an 11 px label.
///
/// The capsule itself is painted by [_NavPillTrack]; the item only marks its
/// slot ([_PillAnchor]).
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.item,
    required this.index,
    required this.anchors,
    required this.active,
    required this.motion,
    required this.onTap,
  });

  final AppNavItem item;
  final int index;
  final _PillAnchors anchors;
  final bool active;
  final Duration motion;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  static const Duration _pressIn = Duration(milliseconds: 70);
  static const Duration _pressOut = Duration(milliseconds: 200);
  static const double _pressedScale = 0.9;

  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: _pressIn,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 1,
    end: _pressedScale,
  ).animate(_press);
  bool _down = false;

  void _onDown() {
    if (reducedMotion(context)) return;
    _down = true;
    _press.animateTo(1, duration: _pressIn, curve: Curves.easeOut);
  }

  void _onRelease() {
    _down = false;
    if (reducedMotion(context)) return;
    // A quick tap still dips all the way before it springs back.
    _press
        .animateTo(1, duration: _pressIn * (1 - _press.value))
        .whenCompleteOrCancel(() {
          if (mounted && !_down) {
            _press.animateBack(
              0,
              duration: _pressOut,
              curve: Curves.easeOutCubic,
            );
          }
        });
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final item = widget.item;
    final active = widget.active;
    return Semantics(
      selected: active,
      button: true,
      label: item.label,
      child: InkWell(
        key: ValueKey<String>('nav-${item.keyId}'),
        onTap: widget.onTap,
        onTapDown: (_) => _onDown(),
        onTapUp: (_) => _onRelease(),
        onTapCancel: _onRelease,
        borderRadius: BorderRadius.circular(rCard),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppNavBar.itemHeight),
          // Colour-only frames: text and glyph repaint, nothing re-lays out
          // (the label weight flips once, with the selection).
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: active ? 1 : 0),
            duration: widget.motion,
            curve: Curves.easeOut,
            builder: (context, selectedness, _) {
              final ink = Color.lerp(t.ink3, t.accentText, selectedness)!;
              return Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _PillAnchor(
                    anchors: widget.anchors,
                    index: widget.index,
                    child: SizedBox(
                      width: 48,
                      height: 28,
                      child: Center(
                        child: ScaleTransition(
                          scale: _scale,
                          child: AppIcon(
                            item.icon,
                            selected: active,
                            size: 22,
                            color: ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  // The label is already the item's Semantics label; without
                  // ExcludeSemantics it would be read twice. Hard single line:
                  // at textScaler 2.0 it would not fit into a fifth of the bar.
                  ExcludeSemantics(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: AppType.ui(
                        11,
                        weight: active ? FontWeight.w800 : FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The items' pill slots, by item index, for [_NavPillTrack] to measure.
class _PillAnchors {
  final Map<int, RenderBox> boxes = <int, RenderBox>{};
}

/// Marks the 48x28 slot the selected-item pill covers.
class _PillAnchor extends SingleChildRenderObjectWidget {
  const _PillAnchor({
    required this.anchors,
    required this.index,
    required super.child,
  });

  final _PillAnchors anchors;
  final int index;

  @override
  _RenderPillAnchor createRenderObject(BuildContext context) =>
      _RenderPillAnchor(anchors, index);

  @override
  void updateRenderObject(BuildContext context, _RenderPillAnchor renderObject) {
    renderObject
      ..anchors = anchors
      ..index = index;
  }
}

class _RenderPillAnchor extends RenderProxyBox {
  _RenderPillAnchor(this._anchors, this._index);

  _PillAnchors _anchors;
  set anchors(_PillAnchors value) {
    if (identical(value, _anchors)) return;
    _unregister();
    _anchors = value;
    _register();
  }

  int _index;
  set index(int value) {
    if (value == _index) return;
    _unregister();
    _index = value;
    _register();
  }

  void _register() {
    if (attached) _anchors.boxes[_index] = this;
  }

  void _unregister() {
    if (identical(_anchors.boxes[_index], this)) _anchors.boxes.remove(_index);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _register();
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }
}

/// Paints the selected-item pill behind its child, sliding between the
/// items' [_PillAnchor] slots as [animation] runs from [from] to [to].
///
/// The slots are measured at paint time, so the pill sits exactly where the
/// per-item capsule sat before, at any text scale and direction.
class _NavPillTrack extends SingleChildRenderObjectWidget {
  const _NavPillTrack({
    super.key,
    required this.anchors,
    required this.from,
    required this.to,
    required this.animation,
    required this.color,
    required super.child,
  });

  final _PillAnchors anchors;
  final double from;
  final double to;
  final Animation<double> animation;
  final Color color;

  @override
  _RenderNavPillTrack createRenderObject(BuildContext context) =>
      _RenderNavPillTrack(
        anchors: anchors,
        from: from,
        to: to,
        animation: animation,
        color: color,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNavPillTrack renderObject,
  ) {
    renderObject
      ..anchors = anchors
      ..from = from
      ..to = to
      ..animation = animation
      ..color = color;
  }
}

class _RenderNavPillTrack extends RenderProxyBox {
  _RenderNavPillTrack({
    required _PillAnchors anchors,
    required double from,
    required double to,
    required Animation<double> animation,
    required Color color,
  }) : _anchors = anchors,
       _from = from,
       _to = to,
       _animation = animation,
       _color = color;

  static const Curve _curve = Curves.easeOutCubic;

  /// Largest mid-travel stretch of the pill, in px.
  static const double _maxStretch = 12;

  /// Pill position (fractional item index) at progress [t] of a travel.
  static double positionAt(double from, double to, double t) =>
      from + (to - from) * _curve.transform(t);

  _PillAnchors _anchors;
  set anchors(_PillAnchors value) {
    if (identical(value, _anchors)) return;
    _anchors = value;
    markNeedsPaint();
  }

  double _from;
  set from(double value) {
    if (value == _from) return;
    _from = value;
    markNeedsPaint();
  }

  double _to;
  set to(double value) {
    if (value == _to) return;
    _to = value;
    markNeedsPaint();
  }

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  Rect? _slot(int index) {
    final box = _anchors.boxes[index];
    if (box == null || !box.attached || !box.hasSize) return null;
    return MatrixUtils.transformRect(
      box.getTransformTo(this),
      Offset.zero & box.size,
    );
  }

  Rect? _rectAt(double position) {
    final lo = position.floor();
    final a = _slot(lo);
    final b = _slot(position.ceil());
    if (a == null || b == null) return a ?? b;
    return Rect.lerp(a, b, position - lo);
  }

  /// The pill's rect in this box's coordinates, null before layout.
  Rect? get pillRect {
    final t = _animation.value;
    final base = _rectAt(positionAt(_from, _to, t));
    if (base == null || t >= 1) return base;
    final start = _rectAt(_from);
    final end = _rectAt(_to);
    if (start == null || end == null) return base;
    // Stretches with the travel speed, capped: a short hop barely morphs.
    final travel = (end.center.dx - start.center.dx).abs();
    final stretch =
        math.min(travel * 0.15, _maxStretch) *
        math.sin(math.pi * _curve.transform(t));
    return Rect.fromCenter(
      center: base.center,
      width: base.width + stretch,
      height: base.height,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final rect = pillRect;
    if (rect != null) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.shift(offset),
          const Radius.circular(rControl),
        ),
        Paint()..color = _color,
      );
    }
    super.paint(context, offset);
  }
}
