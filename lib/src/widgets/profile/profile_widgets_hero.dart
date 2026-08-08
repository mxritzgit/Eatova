part of 'profile_widgets.dart';

/// Identitaets-Header des Profils: Avatar mit weichem Lime-Schein, Name
/// zentriert darunter, dann die Stat-Leiste (Streak · Mahlzeiten · Gewicht)
/// als drei gleichberechtigte Soft-Kacheln. Bewusst KEINE Karte — der Kopf
/// steht frei auf dem Hintergrund, wie es moderne Profil-Screens tun; die
/// Karten beginnen erst mit den Sektionen darunter.
class ProfileHero extends StatelessWidget {
  const ProfileHero({
    super.key,
    required this.name,
    required this.streak,
    required this.mealsLogged,
    required this.weightKg,
  });

  final String name;
  final int streak;
  final int mealsLogged;
  final double weightKg;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'SF';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  String get _weightLabel {
    final gerundet = (weightKg * 10).round() / 10;
    final text = gerundet == gerundet.roundToDouble()
        ? '${gerundet.round()}'
        : gerundet.toStringAsFixed(1).replaceAll('.', ',');
    return '$text kg';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        Center(
          child: Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  lime.withValues(alpha: 0.32),
                  lime.withValues(alpha: 0.08),
                ],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: lime.withValues(alpha: 0.16),
                  blurRadius: 30,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              _initials,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: lime,
                letterSpacing: -0.4,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _HeroStat(
                icon: Icons.local_fire_department_rounded,
                accent: lime,
                value: '$streak',
                label: 'Tage Streak',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _HeroStat(
                icon: Icons.restaurant_rounded,
                accent: cyan,
                value: '$mealsLogged',
                label: 'Mahlzeiten',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _HeroStat(
                icon: Icons.monitor_weight_rounded,
                accent: orange,
                value: _weightLabel,
                label: 'Gewicht',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Eine Kachel der Hero-Stat-Leiste: rahmenlose Soft-Flaeche, Akzent nur im
/// Icon, Zahl als Held (Soft-Kapsel-Vorgabe — keine Hairlines).
class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.icon,
    required this.accent,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final Color accent;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
      ),
      child: Column(
        children: [
          Icon(icon, size: 17, color: accent),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: textMuted,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

/// Moderne Ziel-Übersicht: aktuelles Gewicht → Wunschgewicht, Tempo (kg/Woche),
/// Tagesziel und grobe Zeit-Prognose. Headline-Karte des Profils.
class GoalPlanCard extends StatelessWidget {
  const GoalPlanCard({super.key, required this.profile, this.onEdit});

  final UserProfile profile;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
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
    final paceWarning = isMaintain ? null : targets.paceWarning;
    final accent = goal.isGain ? orange : (goal.isLoss ? lime : cyan);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.14), surface],
        ),
        borderRadius: BorderRadius.circular(rSheet),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Icon(
                  isMaintain
                      ? Icons.shield_moon_outlined
                      : (goal.isGain
                          ? Icons.trending_up_rounded
                          : Icons.trending_down_rounded),
                  color: accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Mein Ziel',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      goal.label,
                      style: const TextStyle(
                        color: textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (onEdit != null)
                // A11y: volle 48er Tap-Flaeche (kein compact), Glyph bleibt 18.
                IconButton(
                  key: const ValueKey('profile-goalplan-edit'),
                  onPressed: onEdit,
                  tooltip: 'Ziel anpassen',
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  color: accent,
                ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _WeightPole(
                  label: 'Aktuell',
                  value: '${profile.weightKg}',
                  color: textPrimary,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: isMaintain ? textMuted : accent,
                  size: 22,
                ),
              ),
              Expanded(
                child: _WeightPole(
                  label: isMaintain ? 'Halten' : 'Wunsch',
                  value: '${profile.targetWeightKg}',
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
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
                    label: 'Tempo',
                    value:
                        isMaintain ? 'stabil' : targets.effectivePaceLabel,
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _PlanChip(
                  icon: Icons.local_fire_department_rounded,
                  label: 'Tagesziel',
                  value: '${profile.dailyKcalGoal} kcal',
                  color: orange,
                ),
              ),
            ],
          ),
          if (!isMaintain && gap > 0) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: surfaceSoft,
                borderRadius: BorderRadius.circular(rControl),
                border: Border.all(color: hairline),
              ),
              child: Row(
                children: [
                  Icon(Icons.flag_rounded, color: accent, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      weeks != null
                          ? 'Noch $gap kg · Ziel in ca. $weeks Wochen'
                          : 'Noch $gap kg bis zum Wunschgewicht',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                        fontFeatures: [FontFeature.tabularFigures()],
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
    return Column(
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: textMuted,
            fontSize: 10.5,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.2,
                color: color,
                height: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 3),
            const Padding(
              padding: EdgeInsets.only(bottom: 3),
              child: Text(
                'kg',
                style: TextStyle(
                  color: textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rControl),
        border: Border.all(color: hairline),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: color,
                    letterSpacing: -0.2,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
