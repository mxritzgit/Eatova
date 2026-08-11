part of 'profile_widgets.dart';

/// Der Identitaets-Anker des Profils: Forest-Flaeche mit Initialen-Kachel,
/// Name und zwei Tags aus ECHTEN Profilfeldern.
///
/// Die Design-Vorlage zeigt hier zusaetzlich E-Mail, ein „PREMIUM"-Tag und
/// „MEMBER SINCE 2024". Nichts davon existiert bei uns: der Screen bekommt nur
/// einen Namen, und `LifetimeStats.sessionStart` ist der Start DIESER Sitzung,
/// kein Beitrittsdatum. Erfundene Daten auf der Identitaetskarte waeren die
/// teuerste Art von Designschuld — also stehen dort die beiden Felder, die es
/// wirklich gibt.
class IdentityCard extends StatelessWidget {
  const IdentityCard({super.key, required this.name, required this.profile});

  final String name;
  final UserProfile profile;

  /// Initialen aus dem Anzeigenamen. Bewusst OHNE Platzhalter-Buchstaben:
  /// ein leerer Name ergibt eine leere Zeichenkette, die Kachel zeigt dann ein
  /// Personen-Glyph statt zweier erfundener Buchstaben.
  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final initials = _initials;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.forest,
        borderRadius: BorderRadius.circular(rHero),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            right: -40,
            bottom: -50,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: t.lime.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: t.lime,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      alignment: Alignment.center,
                      // FittedBox: die Kachel hat eine feste Kantenlaenge, die
                      // Initialen wachsen aber mit der Systemschrift.
                      child: initials.isEmpty
                          ? Icon(Icons.person_outline,
                              size: 28, color: t.onLime)
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                initials,
                                style: AppType.display(24, color: t.onLime),
                              ),
                            ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.display(
                          23,
                          color: t.onForest,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Wrap statt Row: bei textScaler 2.0 passen zwei Tags nicht
                // mehr nebeneinander, sie sollen umbrechen statt zu sprengen.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    _IdentityTag(
                      label: profile.weightGoal.label(l10n),
                      solid: true,
                    ),
                    _IdentityTag(label: profile.activityLevel.label(l10n)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentityTag extends StatelessWidget {
  const _IdentityTag({required this.label, this.solid = false});

  final String label;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: solid ? t.lime : t.onForest.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: AppType.ui(
          10.5,
          weight: solid ? FontWeight.w700 : FontWeight.w600,
          color: solid ? t.onLime : t.onForest,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Ziel-Uebersicht: aktuelles Gewicht → Wunschgewicht, Tempo (kg/Woche),
/// Tagesziel und grobe Zeit-Prognose.
///
/// Klassenname und Konstruktor-Signatur sind API: `profile_hero_pace_test`
/// baut die Karte direkt und nagelt fuenf Saetze zeichengenau fest. Der
/// Design-Refactor tauscht hier nur Flaechen, Farben und Radien.
class GoalPlanCard extends StatelessWidget {
  const GoalPlanCard({super.key, required this.profile, this.onEdit});

  final UserProfile profile;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final goal = profile.weightGoal;
    final isMaintain = goal == WeightGoal.maintain;
    final gap = (profile.weightKg - profile.targetWeightKg).abs();
    // B2: Hier liegt ein konkretes Profil vor, also gehoert die EFFEKTIVE
    // Rechnung auf die Karte und nicht das gewaehlte Wunsch-Tempo. Fuer das
    // Standardprofil (78/178/30, sitzend, Ziel 68, −1 kg/Woche) kappt die
    // 1200er-Sicherheitsgrenze das Defizit von 1100 auf 797 kcal: real sind
    // das −0,72 kg/Woche und 14 Wochen, nicht −1 und 10.
    //
    // targets einmal berechnen und an weeksToGoal durchreichen — sonst rechnet
    // calculate() zweimal, und die Karte koennte im Extremfall zwei
    // Ergebnisse mischen.
    final targets = const KcalCalculator().calculate(profile);
    final weeks = const KcalCalculator().weeksToGoal(profile, targets: targets);
    // Fertig formulierter Satz aus KcalTargets, sonst null.
    final paceWarning = isMaintain ? null : targets.paceWarning(l10n);
    // Ein Ziel mit Richtung traegt den Marken-Akzent, „halten" bleibt ruhig.
    final accent = isMaintain ? t.ink2 : t.accent;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(
                icon: isMaintain
                    ? Icons.shield_moon_outlined
                    : (goal.isGain
                        ? Icons.trending_up_rounded
                        : Icons.trending_down_rounded),
                color: accent,
                size: 38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.profileGoalPlanTitle,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      goal.label(l10n),
                      style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
                    ),
                  ],
                ),
              ),
              if (onEdit != null)
                // A11y: volle 48er Tap-Flaeche (kein compact), Glyph bleibt 18.
                IconButton(
                  key: const ValueKey('profile-goalplan-edit'),
                  onPressed: onEdit,
                  tooltip: l10n.profileGoalPlanEditTooltip,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  color: accent,
                ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(
                child: _WeightPole(
                  label: l10n.profileWeightPoleCurrent,
                  value: '${profile.weightKg}',
                  color: t.ink,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: accent,
                  size: 22,
                ),
              ),
              Expanded(
                child: _WeightPole(
                  label: isMaintain
                      ? l10n.profileWeightPoleHold
                      : l10n.profileWeightPoleTarget,
                  value: '${profile.targetWeightKg}',
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                // Den fertigen paceWarning-Satz haengt die Karte NICHT als
                // eigenen Textblock an: W3-04 zeigt ihn im Einstellungs-Sheet,
                // und derselbe Dreizeiler ein zweites Mal wuerde die
                // Zwei-Chip-Zeile hier erschlagen. Als Tooltip/Semantics am
                // Tempo-Chip erklaert er die Zahl auf Abruf, ohne sie zu
                // wiederholen — und Screenreader bekommen ihn ohne Umweg.
                child: _MaybeTooltip(
                  message: paceWarning,
                  child: _PlanChip(
                    icon: Icons.speed_rounded,
                    label: l10n.profilePlanChipPace,
                    value: isMaintain
                        ? l10n.profileStable
                        : targets.effectivePaceLabel(l10n),
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _PlanChip(
                  icon: Icons.local_fire_department_rounded,
                  label: l10n.profilePlanChipDailyGoal,
                  value: '${profile.dailyKcalGoal} kcal',
                  color: t.ink,
                ),
              ),
            ],
          ),
          if (!isMaintain && gap > 0) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: t.tile,
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.flag_rounded, color: accent, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      weeks != null
                          ? l10n.profileGoalProgressWeeks(gap, weeks)
                          : l10n.profileGoalProgressNoWeeks(gap),
                      style: AppType.ui(
                        13,
                        weight: FontWeight.w600,
                        color: t.ink,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Haengt [message] als Tooltip an [child] — oder reicht [child] unveraendert
/// durch, wenn nichts zu erklaeren ist. Vermeidet ein `Tooltip` mit leerer
/// Nachricht (das faenge Long-Press ab und kuendigte Screenreadern eine
/// Beschreibung an, die es nicht gibt).
class _MaybeTooltip extends StatelessWidget {
  const _MaybeTooltip({required this.message, required this.child});

  final String? message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null || text.isEmpty) return child;
    return Tooltip(message: text, child: child);
  }
}

class _WeightPole extends StatelessWidget {
  const _WeightPole({
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
    return Column(
      children: <Widget>[
        Text(label.toUpperCase(), style: AppType.eyebrow(t.ink2, size: 10.5)),
        const SizedBox(height: 4),
        // FittedBox: die grosse Zahl waechst mit der Systemschrift, die halbe
        // Kartenbreite tut es nicht.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                value,
                style: AppType.display(30, color: color, height: 1),
              ),
              const SizedBox(width: 3),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  'kg',
                  style:
                      AppType.ui(12, weight: FontWeight.w700, color: t.ink2),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style:
                      AppType.ui(10.5, weight: FontWeight.w600, color: t.ink2),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(13, weight: FontWeight.w700, color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
