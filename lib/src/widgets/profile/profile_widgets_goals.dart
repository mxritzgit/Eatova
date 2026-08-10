part of 'profile_widgets.dart';

/// Die Tagesziele als Einstellungs-Karte: zwei Zustandszeilen, der
/// Makro-Split als Balken mit Legende und der Weg zum Bearbeiten.
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
  final int dailySteps;
  final VoidCallback? onEdit;

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
          SettingsRow(
            leading: const IconTile(icon: Icons.local_fire_department_outlined),
            title: l10n.profileGoalsCalories,
            // GENAU dieses Format ('<ist>/<soll>', ohne Leerzeichen) traegt den
            // Live-Refresh-Beweis in profile_route_refresh_test. MacroBar aus
            // der Design-Bibliothek rendert '1000 / 8000' und ist hier deshalb
            // nicht verwendbar.
            value: '$dailyKcal/${profile.dailyKcalGoal}',
            chevron: false,
          ),
          Divider(height: 1, thickness: 1, color: t.line),
          SettingsRow(
            leading: const IconTile(icon: Icons.directions_walk_outlined),
            title: l10n.profileGoalsSteps,
            value: '$dailySteps/${profile.dailyStepsGoal}',
            chevron: false,
          ),
          if (hatMakros) ...<Widget>[
            Divider(height: 1, thickness: 1, color: t.line),
            _MacroSplitBlock(protein: protein, carbs: carbs, fat: fat),
          ],
          if (onEdit != null) ...<Widget>[
            Divider(height: 1, thickness: 1, color: t.line),
            SettingsRow(
              key: const ValueKey('profile-edit-goals'),
              leading: const IconTile(icon: Icons.tune_rounded),
              title: l10n.profileGoalsEditCta,
              onTap: onEdit,
            ),
          ],
        ],
      ),
    );
  }
}

/// Makro-Verteilung als ein Balken statt dreier Ringe: die Anteile stehen so
/// im direkten Groessenvergleich, und die Legende nennt die absoluten Gramm.
class _MacroSplitBlock extends StatelessWidget {
  const _MacroSplitBlock({
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final int protein, carbs, fat;

  /// `Expanded` mit flex 0 laesst sein Kind unbeschraenkt breit werden und
  /// wirft in einer Row — ein Makroziel von 0 g ist im Einstellungs-Sheet
  /// erlaubt, also darf der Balken das aushalten.
  static int _flex(int value) => value < 1 ? 1 : value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const IconTile(icon: Icons.bar_chart_rounded),
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
          const SizedBox(height: 12),
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
                  children: <Widget>[
                    Expanded(
                      flex: _flex(protein),
                      child: ColoredBox(color: t.protein),
                    ),
                    Expanded(
                      flex: _flex(carbs),
                      child: ColoredBox(color: t.carbs),
                    ),
                    Expanded(
                      flex: _flex(fat),
                      child: ColoredBox(color: t.fat),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 9),
          // Wrap statt Row: drei Legenden-Eintraege passen bei textScaler 2.0
          // nicht mehr nebeneinander.
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
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        // Flexible + Ellipsis: der Wrap regelt nur den Umbruch ZWISCHEN den
        // Legenden-Eintraegen, nicht die Breite eines einzelnen. „240 g
        // Kohlenhydrate" sprengt bei doppelter Systemschrift sonst die Zeile.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.ui(11, weight: FontWeight.w600, color: t.ink2),
          ),
        ),
      ],
    );
  }
}
