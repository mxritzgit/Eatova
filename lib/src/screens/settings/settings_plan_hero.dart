import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'settings_controls.dart';

// ---------------------------------------------------------------------------
// The settings plan card: what body, activity and goal currently produce.
//
// Split by contrast, not taste: the hero carries maintenance, pace and the big
// kcal number on [AppTokens.forest]; the three macro tiles sit BELOW on the
// page ground, because [AppTokens.protein] on forest drops under 2:1 in light
// mode and the nutrient coding would be unreadable.
// ---------------------------------------------------------------------------

/// Weekly rate in kg that a given [tagesziel] yields against [erhaltung];
/// negative means losing.
///
/// **The only place where kcal becomes a pace.** Plan card and weight-goal row
/// must show the same number (B2). For the calculated target this equals
/// [KcalTargets.effectiveWeeklyRateKg]; in manual mode the user's own number
/// counts.
double wochenrateKg({required int tagesziel, required int erhaltung}) =>
    (tagesziel - erhaltung) * 7 / kcalPerKgBodyMass;

class SettingsPlanHero extends StatelessWidget {
  const SettingsPlanHero({
    super.key,
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.targets,
    required this.manual,
  });

  final int kcal;
  final int protein;
  final int carbs;
  final int fat;
  final KcalTargets targets;
  final bool manual;

  /// Whether the card shows the calculated target. Once the user sets their
  /// own number, [targets] no longer describes what is on the card, so pace
  /// and note must come from the displayed number.
  bool get _zeigtRechnung => kcal == targets.kcal;

  /// Pace derived from the number actually shown on the card — not the
  /// *chosen* pace (B2), which contradicted the displayed kcal.
  String _paceLabel(AppLocalizations l10n) => paceLabelForWeeklyRateKg(
        wochenrateKg(tagesziel: kcal, erhaltung: targets.maintenanceKcal),
        l10n,
      );

  /// The safety-clamp explanation, only when the card shows the calculated
  /// target.
  String? _paceWarning(AppLocalizations l10n) =>
      _zeigtRechnung ? targets.paceWarning(l10n) : null;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final warnung = _paceWarning(l10n);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.forest,
            borderRadius: BorderRadius.circular(rHero),
          ),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: DotGridBackground(
                  color: t.onForest.withValues(alpha: 0.07),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: t.onForest.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(rChip),
                          ),
                          child: Icon(
                            manual
                                ? Icons.edit_rounded
                                : Icons.auto_awesome_rounded,
                            size: 17,
                            color: t.lime,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                manual
                                    ? l10n.settingsPlanHeroEyebrowManual
                                    : l10n.settingsPlanHeroEyebrow,
                                // Stable handle for tests: without it they
                                // hang off the ARB text, which every wording
                                // change breaks.
                                key: ValueKey(
                                  manual
                                      ? 'settings-plan-eyebrow-manual'
                                      : 'settings-plan-eyebrow-live',
                                ),
                                style: AppType.eyebrow(
                                  t.onForest.withValues(alpha: 0.70),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                l10n.settingsPlanHeroMaintenance(
                                  targets.maintenanceKcal,
                                  _paceLabel(l10n),
                                ),
                                style: AppType.ui(
                                  12,
                                  weight: FontWeight.w500,
                                  color: t.onForest.withValues(alpha: 0.82),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            '$kcal',
                            maxLines: 1,
                            style: AppType.display(46, color: t.lime, height: 1),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.commonKcalUnit,
                          style: AppType.ui(
                            14,
                            weight: FontWeight.w700,
                            color: t.onForest.withValues(alpha: 0.70),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Text scaling as a layout feature (F8-09): FittedBox.scaleDown kept
        // the 11-px labels at 11 px whatever the system font. The tiles now
        // reserve their width from the text scaler and wrap to two or three
        // rows instead of shrinking the text.
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 10.0;
            final scaler = MediaQuery.textScalerOf(context);
            // 96 px holds "240 g" over "Kohlenhydrate" at scale 1.0 inside a
            // third of the 335-px page; scaled with the font so the label
            // stays legible instead of shrinking.
            final minTile = scaler.scale(96);
            final width = constraints.maxWidth;
            final perRow =
                ((width + gap) / (minTile + gap)).floor().clamp(1, 3);
            final tileWidth = (width - gap * (perRow - 1)) / perRow;
            final tiles = <Widget>[
              _MacroTile(
                label: l10n.todayMacroProtein,
                value: '$protein ${l10n.commonUnitG}',
                color: t.protein,
              ),
              _MacroTile(
                label: l10n.foodMacroTileCarbsLabel,
                value: '$carbs ${l10n.commonUnitG}',
                color: t.carbs,
              ),
              _MacroTile(
                label: l10n.todayMacroFat,
                value: '$fat ${l10n.commonUnitG}',
                color: t.fat,
              ),
            ];
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
              ],
            );
          },
        ),
        if (warnung != null) ...<Widget>[
          const SizedBox(height: 12),
          SettingsNote(
            warnung,
            key: const ValueKey('settings-pace-warning'),
            tone: t.warning,
            icon: Icons.health_and_safety_outlined,
            boxed: true,
          ),
        ],
      ],
    );
  }
}

class _MacroTile extends StatelessWidget {
  const _MacroTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Width is reserved by the parent from the text scaler, so the texts keep
    // their scaled size; ellipsis is the safety net, not the plan.
    return AppCard(
      radius: rControl,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      child: Column(
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppType.display(16, weight: FontWeight.w700, color: color),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppType.ui(11, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
