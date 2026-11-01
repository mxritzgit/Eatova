import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import 'spinner.dart';

// Secondary actions of the dark redesign (2026-10-03): what used to be a
// default TextButton, an outlined button with a hairline or a small red text
// link. One soft capsule language next to the filled PrimaryActionButton.

/// Tone of a [SoftPillButton].
enum SoftPillTone {
  /// Accent tint with accent text: "do something here" (adjust, edit, paste).
  accent,

  /// Quiet [AppTokens.softFill] with muted ink: an alternative path (change
  /// text). That fill holds on the sheet ground too; `surf2` vanished there
  /// in light mode (1.05:1).
  neutral,

  /// Danger tint with danger text: delete. Never filled, so it cannot be
  /// mistaken for the sheet's primary action.
  danger,

  /// No fill at rest, `inkSoft` text: the quiet way out under a lit primary
  /// action ("Käufe wiederherstellen", a cancel). The fill appears only
  /// under a finger or keyboard focus, so the eye lands on the lit action
  /// while the exit keeps its full target.
  quiet,
}

/// Height of a [SoftPillButton].
enum SoftPillSize {
  /// 48 px: the default, a pill on its own or beside others.
  compact,

  /// 54 px, as tall as [PrimaryActionButton]: a secondary action directly
  /// under the primary one (with `expand: true`). Style, not size, carries
  /// the hierarchy.
  regular,
}

/// A secondary action: a soft tinted capsule with an optional leading icon,
/// 48 px tall ([size] `regular`: 54), with the press dip. [expand] stretches
/// it to the full width (a sheet's second action under its primary one).
/// Null [onTap] renders the disabled state; [busy] puts a 16 px spinner in
/// the label tone where the icon sits and ignores taps.
///
/// Depth and light (2026-10-25): secondary actions sit flush in their ground
/// (tone only, no shadow) under the lit primary one. No ripple: a press
/// deepens the fill a step and the pill rebounds; keyboard focus changes the
/// fill, never a ring.
class SoftPillButton extends StatelessWidget {
  const SoftPillButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.tone = SoftPillTone.accent,
    this.expand = false,
    this.semanticLabel,
    this.size = SoftPillSize.compact,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final SoftPillTone tone;
  final bool expand;

  /// Spoken instead of [label] when the visible text needs context.
  final String? semanticLabel;

  final SoftPillSize size;

  /// Work in flight: the fill stays, taps are ignored.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (fill, ink) = switch (tone) {
      // The stronger tint: on the dark ground the 14 % one sat a hair from
      // the neutral fill, only the label told them apart.
      SoftPillTone.accent => (t.accentTintStrong, t.accentText),
      SoftPillTone.neutral => (t.softFill, t.inkMuted),
      SoftPillTone.danger => (t.danger.withValues(alpha: 0.12), t.danger),
      SoftPillTone.quiet => (t.softFill.withValues(alpha: 0), t.inkSoft),
    };
    final quiet = tone == SoftPillTone.quiet;
    final enabled = onTap != null && !busy;
    // Busy keeps the tone: working, not locked.
    final fg = enabled || busy ? ink : ink.withValues(alpha: 0.45);
    final rest = enabled || busy ? fill : fill.withValues(alpha: fill.a * 0.6);
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: semanticLabel ?? label,
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: PressScale(
        enabled: enabled,
        rebound: true,
        child: Material(
          color: rest,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            splashFactory: NoSplash.splashFactory,
            // The quiet pill shows its capsule only while touched.
            highlightColor: quiet ? t.softFill : fg.withValues(alpha: 0.10),
            focusColor: quiet ? t.softFill : fg.withValues(alpha: 0.14),
            hoverColor: quiet
                ? t.softFill.withValues(alpha: 0.6)
                : fg.withValues(alpha: 0.05),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: size == SoftPillSize.regular
                    ? kPrimaryButtonHeight
                    : kButtonMinHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (busy) ...[
                      AppSpinner(
                        size: AppIconSize.small,
                        strokeWidth: 2,
                        color: fg,
                        trackColor: fg.withValues(alpha: 0.2),
                      ),
                      const SizedBox(width: 8),
                    ] else if (icon != null) ...[
                      Icon(icon, size: AppIconSize.button, color: fg),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: AppType.ui(
                          quiet ? 15 : 14,
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
      ),
    );
  }
}

/// Tone of an [EatovaTextAction].
enum EatovaTextTone {
  /// `accentText`: a link that does something here (terms, retry).
  accent,

  /// `ink2`: a quiet alternative path (restore, legal rows).
  neutral,

  /// `danger`: a risky text action.
  danger,
}

/// The shared quiet text action: a link-weight label in its tone on no
/// fill, or on a tonal capsule with [capsule] (`accentTintStrong`, `tile`
/// for neutral). No ripple: a press lays the tone over it at 12 %, keyboard
/// focus at 18 % (focus highlights show in the traditional mode only).
/// 48 px target, the 3 % press dip.
///
/// A [TextButton] underneath, so finders and tests keep reading
/// `widget<TextButton>(byKey)`; [buttonKey] goes on it. [color] and
/// [textStyle] override the tone's label (a link on a coloured card, the
/// small legal rows).
class EatovaTextAction extends StatelessWidget {
  const EatovaTextAction({
    super.key,
    this.buttonKey,
    required this.label,
    required this.onTap,
    this.icon,
    this.trailingIcon,
    this.tone = EatovaTextTone.accent,
    this.capsule = false,
    this.iconSize = 18,
    this.color,
    this.textStyle,
  });

