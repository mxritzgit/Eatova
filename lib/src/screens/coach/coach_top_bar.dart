part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Header: square forest tile with sparkle icon, display title, lime dot plus
// status line below, and the three controls on the right (streak, (i),
// sessions). No wordmark here — the app shell shows it on every tab.
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
      // Horizontal 0: eatova_home_page.dart already adds 20 px per tab, so the
      // divider ends at that inset instead of running edge to edge (accepted).
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 14),
      // Wrap instead of Row: at textScaler 2.0 title, streak pill and two
      // buttons no longer fit on one line; the control group moves down.
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
                    // The tab's rank-1 mark (P9-06c). It sits here and not on
                    // the hero because this header is on screen in EVERY
                    // state; the hero only exists while the chat is empty.
                    // Title only: the status line below is context, and the
                    // three controls on the right keep their own nodes.
                    HeadingSemantics(
                      level: 1,
                      child: Text(
                        l10n.coachTitle,
                        style: AppType.display(22, color: t.ink, height: 1.1),
                      ),
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

/// Streak pill in the header: lime dot plus day count.
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
          // display has tabular figures, so the number does not jitter.
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
