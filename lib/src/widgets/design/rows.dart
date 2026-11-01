import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import 'controls.dart';
import 'surfaces.dart' show HeadingSemantics, SectionHeading;

// ---------------------------------------------------------------------------
// ROWS — page header, list section and list row (settings group and row as
// their older names).
//
// Colors from [AppTokens]; card, row and title geometry follow the dark
// redesign's tabs (polish 2026-10-02).
// ---------------------------------------------------------------------------

/// Shared header of a pushed page: back, title and an optional action.
///
/// [large] is a compatible alias for [title]; both use the same page scale.
///
/// [prominent] switches to the tab header language: a round back button on
/// its own row, then the title at the tabs' 36 px scale and an optional
/// [subtitle] below it.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    this.title,
    this.large,
    this.trailing,
    this.onBack,
    this.backKey,
    this.backEnabled = true,
    this.prominent = false,
    this.subtitle,
  });

  final String? title;
  final String? large;
  final Widget? trailing;

  /// Defaults to maybePop; pages with drafts can supply a discard prompt.
  final VoidCallback? onBack;

  /// Stable key for the back action.
  final Key? backKey;
  final bool backEnabled;

  /// Tab-scale title below a round back button.
  final bool prominent;

  /// Muted line under a [prominent] title; ignored otherwise.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final label = large ?? title ?? '';
    final onTap = backEnabled
        ? (onBack ?? () => Navigator.of(context).maybePop())
        : null;
    if (prominent) return _buildProminent(context, label, onTap);
    // Round like every other back button since 2026-11-01 (it was a 34 px
    // square); same 44 px footprint.
    final back = HeaderIconButton(
      key: backKey,
      icon: AppIcons.chevronLeft,
      onTap: onTap,
      semanticLabel: context.l10n.onboardingBackSemanticLabel,
    );
    final style = AppType.pageTitle(context.t.ink, subpage: true);
    Widget titleText({TextScaler? scaler}) => label.isEmpty
        ? const SizedBox.shrink()
        : HeadingSemantics(
            level: 1,
            child: Text(label, style: style, textScaler: scaler),
          );
    final heading = titleText();
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep full titles readable when back and actions would squeeze them.
        final stacked =
            constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(24) > 32;
        if (stacked && label.isNotEmpty) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [back, const Spacer(), ?trailing]),
              const SizedBox(height: 10),
              // Words wrap, they never split ("Einstellung/en" at 2x on a
              // 320 px phone).
              titleText(
                scaler: AppType.wholeWordScaler(
                  context,
                  text: label,
                  style: style,
                  scaler: MediaQuery.textScalerOf(context),
                  maxWidth: constraints.maxWidth,
                ),
              ),
            ],
          );
        }
        return Row(
          children: [
            back,
            const SizedBox(width: 12),
            Expanded(child: heading),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        );
      },
    );
  }

  Widget _buildProminent(
    BuildContext context,
    String label,
    VoidCallback? onTap,
  ) {
    final t = context.t;
    final style = AppType.pageTitle(t.ink);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            HeaderIconButton(
              key: backKey,
              icon: AppIcons.chevronLeft,
              onTap: onTap,
              semanticLabel: context.l10n.onboardingBackSemanticLabel,
            ),
            const Spacer(),
            ?trailing,
          ],
        ),
        if (label.isNotEmpty) ...<Widget>[
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) => HeadingSemantics(
              level: 1,
              child: Text(
                label,
                style: style,
                textScaler: _wholeWordScaler(
                  context,
                  label,
                  style,
                  constraints.maxWidth,
                ),
              ),
            ),
          ),
        ],
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            style: AppType.ui(
              15,
              weight: FontWeight.w500,
              color: t.ink2,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }

  /// The tab title scaler, lowered just enough that the widest word still
  /// fits one line: "Einstellungen" at 60 px would otherwise break mid-word on
  /// a 320 px phone. Words wrap; they never split.
  static TextScaler _wholeWordScaler(
    BuildContext context,
    String label,
    TextStyle style,
    double maxWidth,
  ) => AppType.wholeWordScaler(
    context,
    text: label,
    style: style,
    scaler: AppType.pageTitleScaler(context),
    maxWidth: maxWidth,
  );
}

