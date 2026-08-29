import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// SURFACES — card, page title, section heading, image placeholder, add slot.
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
///   1  the title of a screen or sheet — [ScreenTitle], [PageHeader],
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

/// The large page title at the top of a screen.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Title only: the subtitle is context, and [trailing] keeps its
              // own node with its own tap action.
              HeadingSemantics(
                level: 1,
                child: Text(
                  title,
                  style: AppType.display(30, color: t.ink, height: 1.1),
                ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style:
                      AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
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
        // text would burst the row.
        if (trailing != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(
                trailing!,
                textAlign: TextAlign.right,
                style: AppType.ui(
                  11.5,
                  weight: FontWeight.w600,
                  color: t.ink2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Diagonally striped surface standing in for a missing photo.
class ImagePlaceholder extends StatelessWidget {
  const ImagePlaceholder({
    super.key,
    this.radius = rControl,
    this.label = 'BILD',
  });

  final double radius;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CustomPaint(
        painter: _StripePainter(base: t.surf2, stripe: t.tile),
        child: Center(
          child: Text(label, style: AppType.eyebrow(t.ink2, size: 9)),
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  _StripePainter({required this.base, required this.stripe});

  final Color base, stripe;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final stripePaint = Paint()
      ..color = stripe
      ..strokeWidth = 10;
    for (double x = -size.height; x < size.width + size.height; x += 20) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0),
          stripePaint);
    }
  }

  // The stripe pattern depends only on the two tones; size is handled by
  // Flutter via the new canvas.
  @override
  bool shouldRepaint(_StripePainter old) =>
      old.base != base || old.stripe != stripe;
}

/// Dashed "add something here" slot at the end of a list.
class DottedAddSlot extends StatelessWidget {
  const DottedAddSlot({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rControl),
      child: CustomPaint(
        painter: _DashedBorderPainter(color: t.line, radius: rControl),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          alignment: Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.75, 0.75, size.width - 1.5, size.height - 1.5),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);

    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = (d + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
