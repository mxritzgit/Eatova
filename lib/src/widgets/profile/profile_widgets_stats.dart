part of 'profile_widgets.dart';

class LifetimeStatsCard extends StatelessWidget {
  const LifetimeStatsCard({super.key, required this.stats});

  final LifetimeStats stats;

  @override
  Widget build(BuildContext context) {
    final duration = stats.sessionDuration;
    final since = _formatSession(duration);
    final items = <_LifetimeTile>[
      _LifetimeTile(
        icon: Icons.fitness_center,
        color: lime,
        value: stats.workoutsCompleted.toString(),
        label: 'Workouts',
      ),
      _LifetimeTile(
        icon: Icons.restaurant_menu_rounded,
        color: orange,
        value: stats.mealsLogged.toString(),
        label: 'Mahlzeiten',
      ),
      _LifetimeTile(
        icon: Icons.water_drop_outlined,
        color: cyan,
        value: _formatWater(stats.waterTotalMl),
        label: 'Wasser',
      ),
      _LifetimeTile(
        icon: Icons.monitor_weight_outlined,
        color: wellnessTone,
        value: stats.weightLogs.toString(),
        label: 'Wiegen',
      ),
    ];
    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Deine Session',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: surfaceSoft,
                  borderRadius: BorderRadius.circular(rChip),
                ),
                child: Text(
                  since,
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.85,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: items,
          ),
        ],
      ),
    );
  }

  static String _formatSession(Duration d) {
    if (d.inMinutes < 1) return 'gerade gestartet';
    if (d.inMinutes < 60) return '${d.inMinutes} Min';
    final h = d.inHours;
    final rest = d.inMinutes % 60;
    if (rest == 0) return '${h}h';
    return '${h}h $rest Min';
  }

  static String _formatWater(int ml) {
    if (ml < 1000) return '$ml ml';
    return '${(ml / 1000).toStringAsFixed(1)} L';
  }
}

class _LifetimeTile extends StatelessWidget {
  const _LifetimeTile({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(rControl),
            ),
            child: Icon(icon, color: color, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    height: 1.1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  label,
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AchievementsGrid extends StatelessWidget {
  const AchievementsGrid({
    super.key,
    required this.stats,
    required this.trackingStreak,
    required this.weightLogs,
    required this.favoritesCount,
  });

  final LifetimeStats stats;

  /// Logging-Streak (effectiveStreakOn): Tage in Folge mit >= 1 Mahlzeit.
  final int trackingStreak;
  final int weightLogs;
  final int favoritesCount;

  @override
  Widget build(BuildContext context) {
    final achievements = <_Achievement>[
      _Achievement(
        icon: Icons.local_fire_department_rounded,
        title: 'Erster Streak',
        subtitle: trackingStreak >= 1 ? 'Erreicht' : '1 Tag Essen loggen',
        color: orange,
        unlocked: trackingStreak >= 1,
      ),
      _Achievement(
        icon: Icons.calendar_view_week_rounded,
        title: '3er Streak',
        subtitle: trackingStreak >= 3
            ? 'Drei Tage am Stück'
            : '${(3 - trackingStreak).clamp(1, 3)} bis zum Badge',
        color: lime,
        unlocked: trackingStreak >= 3,
      ),
      _Achievement(
        icon: Icons.restaurant_rounded,
        title: 'Foodie',
        subtitle: stats.mealsLogged >= 5
            ? '${stats.mealsLogged} Mahlzeiten erfasst'
            : 'Logge 5 Mahlzeiten',
        color: wellnessTone,
        unlocked: stats.mealsLogged >= 5,
      ),
      _Achievement(
        icon: Icons.water_drop_rounded,
        title: 'Hydration',
        subtitle: stats.waterTotalMl >= 2000
            ? '${(stats.waterTotalMl / 1000).toStringAsFixed(1)} L erreicht'
            : '2 L Wasser tracken',
        color: cyan,
        unlocked: stats.waterTotalMl >= 2000,
      ),
      _Achievement(
        icon: Icons.monitor_weight_rounded,
        title: 'Tracker',
        subtitle: weightLogs >= 2
            ? 'Gewichtsverlauf aktiv'
            : 'Gewicht 2× loggen',
        color: lime,
        unlocked: weightLogs >= 2,
      ),
      _Achievement(
        icon: Icons.star_rounded,
        title: 'Favoriten',
        subtitle: favoritesCount >= 3
            ? '$favoritesCount Lieblings-Mahlzeiten'
            : '3 Mahlzeiten merken',
        color: orange,
        unlocked: favoritesCount >= 3,
      ),
    ];

    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Achievements',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Text(
                '${achievements.where((a) => a.unlocked).length}/${achievements.length}',
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.05,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [for (final a in achievements) _AchievementTile(data: a)],
          ),
        ],
      ),
    );
  }
}

class _Achievement {
  const _Achievement({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.unlocked,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool unlocked;
}

class _AchievementTile extends StatelessWidget {
  const _AchievementTile({required this.data});

  final _Achievement data;

  @override
  Widget build(BuildContext context) {
    final tint = data.unlocked ? data.color : textMuted;
    return AnimatedContainer(
      // A11y: Unlock-Uebergang unter "Bewegung reduzieren" auf 0.
      duration: motionDuration(context, const Duration(milliseconds: 220)),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: data.unlocked
            ? data.color.withValues(alpha: 0.10)
            : surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(
          color: data.unlocked
              ? data.color.withValues(alpha: 0.40)
              : hairline,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: data.unlocked ? 0.18 : 0.08),
              borderRadius: BorderRadius.circular(rControl),
            ),
            child: Icon(data.icon, color: tint, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  data.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: data.unlocked ? textPrimary : textPrimary
                        .withValues(alpha: 0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  data.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 10.5,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
