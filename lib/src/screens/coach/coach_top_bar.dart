part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Top-Bar (AI Coach v2): Streak-Pill oben LINKS, Wortmarke mittig, (i) +
// Sessions rechts. Die Pill zeigt den echten Streak aus lifetimeStats.
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
    return SizedBox(
      height: 48,
      child: Stack(
        children: [
          const Center(
            child: Text(
              'Eatova',
              style: TextStyle(
                color: textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(child: _StreakPill(streak: streak)),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TopChip(
                    key: const ValueKey('coach-info'),
                    onTap: onInfoTap,
                    child: const Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _TopChip(
                    key: const ValueKey('coach-sessions-open'),
                    onTap: onSessionsTap,
                    child: const Icon(
                      Icons.forum_outlined,
                      size: 18,
                      color: textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Streak-Pill (oben links): Akzent-Punkt + Tages-Zahl. Rahmenlos wie die
/// uebrigen Soft-Flaechen der App.
class _StreakPill extends StatelessWidget {
  const _StreakPill({required this.streak});

  final int streak;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('coach-streak'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(rPill),
        color: surfaceSoft.withValues(alpha: 0.7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: coachAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$streak',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: textPrimary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 4),
          Text(
            streak == 1 ? 'Tag' : 'Tage',
            style: const TextStyle(fontSize: 11.5, color: textMuted),
          ),
        ],
      ),
    );
  }
}

class _TopChip extends StatelessWidget {
  const _TopChip({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: surfaceSoft,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 36, height: 36, child: Center(child: child)),
      ),
    );
  }
}