// ---------------------------------------------------------------------------
// LISTS (UI polish 2026-11-01): one row anatomy for settings, goals, pickers
// and every list of rows on a card.
//
//   | 18 | badge md 40 | 14 | title 15/600, subtitle 13 | 12 | value | 6 | › | 18 |
//
// Hairlines start at the text column; the chevron follows [ListTrailing].
// ---------------------------------------------------------------------------

/// What a [ListRow] shows at its end.
enum ListTrailing {
  /// `›` (20 px, `ink3`): ONLY when the row opens a page or sheet to
  /// navigate to.
  chevron,

  /// The open-in-new glyph (18 px, `ink3`): a link out of the app (legal
  /// pages, system settings).
  external,

  /// An accent check on the chosen option of a picker list
  /// ([ListRow.selected]); the other rows keep its space empty.
  check,

  /// An [AppToggle] ([ListRow.toggled], [ListRow.onToggle]); the whole row
  /// switches.
  toggle,

  /// The [ListRow.value] alone, no glyph: a value without navigation.
  value,

  /// Nothing: ACTIONS (sign out, delete, export) carry no chevron, the HIG
  /// keeps disclosure for hierarchy.
  none,
}

/// Where the hairlines between the rows of a [ListSection] start.
enum ListDividerInset {
  /// At the text column behind a 40 px badge (`md`): 18 + 40 + 14 = 72.
  text(kCardInset + 40 + kRowLeadingGap),

  /// At the text column behind a 44 px badge (`lg`): 76.
  textLg(kCardInset + 44 + kRowLeadingGap),

  /// At the card's inner margin, 18: rows without a leading element.
  edge(kCardInset);

  const ListDividerInset(this.indent);

  final double indent;
}

/// From about 1.6x text a [ListRow]'s leading badge moves above its text
/// (beside it the text would shrink to a few words per line), and the
/// hairlines of its [ListSection] start at the card margin.
bool listRowStacked(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(15) > 24;

/// A grouped list: an optional [SectionHeading] (with an [action] such as
/// "All"), one card of [ListRow]s separated by hairlines that start at the
/// text column ([inset]), an optional [footnote] under the card and a
/// [footer] widget (a separate card of the same section). [spacing] is the
/// room below the section, [kSectionGap] by default.
class ListSection extends StatelessWidget {
  const ListSection({
    super.key,
    this.title,
    this.action,
    required this.children,
    this.footnote,
    this.footer,
    this.inset = ListDividerInset.text,
    this.spacing = kSectionGap,
  });

  final String? title;

  /// A link at the heading's end, usually an [EatovaTextAction].
  final Widget? action;

  final List<Widget> children;

  /// Muted line under the card (`subhead`, `ink2`).
  final String? footnote;

  final Widget? footer;
  final ListDividerInset inset;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final indent = listRowStacked(context) ? kCardInset : inset.indent;
    return Padding(
      padding: EdgeInsets.only(bottom: spacing),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (title != null) ...<Widget>[
            SectionHeading(title: title!, action: action),
            const SizedBox(height: kSpace12),
          ],
          if (children.isNotEmpty)
            Material(
              color: t.surf,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rCard),
                side: BorderSide(color: t.cardBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var i = 0; i < children.length; i++) ...<Widget>[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: indent,
                        endIndent: kCardInset,
                        color: t.line,
                      ),
                    children[i],
                  ],
                ],
              ),
            ),
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, kSpace8, 2, 0),
              child: Text(footnote!, style: AppType.subhead(t.ink2)),
            ),
          if (footer != null) ...<Widget>[
            if (children.isNotEmpty || footnote != null)
              const SizedBox(height: kSpace12),
            footer!,
          ],
        ],
      ),
    );
  }
}

