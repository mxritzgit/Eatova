import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

/// Open sections keep settings readable without a card around every group.
class SettingsStudioGroup extends StatelessWidget {
  const SettingsStudioGroup({
    super.key,
    required this.label,
    required this.children,
    this.labelColor,
  });

  final String label;
  final List<Widget> children;
  final Color? labelColor;

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
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                label,
                style: AppType.display(19, color: labelColor ?? t.ink),
              ),
            ),
          ),
          for (final child in children) ...[
            child,
            Divider(height: 1, color: t.line),
          ],
        ],
      ),
    );
  }
}

/// Values and multi-choice controls take their own line at larger text sizes.
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
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool chevron;
  final IconData? endIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(rControl),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (leading != null) ...[
                    ExcludeSemantics(child: leading!),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppType.ui(
                            15,
                            weight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 5),
                          Text(
                            subtitle!,
                            style: AppType.ui(13, color: t.ink2, height: 1.45),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if ((chevron || endIcon != null) && onTap != null) ...[
                    const SizedBox(width: 12),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        endIcon ?? Icons.arrow_forward_rounded,
                        size: 19,
                        color: t.ink2,
                      ),
                    ),
                  ],
                ],
              ),
              if (trailing != null) ...[const SizedBox(height: 12), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}
