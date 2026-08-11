import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../l10n/l10n.dart';
import '../services/day_math.dart';
import '../services/kcal_format.dart';
import '../services/trend_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/common/lively.dart';
import '../widgets/common/motion.dart';
import '../widgets/design/design.dart';

/// Trend-Ansicht (Langzeit-Perspektive): Kalorien-Balken pro Tag mit
/// Ziellinie + Zielkorridor, Zeitraum-Umschalter 7/30/90 Tage und
/// Kennzahlen (Durchschnitts-kcal, Ziel-Treffer-Quote, Durchschnitts-Makros).
///
/// Datenpfad ist der injizierte [TrendTotalsLoader] (Produktions-Pfad:
/// TrendService.loadDailyTotals) — bewusst UNABHAENGIG vom HomeStore und
/// seinem 35-Tage-Fenster. Das Kalorienziel kommt als Konstruktor-Parameter.
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({
    super.key,
    required this.kcalGoal,
    required this.loadTotals,
  });

  /// Tagesziel in kcal (aus dem Profil durchgereicht).
  final int kcalGoal;

  final TrendTotalsLoader loadTotals;

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  static const List<int> _ranges = [7, 30, 90];

  int _rangeDays = 30;
  bool _loading = true;
  Object? _error;
  List<TrendDayTotals> _totals = const [];

  @override
  void initState() {
    super.initState();
    // Kein setState noetig: _loading startet bereits true. _fetch selbst
    // setStated erst nach einem await — nie synchron waehrend des Mounts.
    _fetch();
  }

  /// Retry-Einstieg (Button): zurueck in den Lade-Zustand, dann neu laden.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _fetch();
  }

  Future<void> _fetch() async {
    try {
      // Future.sync: auch ein SYNCHRON werfender Loader (z.B. Supabase nicht
      // initialisiert) landet als Future-Fehler im catch — asynchron, also
      // nie als setState mitten im ersten Build.
      final totals = await Future.sync(widget.loadTotals);
      if (!mounted) return;
      setState(() {
        _totals = totals;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      // Der Service hat bereits geloggt — hier nur in den Retry-Zustand
      // uebersetzen, keine rohe Exception in die UI durchreichen.
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      body: SafeArea(
        child: LivelyEntrance(
          // Wie im Profil bewusst SingleChildScrollView + Column statt eines
          // ListView: alle Kennzahlen sollen im Elementbaum stehen, auch die,
          // die gerade unterhalb des Bildschirms liegen.
          child: SingleChildScrollView(
            key: const ValueKey('screen-trends'),
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: l10n.trendsTitle,
                  backKey: const ValueKey('trends-close'),
                ),
                const SizedBox(height: 14),
                _RangeSelector(
                  ranges: _ranges,
                  selected: _rangeDays,
                  onSelected: (days) => setState(() => _rangeDays = days),
                ),
                const SizedBox(height: 14),
                ..._buildContent(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildContent(BuildContext context) {
    final l10n = context.l10n;
    if (_loading) {
      return const [
        SizedBox(
          key: ValueKey('trends-loading'),
          height: 260,
          child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
        ),
      ];
    }
    if (_error != null) {
      return [_ErrorCard(onRetry: _load)];
    }
    if (_totals.length < 2) {
      return const [_EmptyCard()];
    }

    final today = DateTime.now();
    final window = denseTrendWindow(_totals, today: today, days: _rangeDays);
    // B6: Das CHART bekommt das volle Fenster inklusive des laufenden Tages —
    // die Kurve soll zeigen, wo man heute steht. Die KENNZAHLEN rechnen ohne
    // ihn, weil ein Teiltag sonst als vollstaendiger Tag in den Schnitt und
    // in die Trefferquote eingeht (siehe completedDaysOf). Die Kacheln
    // beschriften das unten mit einer Fussnote.
    final completed = completedDaysOf(window);
    final avgKcal = averageKcalOf(completed);
    final hits = goalHitsOf(completed, goalKcal: widget.kcalGoal);
    final macros = averageMacrosOf(completed);

    return [
      _ChartCard(
        window: window,
        rangeDays: _rangeDays,
        kcalGoal: widget.kcalGoal,
        avgKcal: avgKcal,
        // Zaehlt die gezeichneten Balken (inkl. heute), damit die A11y-Ansage
        // zum Chart passt und nicht zu den Kennzahlen-Kacheln.
        trackedDays: trackedDaysOf(window),
        // B5: Kalender-Arithmetik (DST-sicher), analog zu denseTrendWindow.
        firstDay: addDays(startOfDay(today), -(_rangeDays - 1)),
      ),
      const SizedBox(height: 14),
      // IntrinsicHeight statt CrossAxisAlignment.stretch: im ScrollView ist
      // die Hoehe unbegrenzt, stretch wuerde h=Infinity erzwingen. So werden
      // beide Kennzahlen-Karten gleich hoch wie die hoehere von beiden.
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _StatCard(
                key: const ValueKey('trends-avg-kcal'),
                label: l10n.trendsStatAvgKcalLabel,
                value: avgKcal == null
                    ? '–'
                    : '${formatThousands(avgKcal.round(), l10n.localeName)} kcal',
                sub: avgKcal == null
                    ? l10n.trendsNoCompletedDay
                    : l10n.trendsStatAvgKcalSub,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                key: const ValueKey('trends-goal-rate'),
                label: l10n.trendsStatGoalRateLabel,
                // tracked == 0 ist der einzige Weg zu einer 0/0-Division —
                // hier abgefangen, damit nie ein NaN ins Widget geraet.
                value: hits.tracked == 0
                    ? '–'
                    : '${(hits.hit / hits.tracked * 100).round()} %',
                sub: hits.tracked == 0
                    ? l10n.trendsNoCompletedDay
                    : l10n.trendsStatGoalRateSub(hits.hit, hits.tracked),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _MacroAveragesCard(macros: macros),
      const SizedBox(height: 10),
      // B6: Die Beschriftung muss zur Rechnung passen — die drei Kennzahlen
      // oben zaehlen den laufenden Tag nicht mit, das Chart schon.
      const _MetricsNote(),
    ];
  }
}

/// Fussnote unter den Kennzahlen: benennt, dass der laufende Tag aus den
/// Durchschnitten und der Trefferquote herausfaellt (B6). Eine Zeile fuer alle
/// drei Kacheln — in den 11-px-Sublabels der schmalen Karten waere derselbe
/// Hinweis dreimal umgebrochen.
class _MetricsNote extends StatelessWidget {
  const _MetricsNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('trends-metrics-note'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        context.l10n.trendsMetricsNote,
        style: AppType.ui(
          11,
          weight: FontWeight.w500,
          color: context.t.ink2,
          height: 1.4,
        ),
      ),
    );
  }
}

/// Zeitraum-Umschalter: drei gleich breite Filter-Pillen.
class _RangeSelector extends StatelessWidget {
  const _RangeSelector({
    required this.ranges,
    required this.selected,
    required this.onSelected,
  });

  final List<int> ranges;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        for (var i = 0; i < ranges.length; i++) ...[
          Expanded(
            // Der Key sitzt auf der Semantics-Huelle, nicht auf der Pille:
            // so tippen die Tests unveraendert `trends-range-7` und der
            // Screenreader behaelt seinen erklaerenden Namen.
            child: Semantics(
              key: ValueKey('trends-range-${ranges[i]}'),
              button: true,
              selected: ranges[i] == selected,
              label: l10n.trendsRangeSemanticsLabel(ranges[i]),
              child: FilterChipPill(
                label: l10n.trendsRangeDaysLabel(ranges[i]),
                selected: ranges[i] == selected,
                onTap: () => onSelected(ranges[i]),
              ),
            ),
          ),
          if (i != ranges.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.window,
    required this.rangeDays,
    required this.kcalGoal,
    required this.avgKcal,
    required this.trackedDays,
    required this.firstDay,
  });

  final List<TrendDayTotals?> window;
  final int rangeDays;
  final int kcalGoal;
  final double? avgKcal;
  final int trackedDays;
  final DateTime firstDay;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // A11y: das Chart ist nur gezeichnet -> Kennwerte als Sprachwert.
    // [avgKcal] kommt aus den abgeschlossenen Tagen und kann null sein,
    // waehrend das Chart schon einen Balken zeigt (nur heute geloggt). Dann
    // faellt der Schnitt-Teilsatz weg — `?? 0` haette „im Schnitt 0
    // Kilokalorien" angesagt, was schlicht falsch waere.
    final avg = avgKcal;
    final semanticsValue = trackedDays == 0
        ? l10n.trendsChartSemanticsEmpty
        : avg == null
        ? l10n.trendsChartSemanticsNoAvg(trackedDays, rangeDays, kcalGoal)
        : l10n.trendsChartSemanticsWithAvg(
            trackedDays,
            rangeDays,
            avg.round(),
            kcalGoal,
          );
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  l10n.trendsChartTitle,
                  style: AppType.display(
                    17,
                    weight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  l10n.trendsRangeDaysLabel(rangeDays),
                  textAlign: TextAlign.right,
                  style: AppType.ui(
                    11.5,
                    weight: FontWeight.w600,
                    color: t.ink2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: Semantics(
              label: l10n.trendsChartSemanticsLabel,
              value: semanticsValue,
              child: RepaintBoundary(
                child: TweenAnimationBuilder<double>(
                  // Key pro Zeitraum: der Balken-Aufbau spielt beim Umschalten
                  // erneut; unter reduzierter Bewegung kollabiert er sofort.
                  key: ValueKey('trends-chart-anim-$rangeDays'),
                  tween: Tween(begin: 0, end: 1),
                  duration: motionDuration(
                    context,
                    const Duration(milliseconds: 550),
                  ),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => CustomPaint(
                    key: const ValueKey('trends-chart'),
                    painter: _KcalTrendPainter(
                      window: window,
                      goalKcal: kcalGoal,
                      firstDay: firstDay,
                      progress: value,
                      gridColor: t.line,
                      barColor: t.accent,
                      goalLineColor: t.ink.withValues(alpha: 0.6),
                      bandColor: t.ink.withValues(alpha: 0.05),
                      axisTextColor: t.ink2,
                      l10n: l10n,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ),
          if (rangeDays > 7) ...[
            const SizedBox(height: 6),
            Padding(
              // Gleiche seitliche Anker wie die Zeichenflaeche des Painters
              // (links Achsen-Rinne, rechts Innenrand).
              padding: const EdgeInsets.only(left: 40, right: 8),
              child: Row(
                children: [
                  _Caption('${firstDay.day}.${firstDay.month}.'),
                  const Spacer(),
                  _Caption(l10n.todayDateToday),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppType.ui(
        11,
        weight: FontWeight.w500,
        color: context.t.ink2,
        letterSpacing: 0.2,
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.sub,
  });

  final String label;
  final String value;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppType.eyebrow(t.ink2)),
          const SizedBox(height: 6),
          Text(value, style: AppType.display(20, color: t.ink)),
          const SizedBox(height: 2),
          Text(
            sub,
            style: AppType.ui(11, weight: FontWeight.w500, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

class _MacroAveragesCard extends StatelessWidget {
  const _MacroAveragesCard({required this.macros});

  final ({double proteinG, double carbsG, double fatG})? macros;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final m = macros;
    return AppCard(
      key: const ValueKey('trends-avg-macros'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.trendsMacroAvgTitle, style: AppType.eyebrow(t.ink2)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MacroAvg(
                  color: t.protein,
                  label: l10n.todayMacroProtein,
                  value: m == null ? '–' : '${m.proteinG.round()} g',
                ),
              ),
              Expanded(
                child: _MacroAvg(
                  color: t.carbs,
                  label: l10n.todayMacroCarbs,
                  value: m == null ? '–' : '${m.carbsG.round()} g',
                ),
              ),
              Expanded(
                child: _MacroAvg(
                  color: t.fat,
                  label: l10n.todayMacroFat,
                  value: m == null ? '–' : '${m.fatG.round()} g',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Eine Makro-Kennzahl: farbiger Identitaets-Punkt neben Text in Text-Tokens
/// (die Makro-Farbe traegt nie den Text selbst — zu wenig Kontrast).
class _MacroAvg extends StatelessWidget {
  const _MacroAvg({
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        // Flexible + ellipsis: bei 200%-Systemschrift sprengt
        // "Kohlenhydrate" sonst das Spalten-Drittel der Makro-Karte.
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(11, weight: FontWeight.w500, color: t.ink2),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.display(
                  14,
                  weight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      key: const ValueKey('trends-empty'),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
      child: Column(
        children: [
          Icon(Icons.query_stats_rounded, color: t.ink2, size: 32),
          const SizedBox(height: 12),
          Text(
            l10n.trendsEmptyTitle,
            style: AppType.display(17, weight: FontWeight.w700, color: t.ink),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.trendsEmptyBody,
            textAlign: TextAlign.center,
            style: AppType.ui(
              12,
              weight: FontWeight.w500,
              color: t.ink2,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      key: const ValueKey('trends-error'),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      child: Column(
        children: [
          Icon(Icons.cloud_off_rounded, color: t.ink2, size: 32),
          const SizedBox(height: 12),
          Text(
            l10n.trendsErrorTitle,
            textAlign: TextAlign.center,
            style: AppType.display(17, weight: FontWeight.w700, color: t.ink),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.trendsErrorBody,
            textAlign: TextAlign.center,
            style: AppType.ui(
              12,
              weight: FontWeight.w500,
              color: t.ink2,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          PrimaryActionButton(
            key: const ValueKey('trends-retry'),
            label: l10n.trendsRetryCta,
            height: 46,
            onTap: onRetry,
          ),
        ],
      ),
    );
  }
}

/// Kalorien-Balken pro Tag (eine Serie -> keine Legende, der Kartentitel
/// benennt sie). Balken wachsen von der 0-Basislinie, abgerundetes Daten-Ende
/// oben, eckig an der Basis; Luecken-Tage bleiben Luecken (kein 0-Balken —
/// „nicht getrackt" ist kein 0-kcal-Tag). Ruhige, durchgezogene Hairline-
/// Gridlines; die Ziellinie ist heller und traegt ein Label, der Korridor
/// (±10 %) liegt als leise Flaeche dahinter.
///
/// Alle fuenf Farben kommen als Felder herein und stehen in [shouldRepaint]:
/// beim Wechsel Hell/Dunkel aendert sich nur die Farbe, nicht die Datenlage.
class _KcalTrendPainter extends CustomPainter {
  _KcalTrendPainter({
    required this.window,
    required this.goalKcal,
    required this.firstDay,
    required this.progress,
    required this.gridColor,
    required this.barColor,
    required this.goalLineColor,
    required this.bandColor,
    required this.axisTextColor,
    required this.l10n,
  });

  final List<TrendDayTotals?> window;
  final int goalKcal;
  final DateTime firstDay;
  final double progress;
  final Color gridColor, barColor, goalLineColor, bandColor, axisTextColor;

  /// Widgets ohne BuildContext-Zugriff (hier: ein `CustomPainter`) bekommen
  /// die Lokalisierung als Parameter gereicht (docs/I18N_PAKETE.md §3),
  /// statt ein globales Lookup zu bauen — Vorbild `CoachSpeechInput.listen`.
  final AppLocalizations l10n;

  @override
  void paint(Canvas canvas, Size size) {
    _ensureDateSymbols();
    final showWeekdays = window.length == 7;
    final padding = EdgeInsets.fromLTRB(40, 14, 8, showWeekdays ? 20 : 6);
    final inner = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.horizontal,
      size.height - padding.vertical,
    );
    if (inner.width <= 0 || inner.height <= 0) return;

    var maxKcal = 0;
    var tracked = 0;
    for (final day in window) {
      if (day == null) continue;
      tracked++;
      maxKcal = math.max(maxKcal, day.kcal);
    }

    final base = math.max(maxKcal, goalKcal);
    final niceMax = _niceMax(base);

    // Ruhiges Grid: 4 durchgezogene Hairlines (0 bis niceMax in Dritteln),
    // Tick-Werte rechtsbuendig in der Achsen-Rinne.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = inner.bottom - inner.height * (i / 3);
      canvas.drawLine(Offset(inner.left, y), Offset(inner.right, y), gridPaint);
      _drawText(
        canvas,
        formatThousands((niceMax * i / 3).round(), l10n.localeName),
        Offset(inner.left - 6, y),
        alignRight: true,
        centerVertically: true,
      );
    }

    if (tracked == 0) {
      _drawEmptyHint(canvas, size);
      return;
    }

    // Zielkorridor (±10 %) als leise Flaeche hinter den Balken.
    if (goalKcal > 0) {
      final loY =
          inner.bottom -
          (goalKcal * (1 - trendGoalTolerance) / niceMax) * inner.height;
      final hiY =
          inner.bottom -
          (goalKcal * (1 + trendGoalTolerance) / niceMax) * inner.height;
      final band = Rect.fromLTRB(
        inner.left,
        hiY.clamp(inner.top, inner.bottom),
        inner.right,
        loY.clamp(inner.top, inner.bottom),
      );
      canvas.drawRect(band, Paint()..color = bandColor);
    }

    // Balken: duenne Marken mit Flaechen-Luecke zwischen Nachbarn, Daten-Ende
    // oben abgerundet, Basis eckig. Hoehe skaliert mit [progress] (Motion).
    final n = window.length;
    final slotW = inner.width / n;
    final gapW = slotW >= 8 ? 2.0 : 1.0;
    final barW = math.min(24.0, math.max(slotW - gapW, slotW * 0.55));
    final barPaint = Paint()..color = barColor.withValues(alpha: 0.92);
    for (var i = 0; i < n; i++) {
      final day = window[i];
      if (day == null || day.kcal <= 0) continue;
      final h = (day.kcal / niceMax) * inner.height * progress;
      final x = inner.left + slotW * i + (slotW - barW) / 2;
      final r = math.min(3.0, barW / 2);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, inner.bottom - h, barW, h),
          topLeft: Radius.circular(r),
          topRight: Radius.circular(r),
        ),
        barPaint,
      );
    }

    // Ziellinie: heller als das Grid, durchgezogen, mit Label am rechten Ende.
    if (goalKcal > 0) {
      final goalY = inner.bottom - (goalKcal / niceMax) * inner.height;
      final goalPaint = Paint()
        ..color = goalLineColor
        ..strokeWidth = 1.4;
      canvas.drawLine(
        Offset(inner.left, goalY),
        Offset(inner.right, goalY),
        goalPaint,
      );
      _drawText(
        canvas,
        l10n.trendsChartGoalLabel(formatThousands(goalKcal, l10n.localeName)),
        Offset(inner.right, goalY - 4),
        alignRight: true,
        above: true,
      );
    }

    // 7-Tage-Ansicht: Wochentags-Kuerzel unter jedem Slot als X-Beschriftung.
    if (showWeekdays) {
      for (var i = 0; i < n; i++) {
        // B5: Kalendertag-Verschiebung; eine Duration-Addition wuerde die
        // Wochentags-Kuerzel nach einer DST-Kante um einen Tag verschieben.
        final day = addDays(firstDay, i);
        _drawText(
          canvas,
          DateFormat.E(l10n.localeName).format(day),
          Offset(inner.left + slotW * i + slotW / 2, inner.bottom + 4),
          centerHorizontally: true,
        );
      }
    }
  }

  /// Rundet die Achsen-Spitze auf einen sauberen Wert, der sich glatt
  /// dritteln laesst (Ticks wie 0 / 1.000 / 2.000 / 3.000).
  static int _niceMax(int base) {
    if (base <= 0) return 300;
    const steps = [100, 200, 250, 500, 1000, 2000, 2500, 5000];
    final rawStep = base * 1.05 / 3;
    for (final step in steps) {
      if (step >= rawStep) return step * 3;
    }
    final step = (rawStep / 5000).ceil() * 5000;
    return step * 3;
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset anchor, {
    bool alignRight = false,
    bool centerHorizontally = false,
    bool centerVertically = false,
    bool above = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: AppType.display(9, weight: FontWeight.w500, color: axisTextColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = anchor.dx;
    if (alignRight) dx -= tp.width;
    if (centerHorizontally) dx -= tp.width / 2;
    var dy = anchor.dy;
    if (centerVertically) dy -= tp.height / 2;
    if (above) dy -= tp.height;
    tp.paint(canvas, Offset(dx, dy));
  }

  void _drawEmptyHint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: l10n.trendsChartEmptyHintPainter,
        style: AppType.ui(
          12,
          weight: FontWeight.w500,
          color: axisTextColor,
          height: 1.4,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 24);
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _KcalTrendPainter old) =>
      old.window != window ||
      old.goalKcal != goalKcal ||
      old.firstDay != firstDay ||
      old.progress != progress ||
      old.gridColor != gridColor ||
      old.barColor != barColor ||
      old.goalLineColor != goalLineColor ||
      old.bandColor != bandColor ||
      old.axisTextColor != axisTextColor ||
      old.l10n != l10n;
}

/// Einmalige Initialisierung der `intl`-Datumssymbole (Wochentagskuerzel des
/// Trend-Charts). Gleiches Muster wie `today_texts.dart`s
/// `_ensureDateSymbols`: `initializeDateFormatting()` laedt synchron eine
/// gebuendelte Tabelle, der Bool-Waechter verhindert nur den wiederholten
/// Aufbau bei jedem Repaint.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}
