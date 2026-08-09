import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_texts.dart';

/// Die Forest-Flaeche oben auf „Heute": Budget, verbleibende kcal, Tick-
/// Anzeige und drei Kennzahlen.
///
/// Der Rechenkern ist woertlich der von [CaloriesOverviewCard]
/// (calories_overview_card.dart:34-39) — dieselben Klemmen, dieselbe
/// Zielanpassung: `goal + burned` fliesst in `remaining` und `progress`, das
/// ANGEZEIGTE Ziel bleibt das rohe. Zwei Flaechen, die dieselbe Zahl
/// verschieden ausrechnen, waeren fuer den Nutzer ein Fehler, egal welche
/// Rechnung „richtiger" ist — deshalb rechnet die Food-Zusammenfassung
/// (`DailySummaryCard`) zeichengleich und wird von
/// `test/kcal_goal_consistency_test.dart` daran festgehalten.
class TodayCalorieHero extends StatelessWidget {
  const TodayCalorieHero({
    super.key,
    required this.consumedKcal,
    required this.burnedKcal,
    required this.kcalGoal,
    required this.streak,
  });

  final int consumedKcal;

  /// An einem Nicht-Heute-Tag reicht die Schale 0 durch — die Kachel zeigt
  /// dann „—" statt einer erfundenen Null.
  final int burnedKcal;

  final int kcalGoal;

  /// Bereits ueber `LifetimeStats.effectiveStreakOn` aufgeloest.
  final int streak;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    final goal = kcalGoal <= 0 ? 1 : kcalGoal;
    final eaten = consumedKcal.clamp(0, 99999).toInt();
    final burned = burnedKcal.clamp(0, 99999).toInt();
    final adjustedGoal = goal + burned;
    final remaining = (adjustedGoal - eaten).clamp(-99999, 99999).toInt();
    final progress = (eaten / adjustedGoal).clamp(0.0, 1.0);
    final ueberzogen = remaining < 0;

    return Container(
      key: const ValueKey('today-kcal-hero'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.forest,
        borderRadius: BorderRadius.circular(rHero),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DotGridBackground(color: t.lime.withValues(alpha: 0.16)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'KALORIENBUDGET',
                        style: AppType.eyebrow(t.lime),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Hier steht das ROHE Tagesziel — dieselbe Zahl wie in der
                    // ZIEL-Kachel der Food-Zusammenfassung
                    // (daily_summary_card.dart). „Ziel" ist der Wert, den der
                    // Nutzer in den Einstellungen gesetzt hat; das verbrannte
                    // Guthaben gehoert in die VERBLEIBENDE Zahl, nicht ins
                    // Ziel. Beide Flaechen sind einen Tab-Tap voneinander
                    // entfernt: stuende hier `goal + burned`, saehe der Nutzer
                    // fuer denselben Tag zwei „Ziele" (2.300 hier, 2.000 dort).
                    // Nachvollziehbar bleibt die Rechnung ueber die
                    // VERBRANNT-Kachel weiter unten.
                    // Festgenagelt von test/kcal_goal_consistency_test.dart.
                    Flexible(
                      child: Text(
                        'Ziel ${kcalThousands(goal)} kcal',
                        key: const ValueKey('today-kcal-goal'),
                        textAlign: TextAlign.right,
                        style: AppType.ui(
                          11,
                          weight: FontWeight.w500,
                          color: t.onForest.withValues(alpha: 0.65),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // FittedBox: 66 px Grundschrift werden bei textScaler 2.0 zu
                // 132 px und waeren breiter als die Karte.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: <Widget>[
                      Text(
                        // Der Betrag, nicht der negative Wert: das Vorzeichen
                        // traegt die Einheit daneben.
                        kcalThousands(remaining.abs()),
                        key: const ValueKey('today-kcal-remaining'),
                        style: AppType.display(
                          66,
                          color: t.onForest,
                          height: 0.9,
                          letterSpacing: -3,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          ueberzogen ? 'kcal drüber' : 'kcal übrig',
                          style: AppType.ui(
                            13,
                            // Die grosse Zahl bleibt in beiden Faellen
                            // onForest: `danger` ist auf der Forest-Flaeche im
                            // Hellmodus kaum lesbar, das waere ein Kontrast-
                            // bruch statt eines Signals. Das Signal traegt die
                            // Einheit — in Lime und schwerer gesetzt.
                            weight:
                                ueberzogen ? FontWeight.w700 : FontWeight.w600,
                            color: ueberzogen
                                ? t.lime
                                : t.onForest.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Semantics(
                  label: 'Kalorienfortschritt',
                  value: '${(progress * 100).round()} Prozent des '
                      'Tagesziels gegessen',
                  child: TickGauge(progress: progress),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _Kachel(
                      keyValue: 'today-stat-eaten',
                      value: kcalThousands(eaten),
                      label: 'GEGESSEN',
                    ),
                    const _Trenner(),
                    const SizedBox(width: 16),
                    _Kachel(
                      keyValue: 'today-stat-burned',
                      // Wortgleich zur alten Karte
                      // (calories_overview_card.dart:198-200).
                      value: burned == 0 ? '—' : kcalThousands(burned),
                      label: 'VERBRANNT',
                    ),
                    const _Trenner(),
                    const SizedBox(width: 16),
                    _Kachel(
                      keyValue: 'today-stat-streak',
                      value: '$streak',
                      label: 'TAGE-STREAK',
                      valueColor: t.lime,
                    ),
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

class _Kachel extends StatelessWidget {
  const _Kachel({
    required this.keyValue,
    required this.value,
    required this.label,
    this.valueColor,
  });

  final String keyValue;
  final String value;
  final String label;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // FittedBox um BEIDE Zeilen: die drei Kacheln teilen sich die Kartenbreite
    // zu je einem Drittel (~92 px auf einem Telefon). Bei textScaler 2.0 sind
    // „12.345" und „VERBRANNT" breiter als das — ohne Schrumpfen bricht der
    // Text dort mitten im Wort um und die Zahl stand als Buchstabensalat
    // untereinander (gemessen: 174 px hoch statt 24). Ein Ueberlauf FLIEGT
    // dabei nicht, deshalb faellt das keinem Row-Overflow-Test auf.
    return Expanded(
      child: Column(
        key: ValueKey<String>(keyValue),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppType.display(
                20,
                weight: FontWeight.w700,
                color: valueColor ?? t.onForest,
              ),
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: AppType.ui(
                10.5,
                weight: FontWeight.w500,
                color: t.onForest.withValues(alpha: 0.6),
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Trenner extends StatelessWidget {
  const _Trenner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 34,
      color: context.t.onForest.withValues(alpha: 0.18),
    );
  }
}
