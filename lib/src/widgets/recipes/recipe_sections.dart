import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';

// ---------------------------------------------------------------------------
// A recipe's text sections — portion, ingredients, preparation — as the
// import preview designed them: a calm card with an icon-badge heading,
// accent bullet dots and round numbered steps. Shared by the import preview,
// the recipe detail and the coach's "Add recipe" sheet, so one recipe reads
// the same wherever it is shown. The lists themselves are the design
// library's [BulletList] and [NumberedSteps] (UI polish 2026-11-01).
// ---------------------------------------------------------------------------

TextStyle _bodyStyle(AppTokens t, {bool muted = false}) =>
    AppType.body(muted ? t.ink2 : t.ink);

/// Non-empty, trimmed lines of a free text.
List<String> _lines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

/// A recipe section: a small accent [IconBadge], a level-2 title, the content
/// below on a calm card. [highlight] puts it on the brand surface (the pro
/// tip).
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
              IconBadge(
                icon: icon,
                size: IconBadgeSize.sm,
                tone: IconBadgeTone.accent,
              ),
              const SizedBox(width: kSpace12),
              Expanded(
                child: HeadingSemantics(
                  level: 2,
                  child: Text(
                    title,
                    style: AppType.section(
                      highlight ? t.onBrandSurface : t.ink,
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
    padding: const EdgeInsets.only(bottom: kSpace12),
    child: Text(text, style: AppType.subhead(context.t.ink2)),
  );
}

/// Body text of a section; [empty] shows muted when [text] is empty.
///
/// A number keeps its short unit or word ("420 g", "2 EL") on its line, so
/// large text never strands the unit below the value.
class RecipeParagraph extends StatelessWidget {
  const RecipeParagraph({super.key, required this.text, required this.empty});

  final String text;
  final String empty;

  // The space after a digit, before a token of up to five letters.
  static final RegExp _amountGap = RegExp(
    r'(?<=\d)[ \t](?=[\p{L}%µ°]{1,5}(?!\p{L}))',
    unicode: true,
  );

  @override
  Widget build(BuildContext context) {
    final value = text.trim();
    return Text(
      value.isEmpty ? empty : value.replaceAll(_amountGap, '\u00A0'),
      style: _bodyStyle(context.t, muted: value.isEmpty),
    );
  }
}

/// Ingredients as bullet lines (accent dot + text) under an optional
/// quantity [hint]: a [BulletList] over the non-empty lines of [text]. A
/// list marker the text already carries ("- ", "•", "*") gives way to the
/// dot.
class RecipeIngredientLines extends StatelessWidget {
  const RecipeIngredientLines({super.key, required this.text, this.hint = ''});

  final String text;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final lines = [
      for (final line in _lines(text))
        if (BulletList.stripMarker(line).isNotEmpty) line,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hint.isNotEmpty) _SectionHint(hint),
        if (lines.isEmpty)
          Text(
            context.l10n.recipesNoDataProvided,
            style: _bodyStyle(t, muted: true),
          )
        else
          BulletList(items: lines, style: _bodyStyle(t)),
      ],
    );
  }
}

/// The steps [RecipePreparationSteps] numbers, without their own markers:
/// one per non-empty line. Fewer than two read as one paragraph there.
List<String> recipePreparationSteps(String text) => [
  for (final line in _lines(text))
    if (NumberedSteps.stripMarker(line) case final step when step.isNotEmpty)
      step,
];

/// Preparation as [NumberedSteps] when the text has several lines; a single
/// paragraph stays a paragraph, an empty one shows [empty]. Numbers the
/// steps already carry ("1.", "2)") give way to the [StepNumber].
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

  @override
  Widget build(BuildContext context) {
    final steps = _lines(text);
    final Widget body = steps.length < 2
        ? RecipeParagraph(text: text, empty: empty)
        : NumberedSteps(steps: steps, style: _bodyStyle(context.t));
    if (hint.isEmpty) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_SectionHint(hint), body],
    );
  }
}

/// A round step number under its older name: a [StepNumber].
class RecipeStepBadge extends StatelessWidget {
  const RecipeStepBadge({super.key, required this.number, required this.size});

  final int number;
  final double size;

  @override
  Widget build(BuildContext context) => StepNumber(number, size: size);
}
