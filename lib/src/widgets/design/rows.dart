import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import 'controls.dart';
import 'surfaces.dart' show HeadingSemantics;

// ---------------------------------------------------------------------------
// ROWS — page header, settings group, settings row.
//
// Geometry 1:1 from the design template; colors from [AppTokens].
// ---------------------------------------------------------------------------

/// Header of a subpage: back button plus title.
///
/// [title] sets a small centered title, [large] a big left-aligned one. Setting
/// both is pointless — [large] wins.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    this.title,
    this.large,
    this.trailing,
    this.onBack,
    this.backKey,
  });

  final String? title;
  final String? large;
  final Widget? trailing;

  /// Defaults to [NavigatorState.maybePop]; screens with unsaved changes hook
  /// their discard prompt in here.
  final VoidCallback? onBack;

  /// Goes on the back button (tests tap e.g. `profile-close`).
  final Key? backKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final centered = title ?? '';
    return Row(
      children: <Widget>[
        SquareIconButton(
          key: backKey,
          icon: Icons.chevron_left_rounded,
          onTap: onBack ?? () => Navigator.of(context).maybePop(),
          // Reuses [onboardingBackSemanticLabel] instead of adding a second key
          // with the same meaning; the onboarding back button carries identical
          // text. A semantics label is SPOKEN text, so it must use real
          // umlauts — TalkBack reads "Zurueck" as "zurookk".
          semanticLabel: context.l10n.onboardingBackSemanticLabel,
        ),
        if (large != null) ...<Widget>[
          const SizedBox(width: 12),
          Expanded(
            // Only the title is the jump mark: back button and [trailing] are
            // siblings in this Row and keep their own nodes and tap actions.
            child: HeadingSemantics(
              level: 1,
              child: Text(
                large!,
                style: AppType.display(28, color: t.ink, height: 1.1),
              ),
            ),
          ),
        ] else
          Expanded(
            child: Center(
              // An unnamed header would be a jump mark with nothing to read,
              // so the annotation only goes on real text.
              child: _maybeHeading(
                level: 1,
                enabled: centered.isNotEmpty,
                child: Text(
                  centered,
                  textAlign: TextAlign.center,
                  style: AppType.ui(13, weight: FontWeight.w600, color: t.ink),
                ),
              ),
            ),
          ),
        if (trailing != null)
          trailing!
        else if (large == null)
          // Counterweight to the back button so the centered title really is
          // centered.
          const SizedBox(width: 34),
      ],
    );
  }
}

/// [child] as a heading of [level] when [enabled], otherwise untouched.
Widget _maybeHeading({
  required int level,
  required bool enabled,
  required Widget child,
}) =>
    enabled ? HeadingSemantics(level: level, child: child) : child;

/// Card with an all-caps label above it; children separated by 1 px lines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.label,
    required this.children,
    this.labelColor,
    this.borderColor,
  });

  final String label;
  final List<Widget> children;
  final Color? labelColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          // The caption is the only section marker the settings pages have;
          // without it those screens offer a single jump mark for the whole
          // list. Same rank as [SectionHeading].
          child: HeadingSemantics(
            level: 2,
            child: Text(label, style: AppType.eyebrow(labelColor ?? t.ink2)),
          ),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rCard),
            border: Border.all(color: borderColor ?? t.line),
          ),
          child: Column(
            children: <Widget>[
              for (var i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0) Divider(height: 1, thickness: 1, color: t.line),
                children[i],
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}

/// A row inside a [SettingsGroup].
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

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: AppType.ui(
                      13.5,
                      weight:
                          titleColor == null ? FontWeight.w600 : FontWeight.w700,
                      color: titleColor ?? t.ink,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: AppType.ui(11.5, color: t.ink2)),
                  ],
                ],
              ),
            ),
            // Deviates from the template, where the value is rigid: at
            // textScaler 2.0 a long e-mail address would overflow the row.
            if (value != null)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    value!,
                    textAlign: TextAlign.right,
                    style:
                        AppType.ui(12.5, weight: FontWeight.w500, color: t.ink2),
                  ),
                ),
              ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: trailing!,
              ),
            if (chevron)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 17,
                  color: t.ink2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
