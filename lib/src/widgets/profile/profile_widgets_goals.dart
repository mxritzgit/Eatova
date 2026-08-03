part of 'profile_widgets.dart';

class GoalsOverviewCard extends StatelessWidget {
  const GoalsOverviewCard({
    super.key,
    required this.profile,
    required this.dailyKcal,
    required this.dailySteps,
    this.onEdit,
  });

  final UserProfile profile;
  final int dailyKcal;
  final int dailySteps;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final goals = <_Goal>[
      _Goal(
        label: 'Kcal',
        current: dailyKcal,
        target: profile.dailyKcalGoal,
        unit: 'kcal',
        color: orange,
        icon: Icons.local_fire_department_outlined,
      ),
      _Goal(
        label: 'Schritte',
        current: dailySteps,
        target: profile.dailyStepsGoal,
        unit: '',
        color: lime,
        icon: Icons.directions_walk_outlined,
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
                  'Tagesziele',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (onEdit != null)
                TextButton(
                  key: const ValueKey('profile-edit-goals'),
                  onPressed: onEdit,
                  style: TextButton.styleFrom(
                    foregroundColor: textPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Anpassen',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [for (final g in goals) _GoalTile(goal: g)],
          ),
        ],
      ),
    );
  }
}

class _Goal {
  _Goal({
    required this.label,
    required this.current,
    required this.target,
    required this.unit,
    required this.color,
    required this.icon,
  });

  final String label;
  final int current;
  final int target;
  final String unit;
  final Color color;
  final IconData icon;

  double get ratio =>
      target <= 0 ? 0 : (current / target).clamp(0.0, 1.0).toDouble();
}

class _GoalTile extends StatelessWidget {
  const _GoalTile({required this.goal});

  final _Goal goal;

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
          SizedBox(
            width: 38,
            height: 38,
            // A11y: Fortschritts-Ring ansagen; der Wert daneben nennt die
            // absoluten Zahlen, hier reicht die Prozent-Erfuellung.
            child: Semantics(
              label: '${goal.label} Fortschritt',
              value: '${(goal.ratio * 100).round()}%',
              child: Stack(
                alignment: Alignment.center,
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      size: const Size(38, 38),
                      painter:
                          MiniRingPainter(value: goal.ratio, color: goal.color),
                    ),
                  ),
                  Icon(goal.icon, color: goal.color, size: 14),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  goal.label,
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${goal.current}/${goal.target}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    fontFeatures: [FontFeature.tabularFigures()],
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