/// One row of a [ListSection].
///
/// Leading: an [icon] (drawn as an [IconBadge] `md`, tinted `danger` when
/// [destructive]) or any [leading] widget (a photo with [rThumb], a
/// [SlotIconTile]). Then [title] (`rowTitle`), [subtitle] (`subhead`), a
/// right-aligned [value] (14/600, tabular; a value wider than 45 % of the
/// row moves under the title), an optional [end] widget and the [trailing]
/// mark. [below] holds a control on its own line (segments, a retry).
///
/// Min height 56, 14 px vertical padding (68 with a badge); 18 px sides.
/// A press tints the row with the theme highlight, no scale (rows are tapped
/// often); keyboard focus with the theme focus colour; [enabled] false dims
/// it to 45 %. The row is ONE semantics node: title, subtitle and value in
/// one label, a button when it has [onTap], `toggled` for a toggle row,
/// `selected` for the chosen picker row.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.icon,
    this.leading,
    this.trailing = ListTrailing.none,
    this.end,
    this.below,
    this.onTap,
    this.selected = false,
    this.toggled,
    this.onToggle,
    this.toggleKey,
    this.destructive = false,
    this.enabled = true,
    this.dense = false,
  }) : _titleColor = null,
       _merge = true;

  /// [SettingsRow]'s path: its old semantics (no merged node) and its
  /// recoloured, bolder title.
  const ListRow._compat({
    required this.title,
    this.subtitle,
    this.value,
    this.leading,
    this.trailing = ListTrailing.none,
    this.end,
    this.onTap,
    this.dense = false,
    Color? titleColor,
  }) : icon = null,
       below = null,
       selected = false,
       toggled = null,
       onToggle = null,
       toggleKey = null,
       destructive = false,
       enabled = true,
       _titleColor = titleColor,
       _merge = false;

  final String title;
  final String? subtitle;

  /// Right-aligned state text ("Metric", "On", "72 kg").
  final String? value;

  /// The row's glyph, drawn as an [IconBadge] `md`. [leading] wins.
  final IconData? icon;
  final Widget? leading;
  final ListTrailing trailing;

  /// An extra widget before the [trailing] mark (a [StatusPill], say).
  final Widget? end;

  /// A control on its own line under the row, outside the row's tap area.
  final Widget? below;

  /// Ignored for [ListTrailing.toggle]: there the row calls [onToggle].
  final VoidCallback? onTap;

  /// The chosen option of a [ListTrailing.check] row.
  final bool selected;

  /// The switch state of a [ListTrailing.toggle] row.
  final bool? toggled;

  /// Null locks the toggle (dimmed, deaf), the row included.
  final ValueChanged<bool>? onToggle;

  /// Goes on the [AppToggle] of a toggle row.
  final Key? toggleKey;

  /// Title in `danger`, the badge tinted `danger`.
  final bool destructive;

  final bool enabled;

  /// Tighter rhythm for long option lists (picker sheets): 52 / 11.
  final bool dense;

  final Color? _titleColor;
  final bool _merge;

  /// Share of the row a value may take before it moves under the title.
  static const double _valueShare = 0.45;

  Widget? _mark(AppTokens t) => switch (trailing) {
    ListTrailing.chevron => Icon(
      AppIcons.chevronRight,
      size: AppIconSize.standard,
      color: t.ink3,
    ),
    ListTrailing.external => Icon(
      AppIcons.openInNew,
      size: AppIconSize.button,
      color: t.ink3,
    ),
    ListTrailing.check =>
      selected
          ? Icon(
              AppIcons.check,
              size: AppIconSize.standard,
              color: t.accentText,
            )
          : const SizedBox.square(dimension: AppIconSize.standard),
    ListTrailing.toggle => AppToggle(
      key: toggleKey,
      value: toggled ?? false,
      enabled: enabled && onToggle != null,
      onChanged: onToggle ?? (_) {},
    ),
    ListTrailing.value || ListTrailing.none => null,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final isToggle = trailing == ListTrailing.toggle;
    final VoidCallback? tap = !enabled
        ? null
        : isToggle
        ? (onToggle == null ? null : () => onToggle!(!(toggled ?? false)))
        : onTap;
    final bold = _titleColor != null;
    final titleStyle = AppType.ui(
      15,
      weight: bold ? FontWeight.w700 : FontWeight.w600,
      color: _titleColor ?? (destructive ? t.danger : t.ink),
    );
    final valueStyle = AppType.ui(
      14,
      weight: FontWeight.w600,
      color: t.inkMuted,
      tabular: true,
    );
    final lead =
        leading ??
        (icon == null
            ? null
            : IconBadge(icon: icon, color: destructive ? t.danger : null));
    final mark = _mark(t);
    final stacked = listRowStacked(context) && lead != null;

    Widget row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: dense ? 52 : 56),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: kCardInset,
          vertical: dense ? 11 : 14,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The value's box also holds its kSpace12 gap to the title.
            final stackValue =
                value != null &&
                (stacked ||
                    _textWidth(context, value!, valueStyle) >
                        constraints.maxWidth * _valueShare - kSpace12);
            final texts = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: titleStyle),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: AppType.subhead(t.ink2)),
                ],
                if (stackValue) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(value!, style: valueStyle),
                ],
              ],
            );
            final tail = <Widget>[
              if (value != null && !stackValue)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * _valueShare,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: kSpace12),
                    child: Text(
                      value!,
                      textAlign: TextAlign.right,
                      style: valueStyle,
                    ),
                  ),
                ),
              if (end != null)
                Padding(
                  padding: const EdgeInsets.only(left: kSpace12),
                  child: end,
                ),
              if (mark != null)
                Padding(
                  // The glyphs sit closer to the value than a control does.
                  padding: EdgeInsets.only(
                    left: trailing == ListTrailing.chevron ||
                            trailing == ListTrailing.external
                        ? 6
                        : kSpace12,
                  ),
                  child: mark,
                ),
            ];
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(children: <Widget>[lead, const Spacer(), ...tail]),
                  const SizedBox(height: 10),
                  texts,
                ],
              );
            }
            return Row(
              children: <Widget>[
                if (lead != null) ...<Widget>[
                  lead,
                  const SizedBox(width: kRowLeadingGap),
                ],
                Expanded(child: texts),
                ...tail,
              ],
            );
          },
        ),
      ),
    );
    row = InkWell(onTap: tap, child: row);
    if (_merge) {
      row = MergeSemantics(
        child: Semantics(
          button: tap != null && !isToggle,
          enabled: enabled,
          selected: trailing == ListTrailing.check ? selected : null,
          // A check row is one option of a picker: announced as a choice in
          // a group, as the settings pickers were before the list rows.
          inMutuallyExclusiveGroup: trailing == ListTrailing.check
              ? true
              : null,
          child: row,
        ),
      );
    }
    if (below != null) {
      row = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          row,
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kCardInset,
              0,
              kCardInset,
              kSpace12 + 2,
            ),
            child: below,
          ),
        ],
      );
    }
    return enabled ? row : Opacity(opacity: kDisabledAlpha, child: row);
  }

  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

