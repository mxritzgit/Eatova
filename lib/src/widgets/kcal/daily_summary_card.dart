import 'package:flutter/material.dart';

import '../../models/macro_progress.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_format.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';

// Der Tausenderpunkt-Formatierer wohnt seit 2026-08-09 unter services/.
// Hier re-exportiert, weil meal_analysis_screen.dart ihn ueber diese Datei
// bezieht — der Import dort bleibt dadurch unveraendert gueltig.
export '../../services/kcal_format.dart' show formatThousands;

/// Die kompakte Tages-Zusammenfassung ueber dem Tagebuch: verbleibende kcal,
/// Fortschritt, ZIEL / GEGESSEN / VERBRANNT plus drei Makro-Balken.
///
/// Erbin der abgeloesten Glas-Kalorienkarte. Der Kalorien-Hero (Forest-
/// Flaeche, Begruessung, Streak) zieht in den Heute-Tab; hier bleibt die
/// Karte, an der die Tests haengen — mit denselben Keys, denselben
/// Zahlenformaten und derselben „—"-Regel fuer einen Tag ohne Schrittdaten.
///
/// Die VERBLEIBENDE Zahl bleibt aber hier: sie ist die Zahl, die man beim
/// Loggen braucht („passt das noch rein?"), und der Food-Tab ist der Ort des
/// Loggens. Sie erscheint als fuehrende Groesse der Karte — bewusst OHNE
/// eigenen Fortschrittsbalken: mit einem wuchs die Karte auf 237 px und schob
/// das Tagebuch darunter auf einem 852-px-Schirm unter die Falz. Den vollen
/// Kalorien-Hero mit Balken traegt der Tab „Heute" einen Tipp entfernt.
///
/// **Zwei Zahlen, eine Wahrheit:** `ZIEL` zeigt das ROHE `kcalGoal` — genau
/// den Wert, den der Nutzer in den Einstellungen gesetzt hat. Das verbrannte
/// Guthaben fliesst ausschliesslich in `remaining` und `progress`, nie in die
/// angezeigte Zielzahl. Der Heute-Hero (`today_hero.dart`) rechnet und
/// beschriftet identisch; `test/kcal_goal_consistency_test.dart` haelt beide
/// Flaechen zusammen.
class DailySummaryCard extends StatelessWidget {
  const DailySummaryCard({
    super.key,
    required this.dailyConsumedKcal,
    required this.kcalGoal,
    required this.macroProgress,
    required this.profile,
    this.burnedKcal = 0,
  });

