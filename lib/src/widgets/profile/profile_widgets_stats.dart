part of 'profile_widgets.dart';

/// One metric tile: uppercase label, large number, unit.
///
/// Not named `StatTile`: this library imports the whole design barrel, and
/// that generic a name would eventually collide.
class ProfileStatTile extends StatelessWidget {
  const ProfileStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      radius: 20,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(label, style: AppType.eyebrow(t.ink2, size: 9.5)),
          const SizedBox(height: 6),
          // Number and unit share half a card width; without Flexible +
          // FittedBox the two-column row overflows at textScaler 2.0 (§5).
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: AppType.display(28, color: t.ink),
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    unit,
                    style:
                        AppType.ui(11, weight: FontWeight.w500, color: t.ink2),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Two tiles side by side, equal height.
///
/// `IntrinsicHeight` instead of a fixed height: the tiles may grow with the
/// system font but must not end up different heights.
class ProfileStatRow extends StatelessWidget {
  const ProfileStatRow({super.key, required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: left),
          const SizedBox(width: 12),
          Expanded(child: right),
        ],
      ),
    );
  }
}

