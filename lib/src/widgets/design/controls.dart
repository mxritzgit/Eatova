import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';

// ---------------------------------------------------------------------------
// CONTROLS — icon button, icon tile, toggle, segmented pill, filter chip,
// primary action, nav bar.
//
// Material carries behavior and semantics, the tokens carry the pixels.
//
// A11y rule for this file (DESIGN_REFACTOR §5): every duration goes through
// [motionDuration]. A hardcoded `Duration` ignores "reduce motion", and these
// blocks appear on EVERY screen.
// ---------------------------------------------------------------------------

/// Square 34 px bordered button — back, close, menu.
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
  Widget build(BuildContext context) {
    final t = context.t;
    // 34 px visible, 44 px tappable — the extra hit area is transparent and
    // sits outside the drawn surface.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
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
                child: Icon(icon, size: 17, color: t.ink2),
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
  const IconTile({super.key, required this.icon, this.color, this.size = 34});

  final IconData icon;
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
      child: Icon(
        icon,
        size: 16,
        color: color == null ? t.ink : t.readableOnTint(color!),
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
                    color: option == selected ? t.forest : Colors.transparent,
                    // Concentric with the 3 px padded outer capsule.
                    borderRadius: BorderRadius.circular(rChip - 3),
                  ),
                  child: Text(
                    option,
                    style: AppType.ui(
                      11,
                      weight: FontWeight.w600,
                      color: option == selected ? t.onForest : t.ink2,
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

/// Rectangular filter pill for horizontal chip bars.
///
/// ONE selection language for every chip in the app: selected = forest fill
/// with `onForest` text (and icon), unselected = `surf` with a `line` edge.
/// Radius [rChip].
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
    final fg = selected ? t.onForest : t.ink2;
    final fontSize = small ? 11.0 : 12.0;
    final padding = small
        ? const EdgeInsets.symmetric(horizontal: 11, vertical: 6)
        : const EdgeInsets.symmetric(horizontal: 15, vertical: 9);
    // Selection is carried by fill and text color alone; without `selected` in
    // the semantics tree a screen reader cannot tell which filter is active.
    // With an explicit spoken name the visible label is excluded, otherwise
    // the node would read "name, label" twice over.
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Material(
        color: selected ? t.forest : t.surf,
        borderRadius: BorderRadius.circular(rChip),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rChip),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(rChip),
              border: Border.all(color: selected ? Colors.transparent : t.line),
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
                      // On the forest fill the dot keeps its hue but must
                      // stay visible: onForest is the safe fallback.
                      color: selected ? t.onForest : (dotColor ?? fg),
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
                      weight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ),
              ],
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
/// The label uses [AppTokens.bg]: `ink` and `bg` are opposites in both modes,
/// and on `danger` too `bg` always keeps readable contrast. `onTap == null`
/// renders the visible disabled state (dimmed fill and label).
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
    // Disabled: the fill drops to 38 % (still 2.4:1 L / 3.2:1 D against
    // `surf`, 4.6+:1 to the enabled fill) and the label dims — a locked
    // CTA must not look pressable. InkWell without onTap draws no ripple.
    final fill = (destructive ? t.danger : t.ink)
        .withValues(alpha: enabled ? 1 : kDisabledFillAlpha);
    final onFill = t.bg.withValues(alpha: enabled ? 1 : 0.8);
    // A bare InkWell carries neither `isButton` nor an enabled state, so a
    // screen reader would announce the primary action as plain text and a
    // disabled one as a button that does nothing. `onTap == null` is the
    // app-wide disabled convention.
    return Semantics(
      button: true,
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                        weight: FontWeight.w700,
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
    );
  }
}

/// One entry of the [AppNavBar].
@immutable
class AppNavItem {
  const AppNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    String? keyId,
  }) : keyId = keyId ?? label;

  final IconData icon;
  final IconData activeIcon;

  /// The visible label — comes from the ARB and is translated.
  final String label;

  /// Carries the test key (`ValueKey('nav-$keyId')`). Stays GERMAN even when
  /// [label] is translated — keys are API (DESIGN_REFACTOR §6).
  final String keyId;
}

/// The bottom nav bar — lime capsule around the active icon.
class AppNavBar extends StatelessWidget {
  const AppNavBar({
    super.key,
    required this.index,
    required this.onChanged,
    required this.items,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final List<AppNavItem> items;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Reduce-motion aware, like the predecessor bar.
    final motion = motionDuration(context, const Duration(milliseconds: 180));

    return Container(
      decoration: BoxDecoration(
        color: t.surf.withValues(alpha: 0.94),
        border: Border(top: BorderSide(color: t.line)),
      ),
      // Flatter than the draft (~76 px): the bar sits on EVERY screen and takes
      // that height from the content. The hit area stays above 44 px — the
      // floor this shortening must not cross.
      padding: EdgeInsets.fromLTRB(10, 6, 10, 6 + bottomInset),
      child: Row(
        children: List<Widget>.generate(items.length, (i) {
          final item = items[i];
          final active = i == index;
          return Expanded(
            child: Semantics(
              selected: active,
              button: true,
              label: item.label,
              child: InkWell(
                key: ValueKey<String>('nav-${item.keyId}'),
                onTap: () => onChanged(i),
                borderRadius: BorderRadius.circular(rControl),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AnimatedContainer(
                        duration: motion,
                        curve: Curves.easeOut,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: active ? t.lime : Colors.transparent,
                          borderRadius: BorderRadius.circular(rChip),
                        ),
                        child: Icon(
                          active ? item.activeIcon : item.icon,
                          size: 19,
                          color: active ? t.onLime : t.ink2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // The label is already the item's Semantics label;
                      // without ExcludeSemantics it would be read twice.
                      // Hard single line: at textScaler 2.0 it would not fit
                      // into a third of the bar.
                      ExcludeSemantics(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: AppType.ui(
                            10,
                            weight: active ? FontWeight.w700 : FontWeight.w500,
                            color: active ? t.ink : t.ink2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
