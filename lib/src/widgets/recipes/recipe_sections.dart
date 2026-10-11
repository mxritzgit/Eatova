import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';

// ---------------------------------------------------------------------------
// A recipe's text sections — portion, ingredients, preparation — as the
// import preview designed them: a calm card with an icon-tile heading, accent
// bullet dots and round numbered steps. Shared by the import preview, the
// recipe detail and the coach's "Add recipe" sheet, so one recipe reads the
// same wherever it is shown.
// ---------------------------------------------------------------------------

const double _bodySize = 15;
const double _bodyHeight = 1.5;

TextStyle _bodyStyle(AppTokens t, {bool muted = false}) =>
    AppType.ui(_bodySize, color: muted ? t.ink2 : t.ink, height: _bodyHeight);

/// Non-empty, trimmed lines of a free text.
List<String> _lines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

/// A recipe section: small icon tile, a level-2 title, the content below on a
/// calm card. [highlight] puts it on the brand surface (the pro tip).
class RecipeSectionCard extends StatelessWidget {
  const RecipeSectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.highlight = false,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      radius: rTile,
      color: highlight ? t.brandSurface : null,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: IconTile(icon: icon, color: t.accent, size: 30),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: HeadingSemantics(
                  level: 2,
                  child: Text(
                    title,
                    style: AppType.display(
                      16,
                      weight: FontWeight.w700,
                      color: highlight ? t.onBrandSurface : t.ink,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// A short muted line under a section title ("Everything you need …").
class _SectionHint extends StatelessWidget {
  const _SectionHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: AppType.ui(13, color: context.t.ink2, height: 1.45),
    ),
  );
}

/// Body text of a section; [empty] shows muted when [text] is empty.
class RecipeParagraph extends StatelessWidget {
  const RecipeParagraph({super.key, required this.text, required this.empty});

  final String text;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final value = text.trim();
    return Text(
      value.isEmpty ? empty : value,
      style: _bodyStyle(context.t, muted: value.isEmpty),
    );
  }
}

/// Ingredients as bullet lines (accent dot + text) under an optional
/// quantity [hint]. A list marker the text already carries ("- ", "•", "*")
/// gives way to the dot.
class RecipeIngredientLines extends StatelessWidget {
  const RecipeIngredientLines({super.key, required this.text, this.hint = ''});

  final String text;
  final String hint;

  // A leading list marker from the caption; the dot replaces it.
  static final RegExp _marker = RegExp(r'^(?:[•*·–]\s*|-\s+)');

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final lines = [
      for (final line in _lines(text))
        if (line.replaceFirst(_marker, '').isNotEmpty)
          line.replaceFirst(_marker, ''),
    ];
    // Centre the dot on the first line at any text scale.
    final dotTop =
        (MediaQuery.textScalerOf(context).scale(_bodySize) * _bodyHeight - 6) /
        2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hint.isNotEmpty) _SectionHint(hint),
        if (lines.isEmpty)
          Text(
            context.l10n.recipesNoDataProvided,
            style: _bodyStyle(t, muted: true),
          ),
        for (final (i, line) in lines.indexed) ...[
          if (i > 0) const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: dotTop),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: t.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(line, style: _bodyStyle(t))),
            ],
          ),
        ],
      ],
    );
  }
}

/// Preparation as numbered steps when the text has several lines; a single
/// paragraph stays a paragraph, an empty one shows [empty]. Numbers the
/// steps already carry ("1.", "2)") give way to the badge.
class RecipePreparationSteps extends StatelessWidget {
  const RecipePreparationSteps({
    super.key,
    required this.text,
    required this.empty,
    this.hint = '',
  });

  final String text;
  final String empty;

  /// Muted line above the steps.
  final String hint;

  // "1." / "2)" or a list marker the caption already numbered with; not the
  // "1" of "1.5 l".
  static final RegExp _marker = RegExp(r'^(?:\d+[.)](?!\d)|[•*·–]|-(?=\s))\s*');

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final steps = _lines(text);
    final Widget body;
    if (steps.length < 2) {
      body = RecipeParagraph(text: text, empty: empty);
    } else {
      const badge = 26.0;
      // Badge and first text line share one centre at any text scale.
      final line =
          MediaQuery.textScalerOf(context).scale(_bodySize) * _bodyHeight;
      final badgeTop = line > badge ? (line - badge) / 2 : 0.0;
      final textTop = line < badge ? (badge - line) / 2 : 0.0;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, step) in steps.indexed) ...[
            if (i > 0) const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: badgeTop),
                  child: RecipeStepBadge(number: i + 1, size: badge),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: textTop),
                    child: Text(
                      step.replaceFirst(_marker, ''),
                      style: _bodyStyle(t),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }
    if (hint.isEmpty) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_SectionHint(hint), body],
    );
  }
}

/// Accent-tinted round number (a candidate's position, a preparation step).
/// The digit follows text scale only up to 1.3x, so it never bursts the
/// circle.
class RecipeStepBadge extends StatelessWidget {
  const RecipeStepBadge({super.key, required this.number, required this.size});

  final int number;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
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
    );
  }
}