  final Key? buttonKey;
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final IconData? trailingIcon;
  final EatovaTextTone tone;
  final bool capsule;
  final double iconSize;
  final Color? color;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ink =
        color ??
        switch (tone) {
          EatovaTextTone.accent => t.accentText,
          EatovaTextTone.neutral => t.ink2,
          EatovaTextTone.danger => t.danger,
        };
    final rest = !capsule
        ? Colors.transparent
        : switch (tone) {
            EatovaTextTone.accent => t.accentTintStrong,
            EatovaTextTone.neutral => t.tile,
            EatovaTextTone.danger => t.danger.withValues(alpha: 0.12),
          };
    final enabled = onTap != null;
    final fg = enabled ? ink : ink.withValues(alpha: ink.a * 0.45);
    final style = (textStyle ?? AppType.ui(14, weight: FontWeight.w700))
        .copyWith(color: fg);
    return PressScale(
      enabled: enabled,
      scale: kPressScale,
      child: TextButton(
        key: buttonKey,
        onPressed: onTap,
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(fg),
          backgroundColor: WidgetStatePropertyAll(
            enabled ? rest : rest.withValues(alpha: rest.a * 0.6),
          ),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return ink.withValues(alpha: 0.12);
            }
            if (states.contains(WidgetState.focused)) {
              return ink.withValues(alpha: 0.18);
            }
            if (states.contains(WidgetState.hovered)) {
              return ink.withValues(alpha: 0.06);
            }
            return null;
          }),
          textStyle: WidgetStatePropertyAll(style),
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: capsule ? 18 : 12),
          ),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          splashFactory: NoSplash.splashFactory,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: iconSize, color: fg),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(label, textAlign: TextAlign.center, style: style),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 6),
              Icon(trailingIcon, size: iconSize, color: fg),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tone of a [StatusPill].
enum StatusTone {
  /// `tile` fill, no mark colour of its own.
  neutral,

  /// Accent tint with an accent label: "on", "new", the AI estimate.
  accent,

  /// `tile` fill, the mark in [AppTokens.success].
  success,

  /// `tile` fill, the mark in [AppTokens.warning].
  warning,

  /// `tile` fill, the mark in [AppTokens.danger].
  danger,
}

/// A status or meta note that is NOT tappable ("3 Tage", "Neu", "KI
/// geschätzt"). Something to choose is a [FilterChipPill], something to do
/// a [SoftPillButton], so nobody has to guess whether a capsule is a button.
///
/// A capsule at least 28 px tall, padding 10/5, a 14 px [icon] or an 8 px
/// [dot] in the tone colour before a 12/700 label in `inkSoft` (`accentText`
/// for [StatusTone.accent]). Colour never carries the meaning alone: the
/// label says it. Success, warning and danger tint only the mark, on the
/// neutral fill, so the label keeps its contrast. [color] overrides the mark
/// colour (a macro or slot hue).
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.icon,
    this.dot = false,
    this.tone = StatusTone.neutral,
    this.color,
    this.semanticLabel,
  });

  final String label;
  final IconData? icon;

  /// An 8 px dot instead of an [icon].
  final bool dot;

  final StatusTone tone;
  final Color? color;

  /// Spoken instead of [label] when the visible text is an abbreviation.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final accent = tone == StatusTone.accent;
    final fill = accent ? t.accentTint : t.tile;
    final ink = accent ? t.accentText : t.inkSoft;
    final mark =
        color ??
        switch (tone) {
          StatusTone.neutral => t.ink2,
          StatusTone.accent => t.accentText,
          StatusTone.success => t.success,
          StatusTone.warning => t.warning,
          StatusTone.danger => t.danger,
        };
    return Semantics(
      container: true,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: AppIconSize.meta, color: mark),
              const SizedBox(width: 6),
            ] else if (dot) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: mark, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                style: AppType.ui(12, weight: FontWeight.w700, color: ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where something came from ("tiktok.com"): a quiet capsule with a glyph.
/// With [onTap] it is a 44 px button (e.g. to show the full source text).
class SourcePill extends StatelessWidget {
  const SourcePill({
    super.key,
    required this.label,
    this.icon = AppIcons.link,
    this.onTap,
    this.semanticLabel,
    this.expanded,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// Whether the details this pill toggles are open; null when it toggles
  /// nothing.
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final pill = Material(
      color: t.surf2,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: onTap == null ? 32 : 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: AppIconSize.meta, color: t.ink2),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.caption(t.ink2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      button: onTap != null,
      expanded: expanded,
      label: semanticLabel ?? label,
      onTap: onTap,
      excludeSemantics: true,
      child: pill,
    );
  }
}
