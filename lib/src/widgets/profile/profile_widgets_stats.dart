part of 'profile_widgets.dart';

/// Eine Kennzahl-Kachel: Versalien-Label, grosse Zahl, Einheit.
///
/// Heisst bewusst nicht einfach `StatTile`: die Bibliothek importiert die
/// gesamte Design-Barrel, und ein so generischer Name waere ein Kandidat fuer
/// eine spaetere Namenskollision mit einem gemeinsamen Baustein.
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
          // Zahl und Einheit stehen in einer halben Kartenbreite. Ohne
          // Flexible + FittedBox platzt die Zwei-Spalten-Reihe bei
          // textScaler 2.0 — genau die Bruchstelle aus §5 des Vertrags.
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

/// Zwei Kacheln nebeneinander, gleich hoch.
///
/// `IntrinsicHeight` statt einer festen Hoehe: die Kacheln duerfen mit der
/// Systemschrift wachsen, sollen dabei aber nicht unterschiedlich hoch werden.
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

