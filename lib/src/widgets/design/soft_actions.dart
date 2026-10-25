import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/lively.dart';

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

/// A secondary action: a soft tinted capsule with an optional leading icon,
/// 48 px tall, with the press dip. [expand] stretches it to the full width
/// (a sheet's second action under its primary one). Null [onTap] renders the
/// disabled state.
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
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final SoftPillTone tone;
  final bool expand;

  /// Spoken instead of [label] when the visible text needs context.
  final String? semanticLabel;

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
    final enabled = onTap != null;
    final fg = enabled ? ink : ink.withValues(alpha: 0.45);
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: semanticLabel ?? label,
      onTap: onTap,
      excludeSemantics: true,
      child: PressScale(
        enabled: enabled,
        rebound: true,
        child: Material(
          color: enabled ? fill : fill.withValues(alpha: fill.a * 0.6),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            splashFactory: NoSplash.splashFactory,
            // The quiet pill shows its capsule only while touched.
            highlightColor: quiet ? t.softFill : fg.withValues(alpha: 0.10),
            focusColor: quiet ? t.softFill : fg.withValues(alpha: 0.14),
            hoverColor: quiet
                ? t.softFill.withValues(alpha: 0.6)
                : fg.withValues(alpha: 0.05),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: fg),
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

/// Where something came from ("tiktok.com"): a quiet capsule with a glyph.
/// With [onTap] it is a 44 px button (e.g. to show the full source text).
class SourcePill extends StatelessWidget {
  const SourcePill({
    super.key,
    required this.label,
    this.icon = Icons.link_rounded,
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
                Icon(icon, size: 15, color: t.ink2),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: t.ink2,
                    ),
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
