import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/trend_service.dart';
import '../theme/app_colors.dart';
import '../widgets/common/basic_widgets.dart';
import '../widgets/common/lively.dart';
import '../widgets/common/motion.dart';

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
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        scrolledUnderElevation: 0,
        elevation: 0,
        leading: IconButton(
          key: const ValueKey('trends-close'),
          tooltip: 'Zurück',
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: textPrimary,
            size: 20,
          ),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text(
          'Trends',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        top: false,
        child: LivelyEntrance(
          child: SingleChildScrollView(
            key: const ValueKey('screen-trends'),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
    if (_loading) {
      return const [
        SizedBox(
          key: ValueKey('trends-loading'),
          height: 260,
          child: Center(
            child: CircularProgressIndicator(color: forgeLime, strokeWidth: 3),
          ),
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
    final avgKcal = averageKcalOf(window);
    final hits = goalHitsOf(window, goalKcal: widget.kcalGoal);
    final macros = averageMacrosOf(window);

    return [
      _ChartCard(
        window: window,
        rangeDays: _rangeDays,
        kcalGoal: widget.kcalGoal,
        avgKcal: avgKcal,
        trackedDays: hits.tracked,
        // Kalender-Arithmetik (DST-sicher), analog zu denseTrendWindow.
        firstDay: DateTime(
          today.year,
          today.month,
          today.day - (_rangeDays - 1),
        ),
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
                label: 'Ø KALORIEN',
                value: avgKcal == null
                    ? '–'
                    : '${formatKcalDe(avgKcal.round())} kcal',
                sub: 'pro getracktem Tag',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                key: const ValueKey('trends-goal-rate'),
                label: 'ZIEL GETROFFEN',
                value: hits.tracked == 0
                    ? '–'
                    : '${(hits.hit / hits.tracked * 100).round()} %',
                sub: '${hits.hit} von ${hits.tracked} Tagen (±10 %)',
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _MacroAveragesCard(macros: macros),
    ];
  }
}

/// Deutsche Tausender-Formatierung ohne intl-Dependency: 2200 -> "2.200".
String formatKcalDe(int value) {
  final digits = value.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  return value < 0 ? '-$buf' : buf.toString();
}

/// Zeitraum-Umschalter als Soft-Kapseln (Flaechen-Aufhellung statt Rahmen,
/// gleiches Muster wie die Datums-Chips im Food-Tab).
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
    return Row(
      children: [
        for (var i = 0; i < ranges.length; i++) ...[
          Expanded(
            child: _RangeChip(
              key: ValueKey('trends-range-${ranges[i]}'),
              days: ranges[i],
              selected: ranges[i] == selected,
              onTap: () => onSelected(ranges[i]),
            ),
          ),
          if (i != ranges.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _RangeChip extends StatelessWidget {
  const _RangeChip({
    super.key,
    required this.days,
    required this.selected,
    required this.onTap,
  });

  final int days;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Zeitraum $days Tage',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: AnimatedContainer(
          duration: motionDuration(context, const Duration(milliseconds: 160)),
          curve: Curves.easeOut,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? forgeLime : surface,
            borderRadius: BorderRadius.circular(rControl),
          ),
          child: Text(
            '$days Tage',
            style: TextStyle(
              color: selected ? bg : textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
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
    // A11y: das Chart ist nur gezeichnet -> Kennwerte als Sprachwert.
    final semanticsValue = trackedDays == 0
        ? 'Keine Einträge in diesem Zeitraum'
        : '$trackedDays von $rangeDays Tagen mit Einträgen, '
              'im Schnitt ${avgKcal?.round() ?? 0} Kilokalorien pro Tag, '
              'Tagesziel $kcalGoal Kilokalorien';
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Kalorien pro Tag',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Text(
                '$rangeDays Tage',
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: Semantics(
              label: 'Kalorienverlauf',
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
                  builder: (context, t, _) => CustomPaint(
                    key: const ValueKey('trends-chart'),
                    painter: _KcalTrendPainter(
                      window: window,
                      goalKcal: kcalGoal,
                      firstDay: firstDay,
                      progress: t,
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
                  const _Caption('Heute'),
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
      style: const TextStyle(
        color: textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        fontFeatures: [FontFeature.tabularFigures()],
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
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            style: const TextStyle(
              color: textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
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
    final m = macros;
    return AppCard(
      key: const ValueKey('trends-avg-macros'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ø MAKROS PRO TAG',
            style: TextStyle(
              color: textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MacroAvg(
                  color: macroProtein,
                  label: 'Protein',
                  value: m == null ? '–' : '${m.proteinG.round()} g',
                ),
              ),
              Expanded(
                child: _MacroAvg(
                  color: macroCarbs,
                  label: 'Carbs',
                  value: m == null ? '–' : '${m.carbsG.round()} g',
                ),
              ),
              Expanded(
                child: _MacroAvg(
                  color: macroFat,
                  label: 'Fett',
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
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
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
    return const AppCard(
      key: ValueKey('trends-empty'),
      padding: EdgeInsets.fromLTRB(20, 28, 20, 28),
      child: Column(
        children: [
          Icon(Icons.query_stats_rounded, color: textMuted, size: 32),
          SizedBox(height: 12),
          Text(
            'Noch zu wenig Daten',
            style: TextStyle(
              color: textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Logge deine Mahlzeiten an mindestens zwei Tagen,\n'
            'um hier deinen Verlauf zu sehen.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textMuted,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w500,
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
    return AppCard(
      key: const ValueKey('trends-error'),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      child: Column(
        children: [
          const Icon(Icons.cloud_off_rounded, color: textMuted, size: 32),
          const SizedBox(height: 12),
          const Text(
            'Trends konnten nicht geladen werden',
            style: TextStyle(
              color: textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Prüfe deine Internetverbindung und versuche es erneut.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textMuted,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          InkWell(
            key: const ValueKey('trends-retry'),
            onTap: onRetry,
            borderRadius: BorderRadius.circular(rControl),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: forgeLime,
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: const Text(
                'Erneut versuchen',
                style: TextStyle(
                  color: bg,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
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
/// (±10 %) liegt als leise Flaeche dahinter. Achsentext in Text-Tokens.
class _KcalTrendPainter extends CustomPainter {
  _KcalTrendPainter({
    required this.window,
    required this.goalKcal,
    required this.firstDay,
    required this.progress,
  });

  final List<TrendDayTotals?> window;
  final int goalKcal;
  final DateTime firstDay;
  final double progress;

  static const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

  @override
  void paint(Canvas canvas, Size size) {
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
      ..color = hairline
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = inner.bottom - inner.height * (i / 3);
      canvas.drawLine(Offset(inner.left, y), Offset(inner.right, y), gridPaint);
      _drawText(
        canvas,
        formatKcalDe((niceMax * i / 3).round()),
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
      canvas.drawRect(
        band,
        Paint()..color = textPrimary.withValues(alpha: 0.05),
      );
    }

    // Balken: duenne Marken mit Flaechen-Luecke zwischen Nachbarn, Daten-Ende
    // oben abgerundet, Basis eckig. Hoehe skaliert mit [progress] (Motion).
    final n = window.length;
    final slotW = inner.width / n;
    final gapW = slotW >= 8 ? 2.0 : 1.0;
    final barW = math.min(24.0, math.max(slotW - gapW, slotW * 0.55));
    final barPaint = Paint()..color = forgeLime.withValues(alpha: 0.92);
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
        ..color = textPrimary.withValues(alpha: 0.6)
        ..strokeWidth = 1.4;
      canvas.drawLine(
        Offset(inner.left, goalY),
        Offset(inner.right, goalY),
        goalPaint,
      );
      _drawText(
        canvas,
        'Ziel ${formatKcalDe(goalKcal)}',
        Offset(inner.right, goalY - 4),
        alignRight: true,
        above: true,
      );
    }

    // 7-Tage-Ansicht: Wochentags-Kuerzel unter jedem Slot als X-Beschriftung.
    if (showWeekdays) {
      for (var i = 0; i < n; i++) {
        final day = DateTime(firstDay.year, firstDay.month, firstDay.day + i);
        _drawText(
          canvas,
          _weekdays[day.weekday - 1],
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
        style: const TextStyle(
          color: textMuted,
          fontSize: 9,
          fontWeight: FontWeight.w500,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
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
      text: const TextSpan(
        text: 'Keine Einträge in diesem Zeitraum.',
        style: TextStyle(
          color: textMuted,
          fontSize: 12,
          height: 1.4,
          fontWeight: FontWeight.w500,
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
      old.progress != progress;
}
