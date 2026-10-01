import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import '../design/slot_icon_tile.dart';

/// The meal a new entry lands in: all four slots side by side, the chosen one
/// on a tinted pill in its slot colour.
///
/// Used by the add-meal, barcode, camera and manual sheets. Picking the
/// selected slot again does not call [onSelected].
class MealSlotPicker extends StatelessWidget {
  const MealSlotPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.keyPrefix = 'slot-select-',
  });

  final MealSlot selected;
  final ValueChanged<MealSlot> onSelected;

  /// Segment keys are `<keyPrefix><slot.name>`, the track `<keyPrefix>group`.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => MealSlotSegments(
    selected: selected,
    keyPrefix: keyPrefix,
    onSelected: (slot) {
      if (slot != selected) onSelected(slot);
    },
  );
}

/// Segmented slot control shared by [MealSlotPicker] and the edit sheet's
/// `SlotSelector`.
///
/// The first layout whose labels fit wins: four segments with the glyph
/// beside the name (wide screens), four with the glyph over a short name
/// (phones), a 2x2 grid with glyph and name, a 2x2 grid of names alone (large
/// text), and only as a last resort one slot per row. A single pill slides to
/// the selected segment and takes on its slot tint; under reduced motion it
/// jumps.
class MealSlotSegments extends StatelessWidget {
  const MealSlotSegments({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.keyPrefix,
  });

  final MealSlot selected;

  /// Called for every tap, also on the selected segment.
  final ValueChanged<MealSlot> onSelected;
  final String keyPrefix;

  static const double _pad = 4;
  static const double _gap = 4;
  static const double _tile = 28;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    const slots = MealSlot.values;

    TextPainter layout(String text, TextStyle style) => TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();

    double widest(_SegmentShape shape) {
      var max = 0.0;
      for (final slot in slots) {
        final painter = layout(shape.text(slot, l10n), shape.style(t, true));
        max = math.max(max, painter.width);
        painter.dispose();
      }
      return max;
    }

    double lineHeight(_SegmentShape shape) {
      final painter = layout('Ag', shape.style(t, true));
      final height = painter.height;
      painter.dispose();
      return height;
    }