  final int dailyConsumedKcal;
  final int kcalGoal;
  final int burnedKcal;
  final MacroProgress macroProgress;
  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Rechenkern zeichengleich zu today_hero.dart:38-44 (und damit zur
    // abgeloesten calories_overview_card.dart:34-39). Wer hier etwas aendert,
    // aendert es dort mit — sonst nennen die beiden Tabs fuer denselben Tag
    // verschiedene Zahlen.
    final goal = kcalGoal <= 0 ? 1 : kcalGoal;
    final eaten = dailyConsumedKcal.clamp(0, 99999).toInt();
    final burned = burnedKcal.clamp(0, 99999).toInt();
    // An einem Nicht-Heute-Tag ist `burned` hart 0 — die VERBRANNT-Kachel
    // zeigt dort „—", die Restzahl rechnet aber trotzdem korrekt gegen das
    // reine Tagesziel.
    final adjustedGoal = goal + burned;
    final remaining = (adjustedGoal - eaten).clamp(-99999, 99999).toInt();
    final progress = (eaten / adjustedGoal).clamp(0.0, 1.0).toDouble();
    final ueberzogen = remaining < 0;

    return AppCard(
      key: const ValueKey('analyse-daily-kcal-card'),
      radius: rCard,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Nachgemessen (2026-08-10): Mit eigener Abschnitts-Zeile, einer
          // 38-px-Zahl UND einem eigenen TickGauge wuchs diese Karte auf
          // 237 px — der Verlauf begann dadurch auf einem 852-px-Schirm erst
          // bei y=655, also unter der Falz. Das ist auf dem Tab, dessen
          // Aufgabe der Verlauf IST, der falsche Kompromiss.
          //
          // Deshalb verdichtet: Die Abschnitts-Zeile wandert neben die Zahl,
          // die Zahl schrumpft von 38 auf 30, und der Balken darunter ist nur
          // noch ein 6-px-Strich statt eines 20-px-Gauges. Den vollen
          // Kalorien-Hero traegt der Tab „Heute" einen Tipp entfernt.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
                // Die fuehrende Groesse der Karte. Der Wert steht OHNE „kcal"
                // im selben Text — die Einheit sitzt als eigenes Label daneben
                // und traegt das Vorzeichen. Das ist nicht nur Typografie: die
                // Flow-Tests suchen in dieser Karte nach genau einem
                // „<n> kcal", und eine zweite Zahl in diesem Format machte
                // jede dieser Zaehlungen mehrdeutig.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      // Der Betrag, nicht der negative Wert — wie im
                      // Heute-Hero traegt das Label daneben das Vorzeichen.
                      formatThousands(remaining.abs()),
                      key: const ValueKey('analyse-daily-kcal-remaining'),
                      style: AppType.display(
                        30,
                        weight: FontWeight.w700,
                        height: 1.0,
                        letterSpacing: -1.1,
                        // `accent` statt `lime`: auf einer Karte ist Lime die
                        // Strichfarbe, nicht die Flaeche (Vertrag §3).
                        color: ueberzogen ? t.danger : t.accent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      // Wortgleich zum Heute-Hero (today_hero.dart:118).
                      ueberzogen ? 'kcal drüber' : 'kcal übrig',
                      style: AppType.ui(
                        12,
                        weight: ueberzogen ? FontWeight.w700 : FontWeight.w500,
                        color: ueberzogen ? t.danger : t.ink2,
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              Text('TAGESBILANZ', style: AppType.eyebrow(t.ink2, size: 9.5)),
            ],
          ),
          const SizedBox(height: 10),
          // A11y: der Fortschritt ist sonst nur gemalt. Das war in der alten
          // Karte (calories_overview_card.dart:140) die EINZIGE Stelle, an der
          // ein Screenreader den Tagesfortschritt erfuhr — Label und Wert
          // deshalb wortgleich uebernommen.
          //
          // Die Ansage haengt bewusst am Balken und nicht an der Zahl: der
          // Balken ist ein CustomPaint und damit semantisch leer, sein Knoten
          // steht also allein. An einer Textzeile verschluckt der Text-Knoten
          // daneben die Ansage — genau daran ist ein Zwischenstand dieser
          // Karte gescheitert.
          Semantics(
            label: 'Kalorienfortschritt',
            value: '${(progress * 100).round()} Prozent des Tagesziels '
                'gegessen',
            child: TickGauge(
              progress: progress,
              // 6 statt 20: hier zaehlt der Strich als Randnotiz zur Zahl,
              // nicht als eigene Grafik. Der grosse Balken steht auf „Heute".
              height: 6,
              // Die Standardfarben des Gauge sind fuer die Forest-Flaeche
              // gerechnet (Lime auf abgedunkeltem onForest). Auf `surf` waere
              // die Spur unsichtbar, deshalb Karten-Tokens.
              fillColor: t.accent,
              trackColor: t.tile,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _Stat(
                  label: 'ZIEL',
                  // ROH, ohne `burned` — s. Klassenkommentar.
                  value: '${formatThousands(goal)} kcal',
                  valueKey: const ValueKey('analyse-daily-kcal-goal'),
                ),
              ),
              _StatDivider(color: t.line),
              Expanded(
                child: _Stat(
                  label: 'GEGESSEN',
                  value: '${formatThousands(eaten)} kcal',
                  valueKey: const ValueKey('analyse-daily-kcal-total'),
                ),
              ),
              _StatDivider(color: t.line),
              Expanded(
                child: _Stat(
                  label: 'VERBRANNT',
                  // Ein Nicht-Heute-Tag reicht hart 0 durch: „0 kcal" waere
                  // eine Behauptung ueber den Tag, die niemand gemessen hat.
                  value: burned == 0 ? '—' : '${formatThousands(burned)} kcal',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: CompactMacroBar(
                  label: 'Proteine',
                  current: macroProgress.proteinG,
                  goal: profile.proteinGoalG.toDouble(),
                  color: t.protein,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CompactMacroBar(
                  label: 'Kohlenhydrate',
                  current: macroProgress.carbsG,
                  goal: profile.carbsGoalG.toDouble(),
                  color: t.carbs,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CompactMacroBar(
                  label: 'Fette',
                  current: macroProgress.fatG,
                  goal: profile.fatGoalG.toDouble(),
                  color: t.fat,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Schmaler Makro-Balken im Format `<aktuell>/<ziel>g` — OHNE Leerzeichen um
/// den Schrägstrich.
///
/// Bewusst NICHT [MacroBar] aus `widgets/design/meters.dart`: der rendert
/// `0 / 130g`, der Vertrag verlangt hier aber zeichengenau `0/130g`. Ein
/// Format-Schalter am gemeinsamen Baustein steht als Aenderungswunsch im
/// Bericht; bis dahin lebt der schmale Balken im Food-Paket.
class CompactMacroBar extends StatelessWidget {
  const CompactMacroBar({
    super.key,
    required this.label,
    required this.current,
    required this.goal,
    required this.color,
  });

  final String label;
  final double current;
  final double goal;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ratio = goal <= 0 ? 0.0 : (current / goal).clamp(0.0, 1.0).toDouble();
    final currentG = current.round();
    final goalG = goal.round();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.ui(11, weight: FontWeight.w600, color: t.ink2),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(rPill),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 5,
            backgroundColor: t.tile,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '$currentG/${goalG}g',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.display(11.5, weight: FontWeight.w700, color: t.ink),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.valueKey});

  final String label;

  /// Fertig formatierter Wert inklusive Einheit (z. B. `'590 kcal'`).
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow(t.ink2, size: 9),
          ),
          const SizedBox(height: 4),
          // FittedBox: die Zeile hat drei gleich breite Spalten und der Wert
          // waechst mit der Systemschrift — schrumpfen statt sprengen.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              key: valueKey,
              maxLines: 1,
              style: AppType.display(14, weight: FontWeight.w700, color: t.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// Haarlinie zwischen zwei Werten. Bewusst kuerzer als die Zeile hoch ist —
/// ein Trenner soll gliedern, nicht ein Gitter aufziehen.
class _StatDivider extends StatelessWidget {
  const _StatDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 24, color: color);
}
