import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'surfaces.dart';

/// A quiet section marker for long creation forms, without nested cards.
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
          ExcludeSemantics(
            child: Container(
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: t.surf2,
                borderRadius: BorderRadius.circular(rChip),
              ),
              child: Text(
                number.toString().padLeft(2, '0'),
                textAlign: TextAlign.center,
                style: AppType.display(14, color: t.accent),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HeadingSemantics(
                  level: 2,
                  child: Text(title, style: AppType.display(19, color: t.ink)),
                ),
                if (note != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    note!,
                    style: AppType.ui(13, color: t.ink2, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
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

/// A full-width insertion point, secondary to the sheet's Save action.
class CreationAddButton extends StatelessWidget {
  const CreationAddButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: context.t.accent,
        backgroundColor: context.t.tile,
        minimumSize: const Size(0, kButtonMinHeight),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rControl),
        ),
      ),
      icon: const Icon(Icons.add_rounded, size: 20),
      label: Text(label, style: AppType.ui(14, weight: FontWeight.w600)),
    ),
  );
}
