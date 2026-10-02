import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import 'controls.dart';
import 'surfaces.dart' show HeadingSemantics;

// ---------------------------------------------------------------------------
// ROWS — page header, settings group, settings row.
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
    final back = SquareIconButton(
      key: backKey,
      icon: Icons.chevron_left_rounded,
      onTap: onTap,
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
              icon: Icons.chevron_left_rounded,
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
  ) {
    final scaler = AppType.pageTitleScaler(context);
    if (!maxWidth.isFinite || maxWidth <= 0) return scaler;
    var widest = 0.0;
    for (final word in label.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(text: word, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    if (widest <= maxWidth) return scaler;
    final size = style.fontSize ?? 36;
    return TextScaler.linear(scaler.scale(size) / size * maxWidth / widest);
  }
}

/// Card with an all-caps label above it; children separated by hairlines.
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
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          // The caption is the only section marker the settings pages have;
          // without it those screens offer a single jump mark for the whole
          // list. Same rank as [SectionHeading]. Drawn in capitals like the
          // tabs' eyebrows ("LOGGED"), read in its own case.
          child: HeadingSemantics(
            level: 2,
            child: Text(
              label.toUpperCase(),
              semanticsLabel: label,
              style: AppType.sectionEyebrow(labelColor ?? t.ink2),
            ),
          ),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rCard),
            border: Border.all(color: borderColor ?? t.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 18,
                    endIndent: 18,
                    color: t.line,
                  ),
                children[i],
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// A row inside a [SettingsGroup]: title and subtitle on the left, the value
/// on the right edge before the chevron.
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

  /// Share of the row a value may take before it moves under the title.
  static const double _valueShare = 0.45;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final valueStyle =
        AppType.ui(14, weight: FontWeight.w600, color: t.inkMuted);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: dense ? 52 : 56),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: dense ? 11 : 14,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // A long value ("Moderately active · ×1.6") would squeeze title
              // and subtitle into a narrow column, so it takes its own line
              // under them. Short values stay on the right edge.
              final stackValue =
                  value != null &&
                  _textWidth(context, value!, valueStyle) >
                      constraints.maxWidth * _valueShare;
              return Row(
                children: <Widget>[
                  if (leading != null) ...<Widget>[
                    leading!,
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: AppType.ui(
                            15,
                            weight: titleColor == null
                                ? FontWeight.w600
                                : FontWeight.w700,
                            color: titleColor ?? t.ink,
                          ),
                        ),
                        if (subtitle != null) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(
                            subtitle!,
                            style: AppType.ui(13, color: t.ink2, height: 1.35),
                          ),
                        ],
                        if (stackValue) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(value!, style: valueStyle),
                        ],
                      ],
                    ),
                  ),
                  if (value != null && !stackValue)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * _valueShare,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          value!,
                          textAlign: TextAlign.right,
                          style: valueStyle,
                        ),
                      ),
                    ),
                  if (trailing != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: trailing!,
                    ),
                  if (chevron)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: t.ink3,
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
