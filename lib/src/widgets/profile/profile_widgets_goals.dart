part of 'profile_widgets.dart';

/// Daily goals as one card: today's calories and steps against their goals,
/// the macro split as a bar with legend, and the edit entry point.
class GoalsCard extends StatelessWidget {
  const GoalsCard({
    super.key,
    required this.profile,
    required this.dailyKcal,
    required this.dailySteps,
    this.onEdit,
  });

  final UserProfile profile;
  final int dailyKcal;
  final int? dailySteps;
  final VoidCallback? onEdit;

  static double _fraction(int? value, int goal) =>
      value == null || goal <= 0 ? 0 : (value / goal).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final protein = profile.proteinGoalG;
    final carbs = profile.carbsGoalG;
    final fat = profile.fatGoalG;
    final hatMakros = protein + carbs + fat > 0;

    return AppCard(
      clip: true,
      child: Column(
        children: <Widget>[
          _GoalRow(
            leading: IconTile(
              icon: Icons.local_fire_department_rounded,
              color: t.accent,
            ),
            title: l10n.profileGoalsCalories,
            // Exactly this text ('<actual>/<goal>', no spaces) is what
            // profile_route_refresh_test asserts; one Text.rich keeps it
            // findable while the goal part steps back.
            actual: '$dailyKcal',
            goal: '/${profile.dailyKcalGoal}',
            fraction: _fraction(dailyKcal, profile.dailyKcalGoal),
            color: t.progressAccent,
          ),
          Divider(height: 1, thickness: 1, color: t.line),
          _GoalRow(
            leading: IconTile.custom(
              color: t.activity,
              child: const StepsIcon(),
            ),
            title: l10n.profileGoalsSteps,
            actual: '${dailySteps ?? '–'}',
            goal: '/${profile.dailyStepsGoal}',
            fraction: _fraction(dailySteps, profile.dailyStepsGoal),
            color: t.activity,
          ),
          if (hatMakros) ...<Widget>[
            Divider(height: 1, thickness: 1, color: t.line),
            _MacroSplitBlock(protein: protein, carbs: carbs, fat: fat),
          ],
          if (onEdit != null) ...<Widget>[
            Divider(height: 1, thickness: 1, color: t.line),
            SettingsRow(
              key: const ValueKey('profile-edit-goals'),
              leading: IconTile(icon: Icons.tune_rounded, color: t.accent),
              title: l10n.profileGoalsEditCta,
              titleColor: t.accentText,
              onTap: onEdit,
            ),
          ],
        ],
      ),
    );
  }
}

/// A daily goal: icon, name and "actual/goal" right-aligned, with a thin bar
/// for today's share underneath.
class _GoalRow extends StatelessWidget {
  const _GoalRow({
    required this.leading,
    required this.title,
    required this.actual,
    required this.goal,
    required this.fraction,
    required this.color,
  });

  final Widget leading;
  final String title;
  final String actual;
  final String goal;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Row(
        children: <Widget>[
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Wrap: at large text the numbers move under the name
                // instead of squeezing it.
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: 12,
                  runSpacing: 2,
                  children: <Widget>[
                    Text(
                      title,
                      style: AppType.ui(
                        13.5,
                        weight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                    Text.rich(
                      TextSpan(
                        text: actual,
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w700,
                          color: t.ink,
                        ),
                        children: <InlineSpan>[
                          TextSpan(
                            text: goal,
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w500,
                              color: t.ink3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: fraction),
                  duration: motionDuration(context, kMotionValue),
                  curve: kMotionCurve,
                  builder: (context, value, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: value,
                      minHeight: 5,
                      backgroundColor: t.tile,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
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

/// Macro split as one bar instead of three rings: the shares compare directly
/// and the legend names the absolute grams.
class _MacroSplitBlock extends StatelessWidget {
  const _MacroSplitBlock({
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final int protein, carbs, fat;

  /// `Expanded` with flex 0 makes its child unbounded and throws in a Row; a
  /// macro goal of 0 g is allowed, so the bar must survive it.
  static int _flex(int value) => value < 1 ? 1 : value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(icon: Icons.donut_small_rounded, color: t.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.profileMacroSplitTitle,
                  style:
                      AppType.ui(13.5, weight: FontWeight.w600, color: t.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Semantics(
            label: l10n.profileMacroSplitTitle,
            value: '${l10n.profileMacroAmountLabel(protein, l10n.todayMacroProtein)}, '
                '${l10n.profileMacroAmountLabel(carbs, l10n.todayMacroCarbs)}, '
                '${l10n.profileMacroAmountLabel(fat, l10n.todayMacroFat)}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: SizedBox(
                height: 9,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      flex: _flex(protein),
                      child: ColoredBox(color: t.protein),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      flex: _flex(carbs),
                      child: ColoredBox(color: t.carbs),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      flex: _flex(fat),
                      child: ColoredBox(color: t.fat),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Wrap instead of Row: three legend entries no longer fit side by
          // side at textScaler 2.0.
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: <Widget>[
              _LegendDot(
                color: t.protein,
                label: l10n.profileMacroAmountLabel(
                  protein,
                  l10n.todayMacroProtein,
                ),
              ),
              _LegendDot(
                color: t.carbs,
                label: l10n.profileMacroAmountLabel(
                  carbs,
                  l10n.todayMacroCarbs,
                ),
              ),
              _LegendDot(
                color: t.fat,
                label: l10n.profileMacroAmountLabel(fat, l10n.todayMacroFat),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        // Flexible + ellipsis: the Wrap only breaks BETWEEN legend entries,
        // not within one, which would overflow at 2x system font.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
          ),
        ),
      ],
    );
  }
}
