import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/macro_progress.dart';
import '../../models/user_profile.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';

class TodayMacros extends StatelessWidget {
  const TodayMacros({super.key, required this.progress, required this.profile});
  final MacroProgress progress;
  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return HeadingSemantics(
      level: 2,
      child: Semantics(
        label: l10n.todayMacrosTitle,
        explicitChildNodes: true,
        child: Column(
          key: const ValueKey('today-macros-card'),
          children: [
            TodayMacroRow(
              label: l10n.todayMacroProtein,
              value: progress.proteinG.round(),
              goal: profile.proteinGoalG,
              icon: Icons.egg_alt_outlined,
              color: t.proteinProgress,
              surface: t.proteinSurface,
            ),
            const SizedBox(height: 8),
            TodayMacroRow(
              label: l10n.todayMacroCarbs,
              value: progress.carbsG.round(),
              goal: profile.carbsGoalG,
              icon: Icons.grass_rounded,
              color: t.carbsProgress,
              surface: t.carbsSurface,
            ),
            const SizedBox(height: 8),
            TodayMacroRow(
              label: l10n.todayMacroFat,
              value: progress.fatG.round(),
              goal: profile.fatGoalG,
              icon: Icons.water_drop_outlined,
              color: t.fatProgress,
              surface: t.fatSurface,
            ),
          ],
        ),
      ),
    );
  }
}

class TodayMacroRow extends StatelessWidget {
  const TodayMacroRow({
    super.key,
    required this.label,
    required this.value,
    required this.goal,
    required this.icon,
    required this.color,
    required this.surface,
  });
  final String label;
  final int value, goal;
  final IconData icon;
  final Color color, surface;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fraction = goal <= 0 ? 0.0 : (value / goal).clamp(0.0, 1.0);
    return Semantics(
      container: true,
      label: label,
      value: context.l10n.todayMacroProgressValue(value, goal),
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(rCard),
          ),
          child: Row(
            children: [
              Icon(icon, size: 27, color: t.ink),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final large =
                            MediaQuery.textScalerOf(context).scale(14) > 18 ||
                            constraints.maxWidth < 245;
                        final title = Text(
                          label,
                          style: AppType.ui(
                            14,
                            weight: FontWeight.w600,
                            color: t.ink,
                          ),
                        );
                        final amount = Text(
                          '$value / $goal g',
                          style: AppType.ui(
                            14,
                            weight: FontWeight.w500,
                            color: t.ink,
                          ),
                        );
                        return large
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  title,
                                  const SizedBox(height: 3),
                                  amount,
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(child: title),
                                  const SizedBox(width: 8),
                                  amount,
                                ],
                              );
                      },
                    ),
                    const SizedBox(height: 8),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: fraction),
                      duration: motionDuration(
                        context,
                        const Duration(milliseconds: 320),
                      ),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(rPill),
                        child: LinearProgressIndicator(
                          borderRadius: BorderRadius.circular(rPill),
                          value: value,
                          minHeight: 8,
                          backgroundColor: t.surf,
                          valueColor: AlwaysStoppedAnimation(color),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
