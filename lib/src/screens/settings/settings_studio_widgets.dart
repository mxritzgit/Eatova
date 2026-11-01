import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

// ---------------------------------------------------------------------------
// The settings page's names for the shared list anatomy (UI polish
// 2026-11-01): a group is a [ListSection], a row a [ListRow], its tile an
// [IconBadge] `md`. The names stay for keys, finders and the settings
// helpers; the look lives in the design library.
// ---------------------------------------------------------------------------

/// Edge padding of a settings row inside its card.
const double kSettingsRowPad = kCardInset;

/// Edge length of the badge that leads a settings row ([IconBadgeSize.md]).
const double kSettingsTileSize = 40;

/// Gap between the badge and the row's text.
const double kSettingsTileGap = kRowLeadingGap;

/// Where a row's text column starts inside the card.
const double kSettingsTextInset = kSettingsTileSize + kSettingsTileGap;

/// From about 1.6x system font the badge moves above the text: beside it, it
/// would squeeze the text into a column a few words wide.
bool settingsTileStacked(BuildContext context) => listRowStacked(context);

/// A settings section: a [ListSection] with its heading, one card of rows
/// separated at the text column, and [footer] below the card inside the same
/// section (the separate delete card of the account section).
class SettingsStudioGroup extends StatelessWidget {
  const SettingsStudioGroup({
    super.key,
    required this.label,
    required this.children,
    this.footer,
  });

  final String label;
  final List<Widget> children;
  final Widget? footer;

  @override
  Widget build(BuildContext context) =>
      ListSection(title: label, footer: footer, children: children);
}

/// The badge of a settings row: an [IconBadge] `md`, neutral or tinted by
/// [tone] (danger, warning, accent).
class SettingsRowTile extends StatelessWidget {
  const SettingsRowTile({super.key, required this.icon, this.tone});

  final IconData icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) => IconBadge(icon: icon, color: tone);
}

/// A row of a [SettingsStudioGroup]: a [ListRow] with badge, title and
/// subtitle. It ends in a chevron when it opens a page or sheet, in the
/// open-in-new mark when [external] (it leaves the app), and in nothing for
/// an action ([chevron] false). [trailing] is a control on its own line under
/// the text (segments, a retry button), so it keeps its full width at large
/// text sizes and stays outside the row's tap area.
class SettingsStudioRow extends StatelessWidget {
  const SettingsStudioRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.chevron = true,
    this.external = false,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool chevron;
  final bool external;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListRow(
    title: title,
    subtitle: subtitle,
    leading: leading,
    below: trailing,
    trailing: onTap == null
        ? ListTrailing.none
        : external
        ? ListTrailing.external
        : chevron
        ? ListTrailing.chevron
        : ListTrailing.none,
    onTap: onTap,
  );
}
