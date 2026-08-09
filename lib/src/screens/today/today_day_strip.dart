import 'package:flutter/material.dart';

import '../../services/day_math.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_texts.dart';

/// Der schlanke Datums-Streifen des Tabs „Heute": ein Schritt zurueck, der
/// Name des gewaehlten Tages, ein Schritt vor.
///
/// Bewusst NICHT die 30-Tage-Leiste des Food-Tabs (`_FoodDateStrip`): „Heute"
/// beantwortet „wie stehe ich gerade da?" — das ist eine Frage an einen
/// einzelnen Tag, meist den heutigen. Wer wirklich blaettert, tut das im
/// Tagebuch, wo Kalender und Archiv-Chip stehen. Die Labels sind trotzdem
/// dieselben ([todayDateLabel]), damit beide Tabs denselben Tag gleich nennen.
///
/// [today] kommt von aussen, statt hier `clock.now()` zu lesen: so gibt es im
/// Screen genau eine Stelle, die die Uhr befragt, und der Streifen ist ohne
/// Zonen-Trickserei testbar.
class TodayDayStrip extends StatelessWidget {
  const TodayDayStrip({
    super.key,
    required this.selectedDate,
    required this.today,
    this.onSelected,
  });

  final DateTime selectedDate;
  final DateTime today;
  final ValueChanged<DateTime>? onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    // Vorwaerts endet auf dem heutigen Tag: fuer morgen gibt es keine Daten,
    // und ein leerer Zukunftstag saehe aus wie ein Ladefehler. Rechnung ueber
    // day_math, nie ueber Duration (B5).
    final vorwaertsGesperrt = daysBetween(today, selectedDate) <= 0;

    void springe(int tage) =>
        onSelected?.call(addDays(startOfDay(selectedDate), tage));

    return Row(
      key: const ValueKey('today-date-strip'),
      children: <Widget>[
        SquareIconButton(
          key: const ValueKey('today-date-prev'),
          icon: Icons.chevron_left_rounded,
          // Umlaut, kein „ue": ein Semantics-Label ist gesprochener Text.
          semanticLabel: 'Tag zurück',
          onTap: () => springe(-1),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            // Abweichung von der Vorlage (feste height: 34): bei
            // textScaler 2.0 waere die Beschriftung hoeher als die Pille.
            constraints: const BoxConstraints(minHeight: 34),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: t.forest,
              // rChip statt der 11 aus der Vorlage: die Pille steht direkt
              // neben den beiden SquareIconButtons. Bliebe die Zahl hart, liefe
              // sie bei der naechsten Verschiebung der Radius-Skala von deren
              // Ecken weg.
              borderRadius: BorderRadius.circular(rChip),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: t.lime,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    todayDateLabel(today, selectedDate),
                    key: const ValueKey('today-date-selected-label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: t.onForest,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Opacity(
          opacity: vorwaertsGesperrt ? 0.45 : 1,
          child: SquareIconButton(
            key: const ValueKey('today-date-next'),
            icon: Icons.chevron_right_rounded,
            semanticLabel: 'Tag vor',
            onTap: vorwaertsGesperrt ? null : () => springe(1),
          ),
        ),
      ],
    );
  }
}
