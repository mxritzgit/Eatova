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

/// Shared header of a pushed page: back, title and an optional action.
///
/// [large] is a compatible alias for [title]; both use the same page scale.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    this.title,
    this.large,
    this.trailing,
    this.onBack,
    this.backKey,
    this.backEnabled = true,
  });

  final String? title;
  final String? large;
  final Widget? trailing;

  /// Defaults to maybePop; pages with drafts can supply a discard prompt.
  final VoidCallback? onBack;

  /// Stable key for the back action.
  final Key? backKey;
  final bool backEnabled;

  @override
  Widget build(BuildContext context) {
    final label = large ?? title ?? '';
    final back = SquareIconButton(
      key: backKey,
      icon: Icons.chevron_left_rounded,
      onTap: backEnabled
          ? (onBack ?? () => Navigator.of(context).maybePop())
          : null,
      semanticLabel: context.l10n.onboardingBackSemanticLabel,
    );
    final heading = label.isEmpty
        ? const SizedBox.shrink()
        : HeadingSemantics(
            level: 1,
            child: Text(
              label,
              style: AppType.pageTitle(context.t.ink, subpage: true),
            ),
          );
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
              heading,
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
}

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
