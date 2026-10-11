import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// MENUS — the one row language of every overflow menu (meal plan, training
// plan, player header, exercise card, workout chooser). The menu surface,
// edge, label type and "opens under its anchor" come from the theme's
// `popupMenuTheme`.
// ---------------------------------------------------------------------------

/// One overflow menu entry: a 20 px glyph, a 12 px gap and an `ink` 15/600
/// label.
///
/// [destructive] tints only the glyph `danger`. The label never turns red:
/// the red belongs to the confirming action of the decision card that
/// follows, not to a line of text in a menu.
///
/// Without an [icon] the glyph slot stays empty, so rows with and without a
/// mark (the workout chooser's check) keep one label column.
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.label,
    this.icon,
    this.destructive = false,
    this.iconColor,
  });

  final String label;
  final IconData? icon;
  final bool destructive;

  /// Overrides the glyph colour, e.g. the accent check of a chosen entry.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        SizedBox.square(
          dimension: 20,
          child: icon == null
              ? null
              : Icon(
                  icon,
                  size: 20,
                  color: iconColor ?? (destructive ? t.danger : t.ink2),
                ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
          ),
        ),
      ],
    );
  }
}

/// A [PopupMenuItem] carrying a [MenuRow].
PopupMenuItem<T> eatovaMenuItem<T>({
  Key? key,
  required T value,
  required String label,
  IconData? icon,
  bool destructive = false,
  bool enabled = true,
}) => PopupMenuItem<T>(
  key: key,
  value: value,
  enabled: enabled,
  // MenuRow paints its own colours, so a locked row dims as a whole.
  child: enabled
      ? MenuRow(icon: icon, label: label, destructive: destructive)
      : Opacity(
          opacity: 0.4,
          child: MenuRow(icon: icon, label: label, destructive: destructive),
        ),
);
