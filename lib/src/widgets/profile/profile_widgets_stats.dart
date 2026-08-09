part of 'profile_widgets.dart';

/// Eine Kennzahl-Kachel: Versalien-Label, grosse Zahl, Einheit.
///
/// Heisst bewusst nicht einfach `StatTile`: die Bibliothek importiert die
/// gesamte Design-Barrel, und ein so generischer Name waere ein Kandidat fuer
/// eine spaetere Namenskollision mit einem gemeinsamen Baustein.
class ProfileStatTile extends StatelessWidget {
  const ProfileStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      radius: 20,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(label, style: AppType.eyebrow(t.ink2, size: 9.5)),
          const SizedBox(height: 6),
          // Zahl und Einheit stehen in einer halben Kartenbreite. Ohne
          // Flexible + FittedBox platzt die Zwei-Spalten-Reihe bei
          // textScaler 2.0 — genau die Bruchstelle aus §5 des Vertrags.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: AppType.display(28, color: t.ink),
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    unit,
                    style:
                        AppType.ui(11, weight: FontWeight.w500, color: t.ink2),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Zwei Kacheln nebeneinander, gleich hoch.
///
/// `IntrinsicHeight` statt einer festen Hoehe: die Kacheln duerfen mit der
/// Systemschrift wachsen, sollen dabei aber nicht unterschiedlich hoch werden.
class ProfileStatRow extends StatelessWidget {
  const ProfileStatRow({super.key, required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: left),
          const SizedBox(width: 12),
          Expanded(child: right),
        ],
      ),
    );
  }
}

/// Formatiert die Dauer der laufenden Sitzung fuer die Abschnittszeile.
String formatSessionDuration(Duration d) {
  if (d.inMinutes < 1) return 'gerade gestartet';
  if (d.inMinutes < 60) return '${d.inMinutes} Min';
  final h = d.inHours;
  final rest = d.inMinutes % 60;
  if (rest == 0) return '${h}h';
  return '${h}h $rest Min';
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
    final t = context.t;
    final achievements = <_Achievement>[
      _Achievement(
        icon: Icons.local_fire_department_rounded,
        title: 'Erster Streak',
        subtitle: trackingStreak >= 1 ? 'Erreicht' : '1 Tag Essen loggen',
        unlocked: trackingStreak >= 1,
      ),
      _Achievement(
        icon: Icons.calendar_view_week_rounded,
        title: '3er Streak',
        subtitle: trackingStreak >= 3
            ? 'Drei Tage am Stück'
            : '${(3 - trackingStreak).clamp(1, 3)} bis zum Badge',
        unlocked: trackingStreak >= 3,
      ),
      _Achievement(
        icon: Icons.restaurant_rounded,
        title: 'Foodie',
        subtitle: stats.mealsLogged >= 5
            ? '${stats.mealsLogged} Mahlzeiten erfasst'
            : 'Logge 5 Mahlzeiten',
        unlocked: stats.mealsLogged >= 5,
      ),
      _Achievement(
        icon: Icons.workspace_premium_rounded,
        title: '7er Streak',
        subtitle: trackingStreak >= 7
            ? 'Sieben Tage am Stück'
            : '${(7 - trackingStreak).clamp(1, 7)} bis zum Badge',
        unlocked: trackingStreak >= 7,
      ),
      _Achievement(
        icon: Icons.monitor_weight_rounded,
        title: 'Tracker',
        subtitle:
            weightLogs >= 2 ? 'Gewichtsverlauf aktiv' : 'Gewicht 2× loggen',
        unlocked: weightLogs >= 2,
      ),
      _Achievement(
        icon: Icons.star_rounded,
        title: 'Favoriten',
        subtitle: favoritesCount >= 3
            ? '$favoritesCount Lieblings-Mahlzeiten'
            : '3 Mahlzeiten merken',
        unlocked: favoritesCount >= 3,
      ),
    ];
    final freigeschaltet = achievements.where((a) => a.unlocked).length;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Achievements',
                  style: AppType.display(
                    17,
                    weight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
              ),
              Text(
                '$freigeschaltet/${achievements.length}',
                style:
                    AppType.ui(11.5, weight: FontWeight.w600, color: t.ink2),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Bewusst KEIN GridView mit childAspectRatio: ein festes
          // Seitenverhaeltnis kann bei textScaler 2.0 nicht mitwachsen und
          // overflowt garantiert. Paarweise Rows unter IntrinsicHeight sind
          // optisch dasselbe Raster und wachsen mit dem Text.
          for (var i = 0; i < achievements.length; i += 2) ...<Widget>[
            if (i > 0) const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: _AchievementTile(data: achievements[i])),
                  const SizedBox(width: 10),
                  Expanded(
                    child: i + 1 < achievements.length
                        ? _AchievementTile(data: achievements[i + 1])
                        : const SizedBox.shrink(),
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

class _Achievement {
  const _Achievement({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.unlocked,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool unlocked;
}

class _AchievementTile extends StatelessWidget {
  const _AchievementTile({required this.data});

  final _Achievement data;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Freigeschaltet traegt den Marken-Akzent, gesperrt bleibt Sekundaertext:
    // sechs bunte Kacheln waren sechs konkurrierende Signale.
    final tint = data.unlocked ? t.accent : t.ink2;
    return AnimatedContainer(
      // A11y: Unlock-Uebergang unter "Bewegung reduzieren" auf 0.
      duration: motionDuration(context, const Duration(milliseconds: 220)),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: data.unlocked ? tint.withValues(alpha: 0.10) : t.tile,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(
          color: data.unlocked ? tint.withValues(alpha: 0.40) : t.line,
        ),
      ),
      child: Row(
        children: <Widget>[
          IconTile(icon: data.icon, color: tint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  data.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w700,
                    color: data.unlocked ? t.ink : t.ink2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  data.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(10.5, color: t.ink2, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
