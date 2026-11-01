import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import 'lists.dart';
import 'soft_actions.dart';
import 'surfaces.dart';

/// A quiet section marker for long creation forms, without nested cards:
/// the form's sections are a sequence, so they lead with a [StepNumber]
/// (32), the app's one number style (UI polish 2026-11-01).
class CreationSectionHeading extends StatelessWidget {
  const CreationSectionHeading({
    super.key,
    required this.number,
    required this.title,
    this.note,
  });

  final int number;
  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StepNumber(number, size: 32),
          const SizedBox(width: kSpace12),
          Expanded(
            child: Padding(
              // The title's first line centres on the number.
              padding: EdgeInsets.only(
                top: _titleTop(MediaQuery.textScalerOf(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HeadingSemantics(
                    level: 2,
                    child: Text(title, style: AppType.title2(t.ink)),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: kSpace4),
                    Text(note!, style: AppType.subhead(t.ink2)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static double _titleTop(TextScaler scaler) {
    final line = scaler.scale(19) * 1.2;
    return line < 32 ? (32 - line) / 2 : 0;
  }
}
/// Related values share a row only while each field remains comfortably wide.
class CreationFieldGrid extends StatelessWidget {
  const CreationFieldGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 300 * scale ? 2 : 1;
        final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

/// A full-width insertion point, secondary to the sheet's Save action: the
/// accent [SoftPillButton] with the add glyph, flush in its ground.
class CreationAddButton extends StatelessWidget {
  const CreationAddButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SoftPillButton(
    label: label,
    icon: AppIcons.add,
    onTap: onPressed,
    expand: true,
  );
}
