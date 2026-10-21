import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme/app_tokens.dart';
import 'controls.dart' show IconTile;
import 'surfaces.dart' show AppCard, HeadingSemantics;

// ---------------------------------------------------------------------------
// FEEDBACK STATES — one language for "something went wrong", "nothing here
// yet" and "still loading" (design pass 2026-10-11).
//
//   SignalNote   an inline status line: glyph in the tone, text in ink, an
//                optional tinted box and one way forward.
//   CalmState    empty / error state: glyph tile, title, guidance, soft pill
//                actions. Inline in a sheet, or as a card on a page.
//   AppSpinner   the app's spinner: 22 px, round caps, accent (spinner.dart).
//   Skeleton*    static placeholders in the geometry of the rows they stand
//                in for. No shimmer, so reduced motion has nothing to stop.
//
// Colors only from [AppTokens], type only from [AppType].
// ---------------------------------------------------------------------------

/// Explanatory or error line with a glyph.
///
/// Without [boxed] it is a plain row (a settings group child); with [boxed]
/// it carries its own tinted surface — the app's error/warning banner. Errors
/// pass `tone: t.danger` and [Icons.error_outline_rounded], warnings
/// `t.warning`.
class SignalNote extends StatelessWidget {
  const SignalNote(
    this.text, {
    super.key,
    this.tone,
    this.icon = Icons.info_outline_rounded,
    this.boxed = false,
    this.action,
    this.liveRegion = false,
  });

  final String text;

  /// Glyph color — and, on an UNBOXED note, the text color too; defaults to
  /// the quiet [AppTokens.ink2]. [AppTokens.warning] and [AppTokens.danger]
  /// mark notes that need action. A [boxed] note always writes in `ink`.
  final Color? tone;

  final IconData icon;
  final bool boxed;

  /// One way forward under the text (a soft pill such as "Retry"), aligned
  /// with the text rather than the glyph.
  final Widget? action;

  /// Announces the text when it appears (an error after a failed save). Only
  /// the text: an [action] keeps its own button node.
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ton = tone ?? t.ink2;
    // Signal-banner contract (hell_modus_audit_test): fill = tone at 10 %,
    // GLYPH in the full tone, TEXT in `ink`. The tinted fill eats the
    // headroom the tone still had on the bare ground — over `bg` (where these
    // boxes actually sit) 13 px text measures warning 4.20:1, danger 4.48:1
    // and even the quiet ink2 4.48:1, all below AA. `ink` gives 12.9-14.7:1.
    // Unboxed notes keep the tone as text color: without a fill it carries
    // (warning 4.76:1 on bg, 5.38:1 on surf), and the tone IS the signal
    // there.
    final textFarbe = boxed ? t.ink : ton;

    Widget zeile = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 17, color: ton),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            liveRegion: liveRegion,
            child: Text(
              text,
              style: AppType.ui(
                13,
                weight: FontWeight.w500,
                color: textFarbe,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
    if (action case final action?) {
      zeile = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          zeile,
          const SizedBox(height: 10),
          // Glyph (17) plus gap (10): the pill starts under the text.
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 27),
            child: action,
          ),
        ],
      );
    }

    if (!boxed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: zeile,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: ton.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(rTile),
        border: Border.all(color: ton.withValues(alpha: 0.24)),
      ),
      child: zeile,
    );
  }
}

/// The one shape for "nothing to show here" and "this did not load": a glyph
/// in a tile, an optional title, one line of guidance and at most two ways
/// forward ([actions], soft pills such as [SoftPillButton]). Several actions
/// sit side by side while they fit and stack at one shared width once they
/// do not (large text, narrow phones); they must report intrinsic widths,
/// which pills do. A single action is placed as is and may size itself.
///
/// Inline (default) it sits centred in a sheet's flow, as in the add-meal
/// search. With [card] it is its own card on a page — left-aligned, a 44 px
/// accent tile and a display title that screen readers can jump to (the
/// shopping list's empty state).
///
/// Never red: an error says what happened and offers the retry; the tone of
/// the page stays calm.
class CalmState extends StatelessWidget {
  const CalmState({
    super.key,
    this.icon,
    this.glyph,
    required this.text,
    this.title,
    this.actions = const <Widget>[],
    this.card = false,
  }) : assert(
         icon != null || glyph != null,
         'A calm state needs an icon or a glyph',
       );

