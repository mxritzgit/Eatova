import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

/// Edge padding of a [SettingsStudioRow] inside its card.
const double kSettingsRowPad = 18;

/// Edge length of the icon tile that leads a [SettingsStudioRow].
const double kSettingsTileSize = 40;

/// Gap between the icon tile and the row's text.
const double kSettingsTileGap = 14;

/// Where a row's text column starts inside the card.
const double kSettingsTextInset = kSettingsTileSize + kSettingsTileGap;

/// From about 1.6x system font the tile moves above the text: beside it, it
/// would squeeze the text into a column a few words wide.
bool settingsTileStacked(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(15) > 24;

/// A settings section: a display heading over one large-radius card whose
/// rows are separated by hairlines that start at the text column, like the
/// Food diary card. [footer] sits below the card inside the same section
/// (the separate delete card of the account section).
class SettingsStudioGroup extends StatelessWidget {
  const SettingsStudioGroup({
    super.key,
    required this.label,
    required this.children,
    this.labelColor,
    this.footer,
  });

  final String label;
  final List<Widget> children;
  final Color? labelColor;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeadingSemantics(
            level: 2,
            child: Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 12),
              child: Text(
                label,
                style: AppType.display(
                  19,
                  weight: FontWeight.w700,
                  color: labelColor ?? t.ink,
                ),
              ),
            ),
          ),
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
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: settingsTileStacked(context)
                            ? kSettingsRowPad
                            : kSettingsRowPad + kSettingsTextInset,
                        endIndent: kSettingsRowPad,
                        color: t.line,
                      ),
                    children[i],
                  ],
                ],
              ),
            ),
          if (footer != null) ...[
            if (children.isNotEmpty) const SizedBox(height: 12),
            footer!,
          ],
        ],
      ),
    );
  }
}

/// The icon tile of a settings row: a 40 px rounded square in the neutral
/// tile tone, or tinted by [tone] (danger, warning, accent).
class SettingsRowTile extends StatelessWidget {
  const SettingsRowTile({super.key, required this.icon, this.tone});

  final IconData icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ton = tone;
    return Container(
      width: kSettingsTileSize,
      height: kSettingsTileSize,
      decoration: BoxDecoration(
        color: ton == null ? t.tile : ton.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(rChip),
      ),
      // On a tint the glyph needs [AppTokens.readableOnTint] to hold 3:1.
      child: Icon(
        icon,
        size: 20,
        color: ton == null ? t.inkMuted : t.readableOnTint(ton),
      ),
    );
  }
}

/// A row of a [SettingsStudioGroup]: icon tile, title and subtitle, and a
/// chevron (or [endIcon]) when it leads somewhere. [trailing] is a control
/// that takes its own line under the text (segments, a retry button), so it
/// keeps its full width at large text sizes.
class SettingsStudioRow extends StatelessWidget {
  const SettingsStudioRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.chevron = true,
    this.endIcon,
    this.onTap,
    this.titleColor,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool chevron;
  final IconData? endIcon;
  final VoidCallback? onTap;

  /// Recolors the title, e.g. [AppTokens.danger] for a destructive row.
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final stacked = settingsTileStacked(context);
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppType.ui(
            15,
            weight: titleColor == null ? FontWeight.w600 : FontWeight.w700,
            color: titleColor ?? t.ink,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(
            subtitle!,
            style: AppType.ui(13, color: t.ink2, height: 1.35),
          ),
        ],
      ],
    );
    final end = (chevron || endIcon != null) && onTap != null
        ? Icon(
            endIcon ?? Icons.chevron_right_rounded,
            size: endIcon == null ? 22 : 18,
            color: t.ink3,
          )
        : null;
    final tile = leading == null ? null : ExcludeSemantics(child: leading!);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: 14,
            horizontal: kSettingsRowPad,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stacked && tile != null) ...[
                Row(children: [tile, const Spacer(), ?end]),
                const SizedBox(height: 10),
                texts,
              ] else
                Row(
                  children: [
                    if (tile != null) ...[
                      tile,
                      const SizedBox(width: kSettingsTileGap),
                    ],
                    Expanded(child: texts),
                    if (end != null) ...[const SizedBox(width: 10), end],
                  ],
                ),
              if (trailing != null) ...[const SizedBox(height: 14), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}
