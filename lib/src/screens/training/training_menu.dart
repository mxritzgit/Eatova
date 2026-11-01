import 'package:flutter/material.dart';

import '../../widgets/design/design.dart';

/// Opens an overflow menu under [anchor] (the tapped control), like every
/// [PopupMenuButton] (`PopupMenuPosition.under`); Material shifts it up to
/// stay on screen when the space below is too short.
Future<T?> showTrainingMenu<T>(
  BuildContext anchor,
  List<PopupMenuEntry<T>> items,
) {
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final bottomLeft = box.localToGlobal(
    box.size.bottomLeft(Offset.zero),
    ancestor: overlay,
  );
  return showMenu<T>(
    context: anchor,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(bottomLeft.dx, bottomLeft.dy, box.size.width, 0),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

/// The ⋯ of a header, card or row: the app's [AppIconButton] that opens
/// [itemBuilder]'s [MenuRow] entries under itself and hands the chosen value
/// to [onSelected]. [enabled] false dims it and reports it disabled.
class TrainingMenuButton<T> extends StatelessWidget {
  const TrainingMenuButton({
    super.key,
    required this.semanticLabel,
    required this.itemBuilder,
    required this.onSelected,
    this.enabled = true,
    this.tone = IconButtonTone.plain,
    this.target,
  });

  /// Spoken name and long-press tooltip.
  final String semanticLabel;
  final List<PopupMenuEntry<T>> Function(BuildContext context) itemBuilder;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final IconButtonTone tone;

  /// A tap target larger than the 44 px disc (48 beside a dense row).
  final double? target;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => AppIconButton(
      icon: AppIcons.moreHoriz,
      semanticLabel: semanticLabel,
      tone: tone,
      target: target,
      onTap: enabled
          ? () async {
              final value = await showTrainingMenu<T>(
                anchor,
                itemBuilder(anchor),
              );
              if (value != null && anchor.mounted) onSelected(value);
            }
          : null,
    ),
  );
}