  final IconData? icon;

  /// Drawn instead of [icon] (an [AppIcon], say); it takes the tile's ink
  /// and size from the surrounding [IconTheme].
  final Widget? glyph;

  final String text;
  final String? title;
  final List<Widget> actions;
  final bool card;

  @override
  Widget build(BuildContext context) =>
      card ? _buildCard(context) : _buildInline(context);

  Widget _glyph(Color ink) => IconTheme(
    data: IconThemeData(color: ink, size: 22),
    child: glyph ?? Icon(icon),
  );

  Widget _actionBar({required bool centered}) => actions.length == 1
      ? actions.single
      : _PillBar(centered: centered, children: actions);

  Widget _buildInline(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        children: [
          IconTile.custom(size: 48, child: _glyph(t.ink2)),
          const SizedBox(height: 14),
          if (title != null) ...[
            Text(
              title!,
              textAlign: TextAlign.center,
              style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            text,
            textAlign: TextAlign.center,
            style: AppType.ui(13.5, color: t.ink2, height: 1.4),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 16),
            _actionBar(centered: true),
          ],
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    final t = context.t;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: t.accentTint,
              borderRadius: BorderRadius.circular(rControl),
            ),
            child: Center(child: _glyph(t.accentText)),
          ),
          const SizedBox(height: 14),
          if (title != null) ...[
            HeadingSemantics(
              level: 2,
              child: Text(
                title!,
                style: AppType.display(
                  19,
                  weight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(text, style: AppType.ui(14, color: t.ink2, height: 1.45)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 16),
            _actionBar(centered: false),
          ],
        ],
      ),
    );
  }
}

/// Pills side by side while their natural widths fit, otherwise stacked at
/// the widest pill's width, so a stacked pair never reads as two unrelated
/// buttons of different sizes.
class _PillBar extends MultiChildRenderObjectWidget {
  const _PillBar({required this.centered, required super.children});

  final bool centered;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPillBar(
    centered: centered,
    textDirection: Directionality.of(context),
  );

  @override
  void updateRenderObject(BuildContext context, _RenderPillBar renderObject) {
    renderObject
      ..centered = centered
      ..textDirection = Directionality.of(context);
  }
}

class _PillBarParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPillBar extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PillBarParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PillBarParentData> {
  _RenderPillBar({required bool centered, required TextDirection textDirection})
    : _centered = centered,
      _textDirection = textDirection;

  static const double _gap = 10;

