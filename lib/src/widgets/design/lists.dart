import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// ENUMERATIONS (UI polish 2026-11-01) — bullet lists, numbered steps and the
// one step number, lifted out of the recipe sections.
//
// Lists are data, not punctuation: no string carries a "•". Numbers only
// mark real sequences (preparation steps, exercise order, import
// candidates, the sections of a creation form). Markers and numbers are
// decorative to screen readers; a step reads "Step 2 of 5. <text>".
// ---------------------------------------------------------------------------

/// Marker of a [BulletList] item.
enum BulletMarker {
  /// A 6 px dot in the accent, centred on the item's first line.
  dot,
}

/// One entry of [BulletList.icons]: a glyph in a meaning colour beside its
/// text (`success` kept, `accentText` waiting, `danger` lost, `ink2`
/// unknown).
typedef IconBullet = ({IconData icon, Color color, String text});

/// The vertical offset that centres a [marker]-tall mark on the first line
/// of [style] at the current text scale.
double _firstLineTop(BuildContext context, TextStyle style, double marker) {
  final size = style.fontSize ?? 15;
  final line = MediaQuery.textScalerOf(context).scale(size) *
      (style.height ?? AppType.normalHeight);
  return math.max(0, (line - marker) / 2);
}

/// A bullet list: one row per item, the marker centred on the item's first
/// line at any text scale, 12 px to the text ([AppType.body] by default).
///
/// [gap] is the room between items: 6 for short lines (ingredients), 12 for
/// sentences ([BulletList.icons] defaults to 12). Markers the data already
/// carries ("- ", "•", "*", "·", "–") give way to the drawn one
/// ([stripMarker]). On the brand surface pass `onBrandSurface` as
/// [markerColor].
class BulletList extends StatelessWidget {
  const BulletList({
    super.key,
    required List<String> this.items,
    this.marker = BulletMarker.dot,
    this.style,
    this.gap = 6,
    this.markerColor,
  }) : entries = null;

  /// Items with their own glyph and colour (the consequences of a decision):
  /// an 18 px glyph instead of the dot.
  const BulletList.icons({
    super.key,
    required List<IconBullet> this.entries,
    this.style,
    this.gap = 12,
  }) : items = null,
       marker = BulletMarker.dot,
       markerColor = null;

  final List<String>? items;
  final List<IconBullet>? entries;
  final BulletMarker marker;

  /// The item text; [AppType.body] in `ink` (dots) or `ink2` (icons).
  final TextStyle? style;

  final double gap;

  /// The dot's colour; [AppTokens.accent] by default.
  final Color? markerColor;

  static const double _dot = 6;
  static const double _glyph = AppIconSize.button;

  // A leading list marker the data already carries; not the "-" of "-5 kg".
  static final RegExp _marker = RegExp(r'^(?:[•*·–]\s*|-\s+)');

  /// [line] without a leading list marker.
  static String stripMarker(String line) => line.replaceFirst(_marker, '');

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final rows = <Widget>[];
    if (entries case final entries?) {
      final text = style ?? AppType.body(t.ink2);
      final top = _firstLineTop(context, text, _glyph);
      for (final entry in entries) {
        rows.add(
          _BulletRow(
            mark: ExcludeSemantics(
              child: Icon(entry.icon, size: _glyph, color: entry.color),
            ),
            markTop: top,
            child: Text(entry.text, style: text),
          ),
        );
      }
    } else {
      final text = style ?? AppType.body(t.ink);
      final top = _firstLineTop(context, text, _dot);
      for (final item in items!) {
        final line = stripMarker(item.trim());
        if (line.isEmpty) continue;
        rows.add(
          _BulletRow(
            mark: Container(
              width: _dot,
              height: _dot,
              decoration: BoxDecoration(
                color: markerColor ?? t.accent,
                shape: BoxShape.circle,
              ),
            ),
            markTop: top,
            child: Text(line, style: text),
          ),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          rows[i],
        ],
      ],
    );
  }
}

class _BulletRow extends StatelessWidget {
  const _BulletRow({
    required this.mark,
    required this.markTop,
    required this.child,
  });

  final Widget mark;
  final double markTop;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Padding(padding: EdgeInsets.only(top: markTop), child: mark),
      const SizedBox(width: kSpace12),
      Expanded(child: child),
    ],
  );
}

/// The app's one number style for real sequences: an accent-tinted circle
/// with the digit in the display face. [size] 26 inline (steps), 32 as the
/// leading element of a row or form section. The digit follows the text
/// scale only up to 1.3x, so it never bursts the circle. Decorative to
/// screen readers: the row it leads says "Step n of m".
class StepNumber extends StatelessWidget {
  const StepNumber(this.number, {super.key, this.size = 26});

  final int number;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: t.accentTint, shape: BoxShape.circle),
        child: Text(
          '$number',
          textScaler: MediaQuery.textScalerOf(
            context,
          ).clamp(maxScaleFactor: 1.3),
          style: AppType.display(size * 0.46, color: t.accentText),
        ),
      ),
    );
  }
}

/// Numbered steps: a [StepNumber] (26) beside each step, 12 px to the text
/// ([AppType.body]) and between the steps; number and first line share one
/// centre at any text scale. Fewer than two steps are no sequence: a single
/// step stays a plain paragraph. Numbers the text already carries ("1.",
/// "2)") give way to the badge ([stripMarker]).
///
/// Each step is one node read `Step 2 of 5. <text>` (`commonStepOf`).
class NumberedSteps extends StatelessWidget {
  const NumberedSteps({
    super.key,
    required this.steps,
    this.hint,
    this.style,
    this.numberSize = 26,
  });

  final List<String> steps;

  /// A muted line above the steps ([AppType.subhead]).
  final String? hint;

  final TextStyle? style;

  /// 26 inline, 32 for a larger reading size (cooking mode).
  final double numberSize;

  // "1." / "2)" or a list marker; not the "1" of "1.5 l".
  static final RegExp _marker = RegExp(r'^(?:\d+[.)](?!\d)|[•*·–]|-(?=\s))\s*');

  /// [step] without the number or list marker it already carries.
  static String stripMarker(String step) => step.replaceFirst(_marker, '');

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final text = style ?? AppType.body(t.ink);
    final clean = <String>[
      for (final step in steps)
        if (stripMarker(step.trim()) case final s when s.isNotEmpty) s,
    ];
    final Widget body;
    if (clean.length < 2) {
      body = Text(clean.isEmpty ? '' : clean.single, style: text);
    } else {
      final line =
          MediaQuery.textScalerOf(context).scale(text.fontSize ?? 15) *
          (text.height ?? AppType.normalHeight);
      final numberTop = line > numberSize ? (line - numberSize) / 2 : 0.0;
      final textTop = line < numberSize ? (numberSize - line) / 2 : 0.0;
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (i, step) in clean.indexed) ...<Widget>[
            if (i > 0) const SizedBox(height: kSpace12),
            Semantics(
              container: true,
              label: '${l10n.commonStepOf(i + 1, clean.length)}. $step',
              excludeSemantics: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.only(top: numberTop),
                    child: StepNumber(i + 1, size: numberSize),
                  ),
                  const SizedBox(width: kSpace12),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: textTop),
                      child: Text(step, style: text),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    }
    if (hint == null || hint!.isEmpty) return body;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: kSpace12),
          child: Text(hint!, style: AppType.subhead(t.ink2)),
        ),
        body,
      ],
    );
  }
}
