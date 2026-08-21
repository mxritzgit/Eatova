import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'settings_controls.dart';

// ---------------------------------------------------------------------------
// Die Plan-Karte der Einstellungen: was aus Koerper, Aktivitaet und Ziel
// gerade herauskommt.
//
// Aufteilung nach dem Kontrast, nicht nach Geschmack: der Hero traegt
// Erhaltung, Tempo und die grosse kcal-Zahl auf [AppTokens.forest]; die drei
// Makro-Kacheln stehen DARUNTER auf dem Seitengrund. Auf Forest haette
// [AppTokens.protein] im Hellmodus (#3C5CCC auf #123322) ein Kontrast-
// verhaeltnis unter 2:1 — die Naehrwert-Kodierung waere unlesbar.
// ---------------------------------------------------------------------------

/// Wochenrate in kg, die ein konkretes [tagesziel] gegenueber der [erhaltung]
/// hergibt — negativ heisst abnehmen.
///
/// **Die einzige Stelle, an der aus kcal ein Tempo wird.** Plan-Karte und
/// Gewichtsziel-Zeile muessen zwingend dieselbe Zahl zeigen, sonst hat B2 nur
/// den Ort gewechselt. Fuer das gerechnete Ziel ist das Ergebnis identisch mit
/// [KcalTargets.effectiveWeeklyRateKg]; im Manuell-Modus zaehlt die Zahl, die
/// der Nutzer selbst gesetzt hat.
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

  /// Ob die Karte das gerechnete Ziel zeigt. Sobald der Nutzer eine eigene
  /// Zahl setzt, beschreibt [targets] nicht mehr das, was gross auf der Karte
  /// steht — Tempo und Hinweis muessen dann von der gezeigten Zahl kommen,
  /// sonst entsteht derselbe Widerspruch nur andersherum.
  bool get _zeigtRechnung => kcal == targets.kcal;

  /// Tempo aus der Zahl, die tatsaechlich auf der Karte steht.
  ///
  /// B2: Hier stand frueher `goal.paceLabel` — das *gewaehlte* Tempo. Fuer das
  /// damalige Standardprofil (PAL 1,2) ergab das „Erhaltung 1997 ·
  /// −1 kg/Woche" direkt ueber „1200"; 1997 − 1200 = 797 kcal, also
  /// −0,72 kg/Woche. Seit dem Kalorien-Review 2026-08-21: „Erhaltung 2330 ·
  /// −0,75 kg/Woche" ueber „1500" (1-%-Deckel statt Klemme).
  String _paceLabel(AppLocalizations l10n) => paceLabelForWeeklyRateKg(
        wochenrateKg(tagesziel: kcal, erhaltung: targets.maintenanceKcal),
        l10n,
      );

  /// Der fertige Erklaersatz der Sicherheitsklemme — nur wenn die Karte auch
  /// das gerechnete Ziel zeigt.
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
        Row(
          children: <Widget>[
            _MacroTile(
              label: l10n.todayMacroProtein,
              value: '$protein ${l10n.commonUnitG}',
              color: t.protein,
            ),
            const SizedBox(width: 10),
            _MacroTile(
              label: l10n.foodMacroTileCarbsLabel,
              value: '$carbs ${l10n.commonUnitG}',
              color: t.carbs,
            ),
            const SizedBox(width: 10),
            _MacroTile(
              label: l10n.todayMacroFat,
              value: '$fat ${l10n.commonUnitG}',
              color: t.fat,
            ),
          ],
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
    return Expanded(
      child: AppCard(
        radius: rControl,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        child: Column(
          children: <Widget>[
            // Die Kachel ist ein Drittel der Zeile breit, die Zahl waechst mit
            // der Systemschrift — ohne Schrumpfen liefe sie bei 2.0 heraus.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: AppType.display(16, weight: FontWeight.w700, color: color),
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: AppType.ui(11, weight: FontWeight.w600, color: t.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
