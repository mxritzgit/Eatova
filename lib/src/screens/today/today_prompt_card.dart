import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

/// The one build of Today's question and notice cards (UI polish
/// 2026-11-01): a 40 px badge beside the `title2` heading, the copy in
/// `callout`, optional [details], the [actions] stacked at full width and a
/// muted [footnote] under them.
///
/// The badge centres on the title's first line; from about 1.6x text it
/// moves above the title ([listRowStacked]), which then keeps the full
/// width. The card is one semantics container named [label], so a screen
/// reader hears which question its answers belong to.
class TodayPromptCard extends StatelessWidget {
  const TodayPromptCard({
    super.key,
    required this.title,
    this.icon,
    this.glyph,
    this.glyphColor,
    this.body,
    this.bodyKey,
    this.details = const <Widget>[],
    this.actions = const <Widget>[],
    this.actionsGap = kSpace16,
    this.footnote,
    this.label,
  }) : assert(icon != null || glyph != null, 'A prompt card needs a glyph');

  final String title;

  /// The topic's glyph on an accent badge; a custom [glyph] (the steps
  /// mark) takes its place.
  final IconData? icon;
  final Widget? glyph;

  /// Tints the badge in a meaning colour (steps in `activity`) instead of
  /// the accent.
  final Color? glyphColor;

  final String? body;
  final Key? bodyKey;

  /// Content between [body] and the answers (a question, a time pill, a
  /// link); each item brings its own space above.
  final List<Widget> details;

  /// The answers top down: the lit primary first, the quiet way out last.
  final List<Widget> actions;

  /// Room above [actions]; smaller after a [TodayCardLink], whose target
  /// already leaves room around its label.
  final double actionsGap;

  /// What the card's claim rests on, centred under the answers.
  final String? footnote;

  /// The container's spoken name; null leaves the heading to speak.
  final String? label;

  /// How far a quiet pill's empty capsule reaches below its label; a card
  /// ending on one gives that back from its bottom padding, so the label
  /// sits as far from the edge as the badge does at the top.
  static const double _quietSlack = kSpace12;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final last = actions.isEmpty ? null : actions.last;
    final quietLast = last is SoftPillButton && last.tone == SoftPillTone.quiet;
    final quietEnd = quietLast && footnote == null;
    final titleStyle = AppType.title2(t.ink);
    final badge = IconBadge(
      icon: icon,
      tone: IconBadgeTone.accent,
      color: glyphColor,
      child: glyph,
    );
    final heading = HeadingSemantics(
      level: 2,
      child: Text(title, style: titleStyle),
    );
    final Widget header;
    if (listRowStacked(context)) {
      header = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[badge, const SizedBox(height: kSpace12), heading],
      );
    } else {
      // Badge and first line share a centre, whichever is taller.
      final line =
          MediaQuery.textScalerOf(context).scale(titleStyle.fontSize!) *
          titleStyle.height!;
      final edge = IconBadgeSize.md.edge;
      header = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: math.max(0, (line - edge) / 2)),
            child: badge,
          ),
          const SizedBox(width: kRowLeadingGap),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: math.max(0, (edge - line) / 2)),
              child: heading,
            ),
          ),
        ],
      );
    }
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: label,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          kCardInset,
          kCardInset,
          kCardInset,
          quietEnd ? kCardInset - _quietSlack : kCardInset,
        ),
        decoration: BoxDecoration(
          color: t.surf,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: t.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            header,
            if (body case final body?) ...<Widget>[
              const SizedBox(height: kSpace12),
              Text(body, key: bodyKey, style: AppType.callout(t.ink2)),
            ],
            ...details,
            if (actions.isNotEmpty) ...<Widget>[
              SizedBox(height: actionsGap),
              for (var i = 0; i < actions.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: kSpace8),
                actions[i],
              ],
            ],
            if (footnote case final footnote?) ...<Widget>[
              // Under a quiet pill its empty capsule already gives room.
              SizedBox(height: quietLast ? kSpace4 : kSpace12),
              Text(
                footnote,
                textAlign: TextAlign.center,
                style: AppType.subhead(t.ink3),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Two secondary answers side by side while both labels fit half the width
/// on one line, otherwise stacked, first on top.
class TodayActionPair extends StatelessWidget {
  const TodayActionPair({
    super.key,
    required this.first,
    required this.second,
    required this.labels,
  });

  final Widget first, second;

  /// The two buttons' labels, measured for the side-by-side decision.
  final (String, String) labels;

  /// [SoftPillButton]'s chrome around its label: 20 px padding per side,
  /// the 18 px icon and its 8 px gap.
  static const double _pillChrome = 66;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final half = (constraints.maxWidth - kSpace8) / 2;
      final (a, b) = labels;
      final beside = <String>[a, b].every(
        (label) => _labelWidth(context, label) + _pillChrome <= half,
      );
      if (!beside) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[first, const SizedBox(height: kSpace8), second],
        );
      }
      return Row(
        children: <Widget>[
          Expanded(child: first),
          const SizedBox(width: kSpace8),
          Expanded(child: second),
        ],
      );
    },
  );

  /// [label] on one line in [SoftPillButton]'s style at the system font.
  static double _labelWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: AppType.ui(14, weight: FontWeight.w700),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

/// A link inside a prompt card's copy (the changed terms, how the check
/// works): an [EatovaTextAction] whose glyph lines up with the text above,
/// while its press capsule reaches into the card's padding.
class TodayCardLink extends StatelessWidget {
  const TodayCardLink({
    super.key,
    required this.buttonKey,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final Key buttonKey;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// [EatovaTextAction]'s horizontal padding without a capsule.
  static const double _inset = 12;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Transform.translate(
      // Towards the start edge (x -1 in LTR, +1 in RTL).
      offset: Offset(
        _inset *
            AlignmentDirectional.centerStart
                .resolve(Directionality.of(context))
                .x,
        0,
      ),
      child: EatovaTextAction(
        buttonKey: buttonKey,
        onTap: onTap,
        icon: icon,
        iconSize: AppIconSize.small,
        label: label,
      ),
    ),
  );
}
