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

  /// Quiet field fill with muted ink: an alternative path (change text).
  neutral,

  /// Danger tint with danger text: delete. Never filled, so it cannot be
  /// mistaken for the sheet's primary action.
  danger,
}

/// A secondary action: a soft tinted capsule with an optional leading icon,
/// 48 px tall, with the press dip. [expand] stretches it to the full width
/// (a sheet's second action under its primary one). Null [onTap] renders the
/// disabled state.
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
      SoftPillTone.accent => (t.accentTint, t.accentText),
      SoftPillTone.neutral => (t.surf2, t.inkMuted),
      SoftPillTone.danger => (t.danger.withValues(alpha: 0.12), t.danger),
    };
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
        child: Material(
          color: enabled ? fill : fill.withValues(alpha: fill.a * 0.6),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
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
                          14,
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

/// Where something came from ("tiktok.com"): a quiet capsule with a glyph.
/// With [onTap] it is a 44 px button (e.g. to show the full source text).
class SourcePill extends StatelessWidget {
  const SourcePill({
    super.key,
    required this.label,
    this.icon = Icons.link_rounded,
    this.onTap,
    this.semanticLabel,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final String? semanticLabel;

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
      label: semanticLabel ?? label,
      onTap: onTap,
      excludeSemantics: true,
      child: pill,
    );
  }
}
