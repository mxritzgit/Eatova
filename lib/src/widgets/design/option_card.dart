import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import 'controls.dart' show SelectionTone;

// ---------------------------------------------------------------------------
// Single-choice option cards, shared by the onboarding and the Coach brief.
//
// Selection language = the settings picker sheets (polish 2026-10-02): the
// chosen card takes the accent tint, an accent outline and a filled accent
// radio with a check; the others keep the card surface and an empty ring.
// The radio and the outline carry the state at 3:1 or more (WCAG 1.4.11);
// the tint alone would not, and the text stays `ink` in both states.
// ---------------------------------------------------------------------------

/// A selection change on cards, tiles and the radio.
const Duration kSelectionDuration = Duration(milliseconds: 180);

/// Outline width, the same in both states so selecting never shifts layout.
const double kSelectionEdge = 1.5;

/// Card fill: `surf` at rest, the accent tint over it when chosen.
Color selectionCardFill(AppTokens t, bool selected) =>
    selected ? Color.alphaBlend(t.accentTint, t.surf) : t.surf;

/// Card outline: the faint card edge at rest, the accent when chosen.
Color selectionCardEdge(AppTokens t, bool selected) => selected ? t.accent : t.line;

/// 24 px radio mark: a filled accent disc with a check, or an empty ring.
class OptionRadio extends StatelessWidget {
  const OptionRadio({super.key, required this.selected, this.size = 24});

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: motionDuration(context, kSelectionDuration),
        curve: kMotionCurve,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? t.selectedFill : Colors.transparent,
          border: Border.all(
            color: selected ? t.selectedFill : t.ink3,
            width: kSelectionEdge,
          ),
        ),
        child: selected
            ? Icon(Icons.check_rounded, size: size * 0.66, color: t.onSelected)
            : null,
      ),
    );
  }
}

/// A rounded tile behind a glyph, leading an option card.
class OptionGlyphTile extends StatelessWidget {
  const OptionGlyphTile({super.key, required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Icon(icon, size: 22, color: t.accentText),
    );
  }
}

/// One answer of a single-choice question: a full-width card with an
/// optional leading mark, title, one-line consequence and the radio.
///
/// [actionKey] sits on the tap target; its semantics node is the whole card
/// (button, selected, in a mutually exclusive group).
class OptionCard extends StatelessWidget {
  const OptionCard({
    super.key,
    required this.actionKey,
    required this.selected,
    required this.onTap,
    required this.title,
    this.subtitle,
    this.leading,
    this.badge,
  });

  final Key actionKey;
  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String? subtitle;
  final Widget? leading;

  /// Short value next to the title, e.g. the PAL factor "×1,45".
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final radius = BorderRadius.circular(rCard);
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: PressScale(
          scale: kPressScaleCard,
          child: AnimatedContainer(
            duration: motionDuration(context, kSelectionDuration),
            curve: kMotionCurve,
            decoration: BoxDecoration(
              color: selectionCardFill(t, selected),
              borderRadius: radius,
              border: Border.all(color: selectionCardEdge(t, selected), width: kSelectionEdge),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: actionKey,
                onTap: onTap,
                borderRadius: radius,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 68),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
                    child: LayoutBuilder(
                      builder: (context, constraints) =>
                          _layout(context, t, constraints.maxWidth),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Mark, texts and radio in one row; once the text column would drop below
  /// ~150 px of 1.0 text (2x text on a 320 px phone left 110 px and broke
  /// "Kaloriendefizit" mid-word), the mark and radio move above the texts.
  Widget _layout(BuildContext context, AppTokens t, double width) {
    final radio = OptionRadio(selected: selected);
    final textWidth = width - (leading == null ? 0 : 58) - 36;
    final stacked =
        leading != null &&
        textWidth < MediaQuery.textScalerOf(context).scale(150);
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ExcludeSemantics(child: leading!),
              const Spacer(),
              radio,
            ],
          ),
          const SizedBox(height: 12),
          _texts(t),
        ],
      );
    }
    return Row(
      children: <Widget>[
        if (leading != null) ...<Widget>[
          ExcludeSemantics(child: leading!),
          const SizedBox(width: 14),
        ],
        Expanded(child: _texts(t)),
        const SizedBox(width: 12),
        radio,
      ],
    );
  }

  Widget _texts(AppTokens t) {
    final heading = Text(
      title,
      style: AppType.ui(
        16,
        weight: FontWeight.w700,
        color: t.ink,
        letterSpacing: -0.2,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (badge == null)
          heading
        else
          // Wrap, not Row: at 2x text the badge moves under the title instead
          // of squeezing it.
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              heading,
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: t.tile,
                  borderRadius: BorderRadius.circular(rPill),
                ),
                child: Text(
                  badge!,
                  style: AppType.display(
                    12.5,
                    weight: FontWeight.w700,
                    color: t.inkMuted,
                  ),
                ),
              ),
            ],
          ),
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: AppType.ui(13.5, color: t.ink2, height: 1.35),
          ),
        ],
      ],
    );
  }
}
