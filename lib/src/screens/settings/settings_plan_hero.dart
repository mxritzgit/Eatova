import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_tokens.dart';
import 'settings_controls.dart';

// ---------------------------------------------------------------------------
// The settings plan card: what body, activity and goal currently produce.
//
// One hero card in the Today language (polish 2026-10-02): `surf` with the
// violet glow, the daily target as the big display number, maintenance and
// pace under it, and the three macros below a hairline. Macro tones mark the
// dots only, never the numbers: on `surf` in light mode `carbs` reaches
// 3.39:1 and `fat` 3.73:1, enough for a graphic, short of text.
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
    final eyebrow = manual
        ? l10n.settingsPlanHeroEyebrowManual
        : l10n.settingsPlanHeroEyebrow;
    // The number is large text already; past 1.5x it would push the unit off
    // a narrow phone without adding legibility.
    final numberScaler =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.5);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rHero),
            border: Border.all(color: t.cardBorder),
          ),
          child: Stack(
            children: <Widget>[
              // The Today hero's violet glow, pulled to the top corner
              // behind the number.
              Positioned(
                top: -90,
                right: -70,
                width: 300,
                height: 260,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: <Color>[
                          t.arcStart.withValues(alpha: 0.24 * t.glowStrength),
                          t.arcStart.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            eyebrow,
                            // Stable handle for tests: without it they hang
                            // off the ARB text, which every wording change
                            // breaks.
                            key: ValueKey(
                              manual
                                  ? 'settings-plan-eyebrow-manual'
                                  : 'settings-plan-eyebrow-live',
                            ),
                            style: AppType.sectionEyebrow(t.accentText),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Calculated or hand-set, as a glyph on the rows'
                        // icon tile; the eyebrow says it in words.
                        ExcludeSemantics(
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: t.accentTintStrong,
                              borderRadius: BorderRadius.circular(rChip),
                            ),
                            child: Icon(
                              manual
                                  ? Icons.edit_rounded
                                  : Icons.calculate_outlined,
                              size: 20,
                              color: t.accentText,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.end,
                      spacing: 8,
                      children: <Widget>[
                        Text(
                          '$kcal',
                          textScaler: numberScaler,
                          style: AppType.display(60, color: t.ink, height: 1),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            l10n.commonKcalUnit,
                            style: AppType.ui(
                              16,
                              weight: FontWeight.w700,
                              color: t.ink2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.settingsPlanHeroMaintenance(
                        targets.maintenanceKcal,
                        _paceLabel(l10n),
                      ),
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Divider(height: 1, thickness: 1, color: t.line),
                    const SizedBox(height: 16),
                    _MacroRow(
                      tiles: <_MacroTile>[
                        _MacroTile(
                          label: l10n.todayMacroProtein,
                          value: '$protein',
                          unit: l10n.commonUnitG,
                          color: t.protein,
                        ),
                        _MacroTile(
                          label: l10n.foodMacroTileCarbsLabel,
                          value: '$carbs',
                          unit: l10n.commonUnitG,
                          color: t.carbs,
                        ),
                        _MacroTile(
                          label: l10n.todayMacroFat,
                          value: '$fat',
                          unit: l10n.commonUnitG,
                          color: t.fat,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
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

/// The three macro columns. Text scaling as a layout feature (F8-09): each
/// column reserves its width from the text scaler, and the row wraps to two
/// or three lines instead of shrinking the text.
class _MacroRow extends StatelessWidget {
  const _MacroRow({required this.tiles});

  final List<_MacroTile> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        final scaler = MediaQuery.textScalerOf(context);
        // 88 px holds "Kohlenhydrate" over "240 g" at scale 1.0 inside a
        // third of the card; scaled with the font so the label stays legible.
        final minTile = scaler.scale(88);
        final width = constraints.maxWidth;
        final perRow = ((width + gap) / (minTile + gap)).floor().clamp(1, 3);
        // One per line: label left, grams right, so the card stays short.
        if (perRow == 1) {
          return Column(
            children: <Widget>[
              for (var i = 0; i < tiles.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 10),
                tiles[i].asLine(context),
              ],
            ],
          );
        }
        final tileWidth = (width - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: 14,
          children: <Widget>[
            for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }
}

class _MacroTile extends StatelessWidget {
  const _MacroTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;

  /// Macro tone for the MARKER only, never for the number (see file header).
  final Color color;

  Widget _dot() => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  Widget _amount(AppTokens t) => Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: value,
              style: AppType.display(22, weight: FontWeight.w800, color: t.ink),
            ),
            TextSpan(
              text: ' $unit',
              style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
            ),
          ],
        ),
        maxLines: 1,
      );

  /// The single-line variant for large text sizes.
  Widget asLine(BuildContext context) {
    final t = context.t;
    return MergeSemantics(
      child: Row(
        children: <Widget>[
          _dot(),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
            ),
          ),
          const SizedBox(width: 10),
          _amount(t),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // One spoken unit per macro: "Protein, 131 g".
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _dot(),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          _amount(t),
        ],
      ),
    );
  }
}
