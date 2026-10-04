part of 'profile_widgets.dart';

/// One metric: a tinted icon tile beside its label and the large number with
/// its unit — the Training quick tiles' and Today rows' language.
///
/// [framed] draws the tile card; the hero passes `false` to set the streak
/// straight onto its own surface. [tone] tints the icon tile (default the
/// accent).
///
/// Not named `StatTile`: this library imports the whole design barrel, and
/// that generic a name would eventually collide.
class ProfileStatTile extends StatelessWidget {
  const ProfileStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    this.icon,
    this.tone,
    this.framed = true,
    this.large = false,
    this.count,
  });

  final String label;
  final String value;
  final String unit;
  final IconData? icon;
  final Color? tone;
  final bool framed;

  /// Hero-sized number (the streak).
  final bool large;

  /// The number behind [value]; when given, the tile counts up to it on
  /// first display (instant under reduced motion).
  final int? count;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final numberStyle = AppType.display(
      large ? 30 : 22,
      weight: FontWeight.w700,
      color: t.ink,
      letterSpacing: large ? -0.6 : -0.4,
      height: 1.1,
    );
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          label,
          style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
        ),
        const SizedBox(height: 2),
        // Let the unit move below the number instead of shrinking text.
        Wrap(
          spacing: 5,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: <Widget>[
            if (count == null)
              Text(value, style: numberStyle)
            else
              CountingText(
                value: count!.toDouble(),
                format: (v) => '${v.round()}',
                style: numberStyle,
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                unit,
                style: AppType.ui(13, weight: FontWeight.w500, color: t.ink3),
              ),
            ),
          ],
        ),
      ],
    );
    final content = icon == null
        ? texts
        : Row(
            children: <Widget>[
              _profileTile(icon!, tone ?? t.accent, size: large ? 44 : 36),
              SizedBox(width: large ? 12 : 10),
              Expanded(child: texts),
            ],
          );
    if (!framed) return content;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rTile),
        border: Border.all(color: t.cardBorder),
      ),
      child: content,
    );
  }
}

/// The page's icon tile: [icon] on a rounded tile tinted by [tone], the glyph
/// in the tone's readable ink ([IconTile]); neutral without a tone.
/// Decorative: every tile stands next to its own label.
Widget _profileTile(IconData icon, Color? tone, {double size = 40}) =>
    ExcludeSemantics(
      child: IconTile.custom(
        color: tone,
        size: size,
        child: Icon(icon, size: size * 0.5),
      ),
    );

/// Equal-height tiles side by side, stacking when larger text needs room.
///
/// `IntrinsicHeight` instead of a fixed height: the tiles may grow with the
/// system font but must not end up different heights.
class ProfileStatRow extends StatelessWidget {
  const ProfileStatRow({
    super.key,
    required this.left,
    required this.right,
    this.gap = 12,
  });

  final Widget left;
  final Widget right;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minTileWidth = MediaQuery.textScalerOf(context).scale(140);
        if (constraints.maxWidth < minTileWidth * 2 + gap) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[left, SizedBox(height: gap), right],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: left),
              SizedBox(width: gap),
              Expanded(child: right),
            ],
          ),
        );
      },
    );
  }
}