  bool _centered;
  set centered(bool value) {
    if (value == _centered) return;
    _centered = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PillBarParentData) {
      child.parentData = _PillBarParentData();
    }
  }

  List<RenderBox> get _pills {
    final pills = <RenderBox>[];
    for (var child = firstChild; child != null; child = childAfter(child)) {
      pills.add(child);
    }
    return pills;
  }

  /// Each pill's natural width (capped at [maxWidth]) and whether all of
  /// them fit on one line.
  (List<double>, bool) _plan(double maxWidth) {
    final widths = [
      for (final pill in _pills)
        math.min(pill.getMaxIntrinsicWidth(double.infinity), maxWidth),
    ];
    final row =
        widths.fold(0.0, (sum, w) => sum + w) + _gap * (widths.length - 1);
    return (widths, row <= maxWidth);
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final pills = _pills;
    if (pills.isEmpty) return constraints.smallest;
    final (widths, fits) = _plan(constraints.maxWidth);
    Size place(RenderBox pill, BoxConstraints c) {
      if (dry) return pill.getDryLayout(c);
      pill.layout(c, parentUsesSize: true);
      return pill.size;
    }

    final rtl = _textDirection == TextDirection.rtl;
    if (fits) {
      final sizes = [
        for (var i = 0; i < pills.length; i++)
          place(pills[i], BoxConstraints(maxWidth: widths[i])),
      ];
      final height = sizes.map((s) => s.height).reduce(math.max);
      final row =
          sizes.fold(0.0, (sum, s) => sum + s.width) +
          _gap * (sizes.length - 1);
      final width = constraints.maxWidth.isFinite ? constraints.maxWidth : row;
      if (!dry) {
        var x = _centered ? (width - row) / 2 : 0.0;
        for (var i = 0; i < pills.length; i++) {
          final dx = rtl ? width - x - sizes[i].width : x;
          (pills[i].parentData! as _PillBarParentData).offset = Offset(
            dx,
            (height - sizes[i].height) / 2,
          );
          x += sizes[i].width + _gap;
        }
      }
      return constraints.constrain(Size(width, height));
    }
    // Stacked: one shared width, the widest pill's.
    final shared = widths.reduce(math.max);
    final width = constraints.maxWidth.isFinite ? constraints.maxWidth : shared;
    final dx = _centered ? (width - shared) / 2 : (rtl ? width - shared : 0.0);
    var y = 0.0;
    for (final pill in pills) {
      final size = place(pill, BoxConstraints.tightFor(width: shared));
      if (!dry) {
        (pill.parentData! as _PillBarParentData).offset = Offset(dx, y);
      }
      y += size.height + _gap;
    }
    return constraints.constrain(Size(width, y - _gap));
  }

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  double computeMinIntrinsicWidth(double height) => _pills.fold(
    0.0,
    (widest, pill) => math.max(widest, pill.getMinIntrinsicWidth(height)),
  );

  @override
  double computeMaxIntrinsicWidth(double height) {
    final pills = _pills;
    if (pills.isEmpty) return 0;
    return pills.fold(
          0.0,
          (sum, pill) => sum + pill.getMaxIntrinsicWidth(height),
        ) +
        _gap * (pills.length - 1);
  }

  double _intrinsicHeight(double width) {
    final pills = _pills;
    if (pills.isEmpty) return 0;
    final (widths, fits) = _plan(width);
    if (fits) {
      return [
        for (var i = 0; i < pills.length; i++)
          pills[i].getMaxIntrinsicHeight(widths[i]),
      ].reduce(math.max);
    }
    final shared = widths.reduce(math.max);
    return pills.fold(
          0.0,
          (sum, pill) => sum + pill.getMaxIntrinsicHeight(shared),
        ) +
        _gap * (pills.length - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToHighestActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// One placeholder bar: `tile` fill with pill ends, [widthFactor] of the
/// available width.
class SkeletonBar extends StatelessWidget {
  const SkeletonBar({super.key, this.widthFactor = 1, this.height = 12});

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    alignment: AlignmentDirectional.centerStart,
    widthFactor: widthFactor,
    child: Container(
      height: height,
      decoration: BoxDecoration(
        color: context.t.tile,
        borderRadius: BorderRadius.circular(rPill),
      ),
    ),
  );
}

/// One list row's placeholder: a tile and two bars in the row's geometry.
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({
    super.key,
    this.tileSize = 40,
    this.tileRadius = rChip,
    this.nameWidth = 0.6,
    this.metaWidth = 0.34,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  final double tileSize;
  final double tileRadius;

  /// Width factors of the name and the meta bar.
  final double nameWidth, metaWidth;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Container(
            width: tileSize,
            height: tileSize,
            decoration: BoxDecoration(
              color: context.t.tile,
              borderRadius: BorderRadius.circular(tileRadius),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBar(widthFactor: nameWidth),
                const SizedBox(height: 9),
                SkeletonBar(widthFactor: metaWidth, height: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder rows in a card while the real rows load, so they replace it
/// without a jump.
///
/// Hidden from screen readers; with [semanticLabel] the card is announced as
/// that one label instead ("Loading day…").
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({
    super.key,
    this.rows = 3,
    this.tileSize = 40,
    this.tileRadius = rChip,
    this.semanticLabel,
  }) : assert(rows > 0, 'A skeleton card needs at least one row');

  final int rows;
  final double tileSize;
  final double tileRadius;
  final String? semanticLabel;

  /// Name/meta widths, cycled so the rows do not read as a grid.
  static const List<(double, double)> _widths = <(double, double)>[
    (0.62, 0.34),
    (0.48, 0.3),
    (0.7, 0.38),
    (0.55, 0.28),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 14 + tileSize + 12,
                  endIndent: 14,
                  color: t.line,
                ),
              SkeletonRow(
                tileSize: tileSize,
                tileRadius: tileRadius,
                nameWidth: _widths[i % _widths.length].$1,
                metaWidth: _widths[i % _widths.length].$2,
              ),
            ],
          ],
        ),
      ),
    );
    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: card);
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(child: card),
    );
  }
}