    // The slot tile grows a little with the text, so it never looks like a
    // speck beside an enlarged name.
    final rowTile = scaler.scale(_tile).clamp(_tile, 36.0);
    double need(_SegmentShape shape) => switch (shape) {
      // Glyph over the short name, 8 px a side.
      _SegmentShape.stacked => math.max(_tile, widest(shape)) + 16,
      // Glyph beside the name, 12 px insets.
      _SegmentShape.row => rowTile + 10 + widest(shape) + 24,
      _SegmentShape.label => widest(shape) + 16,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final inner = constraints.maxWidth - 2 * _pad;
        bool fits((int, _SegmentShape) option) =>
            option.$1 * need(option.$2) + (option.$1 - 1) * _gap <= inner;
        final (columns, shape) = const <(int, _SegmentShape)>[
          (4, _SegmentShape.row),
          (4, _SegmentShape.stacked),
          (2, _SegmentShape.row),
          (2, _SegmentShape.label),
        ].firstWhere(fits, orElse: () => (1, _SegmentShape.row));
        final tile = shape == _SegmentShape.stacked ? _tile : rowTile;
        final cellWidth = (inner - (columns - 1) * _gap) / columns;
        final cellHeight = switch (shape) {
          _SegmentShape.stacked => math.max(
            56.0,
            6 + tile + 3 + lineHeight(shape) + 6,
          ),
          _SegmentShape.row => math.max(
            48.0,
            math.max(tile, lineHeight(shape)) + 16,
          ),
          _SegmentShape.label => math.max(48.0, lineHeight(shape) + 16),
        };
        final rows = (slots.length / columns).ceil();
        Offset origin(int i) => Offset(
          (i % columns) * (cellWidth + _gap),
          (i ~/ columns) * (cellHeight + _gap),
        );
        final motion = motionDuration(context, kMotionEnter * 1.3);
        final at = origin(slots.indexOf(selected));
        // Capsules for one-line segments, a softer corner for the taller
        // stacked ones (a full pill would pinch glyph and name); the track
        // stays concentric.
        final radius = shape == _SegmentShape.stacked
            ? rTile
            : math.min(cellHeight / 2, rCard);

        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: l10n.mealSlotPickerTitle,
          child: Container(
            key: ValueKey('${keyPrefix}group'),
            padding: const EdgeInsets.all(_pad),
            decoration: BoxDecoration(
              color: t.surf,
              borderRadius: BorderRadius.circular(radius + _pad),
            ),
            child: SizedBox(
              height: rows * cellHeight + (rows - 1) * _gap,
              child: Stack(
                children: [
                  AnimatedPositioned(
                    key: ValueKey('${keyPrefix}indicator'),
                    duration: motion,
                    curve: kMotionCurve,
                    left: at.dx,
                    top: at.dy,
                    width: cellWidth,
                    height: cellHeight,
                    child: AnimatedContainer(
                      duration: motion,
                      curve: kMotionCurve,
                      decoration: BoxDecoration(
                        color: selected.tileTint(t),
                        borderRadius: BorderRadius.circular(radius),
                        // 80 % of the slot ink: >= 3:1 against both the
                        // tint and the track in either palette.
                        border: Border.all(
                          color: selected.tileInk(t).withValues(alpha: 0.8),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < slots.length; i++)
                    Positioned(
                      left: origin(i).dx,
                      top: origin(i).dy,
                      width: cellWidth,
                      height: cellHeight,
                      child: _Segment(
                        actionKey: ValueKey('$keyPrefix${slots[i].name}'),
                        slot: slots[i],
                        selected: slots[i] == selected,
                        shape: shape,
                        tile: tile,
                        radius: radius,
                        onTap: () => onSelected(slots[i]),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// How one segment arranges its glyph and name.
enum _SegmentShape {
  /// Glyph over the short name.
  stacked,

  /// Glyph beside the full name.
  row,

  /// The short name alone: large text in a 2x2 grid.
  label;

  String text(MealSlot slot, AppLocalizations l10n) =>
      this == row ? slot.label(l10n) : slot.shortLabel(l10n);

  TextStyle style(AppTokens t, bool selected) => AppType.ui(
    this == row ? 13 : 12,
    weight: FontWeight.w700,
    color: selected ? t.ink : t.ink2,
  );
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.actionKey,
    required this.slot,
    required this.selected,
    required this.shape,
    required this.tile,
    required this.radius,
    required this.onTap,
  });

  final Key actionKey;
  final MealSlot slot;
  final bool selected;
  final _SegmentShape shape;
  final double tile;
  final double radius;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final motion = motionDuration(context, kMotionEnter);
    final corners = BorderRadius.circular(radius);
    // Unselected slots stay recognisable by their tile but step back.
    final mark = AnimatedOpacity(
      opacity: selected ? 1 : 0.72,
      duration: motion,
      curve: kMotionCurve,
      child: SlotIconTile(slot: slot, size: tile),
    );
    final label = AnimatedDefaultTextStyle(
      duration: motion,
      curve: kMotionCurve,
      style: shape.style(t, selected),
      child: Text(
        shape.text(slot, l10n),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        textAlign: shape == _SegmentShape.row
            ? TextAlign.start
            : TextAlign.center,
      ),
    );
    // The full slot name is spoken; the short visible label would be a
    // truncated word ("Mittag").
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: slot.label(l10n),
      excludeSemantics: true,
      onTap: onTap,
      child: PressScale(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: actionKey,
            onTap: onTap,
            borderRadius: corners,
            customBorder: RoundedRectangleBorder(borderRadius: corners),
            child: switch (shape) {
              _SegmentShape.stacked => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [mark, const SizedBox(height: 3), label],
              ),
              _SegmentShape.row => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    mark,
                    const SizedBox(width: 10),
                    Expanded(child: label),
                  ],
                ),
              ),
              _SegmentShape.label => Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: label,
                ),
              ),
            },
          ),
        ),
      ),
    );
  }
}
