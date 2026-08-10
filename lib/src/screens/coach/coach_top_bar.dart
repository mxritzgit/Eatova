part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Kopfzeile nach der Design-Vorlage: quadratische Forest-Kachel mit
// Funkel-Icon, „KI-Coach" als Display-Titel, darunter ein Lime-Punkt mit der
// Zustandszeile. Rechts die drei Bedienelemente, die es schon gab: Streak,
// (i) und Unterhaltungen.
//
// Die Wortmarke „Eatova" aus der alten Leiste entfaellt — der Kopf traegt
// jetzt selbst die Marke, und die Schale zeigt sie ohnehin auf jedem Tab.
// ---------------------------------------------------------------------------
class _CoachTopBar extends StatelessWidget {
  const _CoachTopBar({
    required this.streak,
    required this.onInfoTap,
    required this.onSessionsTap,
  });

  final int streak;
  final VoidCallback onInfoTap;
  final VoidCallback onSessionsTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      // Horizontal 0: eatova_home_page.dart legt bereits 20 px um jeden Tab.
      // Die Trennlinie endet deshalb an diesem Seitenrand statt randlos zu
      // laufen — bewusst in Kauf genommen, siehe Bericht.
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 14),
      // Abweichung von der Vorlage (dort eine Row): bei textScaler 2.0 passen
      // Marke, Streak-Pille und zwei Knoepfe nicht mehr nebeneinander. Der
      // Wrap setzt die Bediengruppe dann in eine zweite Zeile, statt die
      // Zeile zu sprengen.
      child: Wrap(
        spacing: 8,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: t.forest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.auto_awesome_rounded, size: 19, color: t.lime),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      l10n.coachTitle,
                      style: AppType.display(22, color: t.ink, height: 1.1),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: t.lime,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            l10n.coachStatusLine,
                            style: AppType.ui(
                              11.5,
                              weight: FontWeight.w500,
                              color: t.ink2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _StreakPill(streak: streak),
              const SizedBox(width: 6),
              SquareIconButton(
                key: const ValueKey('coach-info'),
                icon: Icons.info_outline_rounded,
                onTap: onInfoTap,
                semanticLabel: l10n.coachInfoSemanticLabel,
              ),
              const SizedBox(width: 6),
              SquareIconButton(
                key: const ValueKey('coach-sessions-open'),
                icon: Icons.forum_outlined,
                onTap: onSessionsTap,
                semanticLabel: l10n.coachSessionsSemanticLabel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Streak-Pille im Kopf: Lime-Punkt + Tages-Zahl.
class _StreakPill extends StatelessWidget {
  const _StreakPill({required this.streak});

  final int streak;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('coach-streak'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(rPill),
        color: t.tile,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: t.lime, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          // display bringt tabellarische Ziffern mit — die Zahl springt beim
          // Zaehlen nicht.
          Text(
            '$streak',
            style: AppType.display(12.5, weight: FontWeight.w700, color: t.ink),
          ),
          const SizedBox(width: 4),
          Text(
            l10n.coachStreakUnit(streak),
            style: AppType.ui(11.5, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
