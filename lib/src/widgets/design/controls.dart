import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import 'app_icon.dart';
import 'readable_width.dart';

// ---------------------------------------------------------------------------
// CONTROLS — icon buttons, icon tile, toggle, segmented pill, filter chip,
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

/// Square 34 px bordered button — back, close, menu.
class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.semanticLabel,
  }) : _child = null;

  const SquareIconButton.custom({
    super.key,
    required Widget child,
    this.onTap,
    this.semanticLabel,
  }) : icon = null,
       _child = child;

  final IconData? icon;
  final Widget? _child;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // 34 px visible, 44 px tappable — the extra hit area is transparent and
    // sits outside the drawn surface.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      child: PressScale(
        enabled: onTap != null,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(rChip),
            child: Center(
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: t.surf,
                  borderRadius: BorderRadius.circular(rChip),
                  border: Border.all(color: t.line),
                ),
                child: _child == null
                    ? Icon(icon, size: 17, color: t.ink2)
                    : IconTheme(
                        data: IconThemeData(size: 20, color: t.ink2),
                        child: Center(child: _child),
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

/// Emphasis of a [HeaderIconButton].
enum HeaderIconTone {
  /// Card fill with a faint outline: calendar, history, info.
  neutral,

  /// Accent fill: the one primary action of a header (e.g. "add").
  primary,
}

/// Round 44 px icon button for tab headers (dark redesign, 2026-09-28).
///
/// Neutral = card fill, 1 px [AppTokens.lineStrong] outline, icon in
/// [AppTokens.inkMuted]; primary = accent fill with an on-accent icon and no
/// outline. The whole circle is the tap target.
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
  Widget build(BuildContext context) {
    final t = context.t;
    final primary = tone == HeaderIconTone.primary;
    final ink = primary ? t.onAccentFill : t.inkMuted;
    // No excludeSemantics: it would drop the InkWell's tap action; the glyph
    // itself carries no label, so nothing is read twice.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      child: PressScale(
        enabled: onTap != null,
      child: Material(
        color: primary ? t.accentFill : t.surf,
        shape: CircleBorder(
          side: primary ? BorderSide.none : BorderSide(color: t.lineStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: size,
            child: IconTheme(
              data: IconThemeData(size: 20, color: ink),
              child: Center(child: _child ?? Icon(icon)),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Faintly tinted tile behind an icon (list rows, stats).
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color, this.size = 34})
    : _child = null;

  const IconTile.custom({
    super.key,
    required Widget child,
    this.color,
    this.size = 34,
  }) : icon = null,
       _child = child;

  final IconData? icon;
  final Widget? _child;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color == null ? t.tile : color!.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(rChip),
      ),
      // Not the full category color: the glyph would sit on its OWN 15 % tint
      // at ~2.2:1 in light mode — that is what [AppTokens.readableOnTint] is
      // for. Without a color the glyph sits on `tile` and stays `ink`.
      child: _child == null
          ? Icon(
              icon,
              size: 16,
              color: color == null ? t.ink : t.readableOnTint(color!),
            )
          : Center(
              child: IconTheme(
                data: IconThemeData(
                  size: 16,
                  color: color == null ? t.ink : t.readableOnTint(color!),
                ),
                child: _child,
              ),
            ),
    );
  }
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
                // OFF: track ink2@35 %, knob edge full ink2 — `tile`/`line`
                // were under 1.4:1 everywhere. The track itself is only
                // ~1.7:1 (L) / 1.8:1 (D) against the card: WCAG 1.4.11 asks
                // 3:1 for the component BOUNDARY, and that is the knob's ink2
                // ring — 3.3–3.5:1 against the track, 5.7+ against card and
                // knob. A 3:1 track would need ink2@75 % and eat the knob.
                decoration: BoxDecoration(
                  color: value ? t.forest : t.ink2.withValues(alpha: 0.35),
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
                      color: value ? t.lime : t.surf,
                      shape: BoxShape.circle,
                      border: value ? null : Border.all(color: t.ink2),
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

/// Two or three mutually exclusive short options (kg/lb, week/month).
///
/// NO CALLER IN `lib/` TODAY — grep finds this definition and three test
/// suites, nothing else. It stays because it is the segmented control of the
/// design library (DESIGN_REFACTOR §4 lists it beside [FilterChipPill]) and
/// because the live implementation, `_SettingsChoicePill`, is a copy of its
/// geometry: a fix that lands here and not there would drift them apart. Both
/// therefore carry [SelectionTone]. Delete it together with the doc entry the
/// day the settings pills move into this file.
class SegmentedPill extends StatelessWidget {
  const SegmentedPill({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final motion = motionDuration(context, const Duration(milliseconds: 160));
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rChip),
      ),
      // Wrap instead of Row: identical at normal font size, but wraps at
      // textScaler 2.0 instead of overflowing.
      child: Wrap(
        spacing: 0,
        runSpacing: 3,
        children: <Widget>[
          for (final option in options)
            // Like [FilterChipPill]: a bare GestureDetector carries neither
            // `isButton` nor the selection.
            Semantics(
              button: true,
              selected: option == selected,
              child: GestureDetector(
                onTap: () => onChanged(option),
                child: AnimatedContainer(
                  duration: motion,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                  decoration: BoxDecoration(
                    color: option == selected
                        ? t.selectedFill
                        : Colors.transparent,
                    // Concentric with the 3 px padded outer capsule.
                    borderRadius: BorderRadius.circular(rChip - 3),
                  ),
                  child: Text(
                    option,
                    style: AppType.ui(
                      11,
                      weight: FontWeight.w600,
                      color: option == selected ? t.onSelected : t.ink2,
                    ),
                  ),
                ),
              ),
            ),
        ],
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
/// `inkMuted` label. Fully round; the [FilterChipSize.md] chip is 42 px tall
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
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

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
    return Semantics(
      button: true,
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
            // 42 px including the padding; the Row centres its content.
            constraints: BoxConstraints(minHeight: small ? 0 : 42),
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
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
                  Icon(icon, size: small ? 13 : 15, color: fg),
                  SizedBox(width: small ? 4 : 6),
                ],
                Flexible(
                  child: Text(
                    label,
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
  }
}

/// Fill opacity of a disabled [PrimaryActionButton].
const double kDisabledFillAlpha = 0.38;

/// The wide primary action at the foot of a screen.
///
/// Dark redesign (2026-09-28): an accent pill ([AppTokens.accentFill]) with an
/// [AppTokens.onAccentFill] label in weight 800. The destructive variant keeps
/// `danger` with a `bg` label. `onTap == null` renders the visible disabled
/// state (dimmed fill and label).
class PrimaryActionButton extends StatelessWidget {
  const PrimaryActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.destructive = false,
    this.height = kPrimaryButtonHeight,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool destructive;

  /// Minimum height; [kPrimaryButtonHeight] is the app-wide default.
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    // Disabled: the fill drops to 38 % and the label dims — a locked CTA must
    // not look pressable. InkWell without onTap draws no ripple.
    final fill = (destructive ? t.danger : t.accentFill)
        .withValues(alpha: enabled ? 1 : kDisabledFillAlpha);
    final onFill = (destructive ? t.bg : t.onAccentFill)
        .withValues(alpha: enabled ? 1 : 0.8);
    // A bare InkWell carries neither `isButton` nor an enabled state, so a
    // screen reader would announce the primary action as plain text and a
    // disabled one as a button that does nothing. `onTap == null` is the
    // app-wide disabled convention.
    return Semantics(
      button: true,
      enabled: enabled,
      child: PressScale(
        enabled: enabled,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(rButton),
        elevation: 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rButton),
          child: ConstrainedBox(
            // Min height, not a fixed one: at textScaler 2.0 the label would
            // be taller than the button.
            constraints: BoxConstraints(minHeight: height),
            child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 18, color: onFill),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w800,
                        color: onFill,
                      ),
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
  }
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
