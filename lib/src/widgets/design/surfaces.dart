import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';

// ---------------------------------------------------------------------------
// SURFACES — card, section heading.
//
// Geometry, radii and spacing come from the design template; colors only from
// [AppTokens], type only from [AppType].
// ---------------------------------------------------------------------------

/// Marks [child] as a heading, so screen readers can jump to it.
///
/// Flutter sets no heading flag on its own — neither [Text] nor a large type
/// style implies one — so every jump mark in the app comes from here.
///
/// The rank scheme (review 2026-08-29):
///   1  the title of a screen or sheet — [PageHeader],
///   2  a section inside it — [SectionHeading], the [SettingsGroup] caption.
///
/// `header` is the trait TalkBack and VoiceOver navigate by; `headingLevel`
/// adds the rank on top (`aria-level` on web, `isHeading` on Android) and is
/// ignored where the platform has no notion of it.
///
/// `container: true` is load-bearing, not decoration. Every child of a
/// [ListView] is wrapped in an `IndexedSemantics`, which absorbs all compatible
/// descendants into a single node — on the settings page the back button and
/// the page title were one node reading "Zurück Einstellungen". Without a node
/// of its own the heading would inherit that whole label, and the jump mark
/// would announce the neighbours too.
///
/// Wrap the title text ONLY. Put this around a row that also holds a back
/// button or an action and their tap actions land inside the heading node (the
/// pattern that bit PR #53).
class HeadingSemantics extends StatelessWidget {
  const HeadingSemantics({
    super.key,
    required this.level,
    required this.child,
  }) : assert(level >= 1 && level <= 6, 'Heading level must be between 1 and 6');

  final int level;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        header: true,
        headingLevel: level,
        child: child,
      );
}

/// The base surface: calm card, 1 px border, no shadow.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = rCard,
    this.color,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? color;

  /// Clips the content at the radius and drops the padding — for cards whose
  /// children run to the edge.
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: color ?? t.surf,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: t.line),
      ),
      padding: clip ? EdgeInsets.zero : padding,
      child: child,
    );
  }
}

/// A floating surface in the depth-and-light language (2026-10-25): the lit
/// top of [litSurface] and a shadow instead of a hairline. [decision] gives
/// the deeper contact-plus-ambient [decisionShadow] of a surface the eye
/// should land on (the paywall's plan picker); otherwise [raisedShadow].
class LitSurface extends StatelessWidget {
  const LitSurface({
    super.key,
    required this.child,
    this.radius = rHero,
    this.padding = EdgeInsets.zero,
    this.decision = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool decision;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: litSurface(t),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: decision ? decisionShadow(t) : raisedShadow(t),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// The "lit" mark: a small accent dot casting its light. It means "on now"
/// (Premium is active, the trial starts today, the paywall eyebrow); unlit
/// it is a faint neutral dot for "later", Free or off. Decorative: no
/// semantics of its own; the state is always said in words next to it.
class LitDot extends StatelessWidget {
  const LitDot({super.key, this.lit = true, this.size = 8, this.color});

  final bool lit;
  final double size;

  /// A lit dot in another state tone (`warning` for a held subscription);
  /// null is the accent.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final tone = color ?? t.accentFill;
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: motionDuration(context, kMotionEnter),
        curve: kMotionCurve,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: lit ? tone : t.inkFaint,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: lit
                  ? (color == null ? t.accentGlow : tone.withValues(alpha: 0.4))
                  : Colors.transparent,
              blurRadius: size * 1.2,
              spreadRadius: size * 0.1,
            ),
          ],
        ),
      ),
    );
  }
}

/// The heading above a group of cards.
class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, required this.title, this.trailing});

  final String title;

  /// Muted addition on the right (period, goal, action).
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          // One rank below the screen title; the muted [trailing] is no jump
          // mark of its own.
          child: HeadingSemantics(
            level: 2,
            child: Text(
              title,
              style:
                  AppType.display(17, weight: FontWeight.w700, color: t.ink),
            ),
          ),
        ),
        // Flexible instead of a fixed text: at textScaler 2.0 the trailing
        // text would burst the row. The Align puts a short label flush with
        // the card edge; a loose Flexible alone left it at the half mark.
        if (trailing != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                heightFactor: 1,
                child: Text(
                  trailing!,
                  textAlign: TextAlign.end,
                  style: AppType.ui(
                    11.5,
                    weight: FontWeight.w600,
                    color: t.ink2,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