/// A [ListSection] under its older name: since 2026-11-01 the heading is a
/// [SectionHeading] instead of an all-caps caption, and the hairlines start
/// at the card margin (its rows rarely lead with a badge). New code uses
/// [ListSection].
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.label,
    required this.children,
  });

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListSection(
    title: label,
    inset: ListDividerInset.edge,
    children: children,
  );
}

/// A [ListRow] under its older name, with its older API: a custom
/// [trailing] widget before the chevron, [chevron] on by default, and
/// [titleColor] for destructive rows (one weight step bolder). Its
/// semantics stay as they were (no merged node). New code uses [ListRow].
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.leading,
    this.trailing,
    this.chevron = true,
    this.onTap,
    this.titleColor,
    this.dense = false,
  });

  final String title;
  final String? subtitle;

  /// Right-aligned state text ("Metric", "On").
  final String? value;

  final Widget? leading;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;

  /// Recolors the title (e.g. [AppTokens.danger] for destructive rows) and
  /// bumps it one weight step.
  final Color? titleColor;

  /// Tighter vertical rhythm for long option lists (picker sheets).
  final bool dense;

  @override
  Widget build(BuildContext context) => ListRow._compat(
    title: title,
    subtitle: subtitle,
    value: value,
    leading: leading,
    end: trailing,
    trailing: chevron ? ListTrailing.chevron : ListTrailing.none,
    onTap: onTap,
    titleColor: titleColor,
    dense: dense,
  );
}
