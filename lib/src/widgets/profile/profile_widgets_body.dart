part of 'profile_widgets.dart';

class BodyStatsCard extends StatelessWidget {
  const BodyStatsCard({
    super.key,
    required this.profile,
    required this.log,
    required this.onLogWeight,
  });

  final UserProfile profile;
  final WeightLog log;
  final ValueChanged<double> onLogWeight;

  double get _bmi {
    final m = profile.heightCm / 100.0;
    if (m <= 0) return 0;
    final w = log.latest?.weightKg ?? profile.weightKg.toDouble();
    return w / (m * m);
  }

  @override
  Widget build(BuildContext context) {
    final latest = log.latest;
    final delta = log.trendDelta;
    final weightValue = latest?.weightKg ?? profile.weightKg.toDouble();
    final bmi = _bmi;
    final bmiLabel = BMIGaugePainter.labelFor(bmi);
    final bmiColor = BMIGaugePainter.colorFor(bmi);

    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Körper',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              _InfoButton(
                onTap: () => _showBmiInfoSheet(context),
                tooltip: 'BMI-Erklärung',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      weightValue.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.4,
                        height: 1,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'kg · aktuelles Gewicht',
                      style: TextStyle(
                        color: textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (delta != null) ...[
                      const SizedBox(height: 8),
                      _DeltaPill(delta: delta),
                    ],
                    const SizedBox(height: 14),
                    _BodyMetric(
                      icon: Icons.height_rounded,
                      label: '${profile.heightCm} cm',
                    ),
                    const SizedBox(height: 6),
                    _BodyMetric(
                      icon: Icons.cake_outlined,
                      label: '${profile.ageYears} J. · ${profile.sex.label}',
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 140,
                height: 110,
                // A11y: Gauge ist reines CustomPaint -> Wert + Zone ansagen.
                child: Semantics(
                  label: 'BMI',
                  value: '${bmi.toStringAsFixed(1)} · $bmiLabel',
                  child: RepaintBoundary(
                    child: CustomPaint(painter: BMIGaugePainter(bmi: bmi)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bmiColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(rControl),
              border: Border.all(color: bmiColor.withValues(alpha: 0.32)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: bmiColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'BMI $bmiLabel',
                    style: TextStyle(
                      color: bmiColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                Text(
                  bmi.toStringAsFixed(1),
                  style: TextStyle(
                    color: bmiColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('profile-log-weight'),
              onPressed: () => _promptWeight(context),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text(
                'Gewicht loggen',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: textPrimary,
                side: const BorderSide(color: hairline),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _promptWeight(BuildContext context) async {
    final result = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          _ProfileWeightInputSheet(initial: log.latest?.weightKg ?? profile.weightKg.toDouble()),
    );
    if (result != null) onLogWeight(result);
  }

  static void _showBmiInfoSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      showDragHandle: true,
      builder: (_) => const _BmiInfoSheet(),
    );
  }
}

class _BmiInfoSheet extends StatelessWidget {
  const _BmiInfoSheet();

  @override
  Widget build(BuildContext context) {
    final zones = [
      ('Untergewicht', '< 18.5', cyan),
      ('Normal', '18.5 – 24.9', lime),
      ('Übergewicht', '25.0 – 29.9', orange),
      ('Adipös', '≥ 30.0', danger),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'BMI Orientierung',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Body Mass Index ist eine grobe Heuristik. Für Athleten und '
            'athletische Körper ist die Tendenz interessanter als der '
            'absolute Wert.',
            style: TextStyle(color: textMuted, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 16),
          for (final z in zones) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: z.$3.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(rControl),
                border: Border.all(color: z.$3.withValues(alpha: 0.32)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: z.$3,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      z.$1,
                      style: TextStyle(
                        color: z.$3,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    z.$2,
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
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

class _ProfileWeightInputSheet extends StatefulWidget {
  const _ProfileWeightInputSheet({required this.initial});

  final double initial;

  @override
  State<_ProfileWeightInputSheet> createState() =>
      _ProfileWeightInputSheetState();
}

class _ProfileWeightInputSheetState extends State<_ProfileWeightInputSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initial.toStringAsFixed(1),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Gewicht loggen',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('profile-weight-input'),
            cursorOpacityAnimates: false,
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Aktuelles Gewicht',
              suffixText: 'kg',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('profile-weight-save'),
              onPressed: () {
                final raw = _controller.text.trim().replaceAll(',', '.');
                final value = double.tryParse(raw);
                if (value != null && value > 0) Navigator.pop(context, value);
              },
              icon: const Icon(Icons.check_rounded, size: 17),
              label: const Text(
                'Speichern',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: lime,
                foregroundColor: bg,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeltaPill extends StatelessWidget {
  const _DeltaPill({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    final isFlat = delta.abs() < 0.05;
    final color = isFlat ? textMuted : (delta > 0 ? orange : cyan);
    final icon = isFlat
        ? Icons.remove_rounded
        : (delta > 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded);
    final label = isFlat
        ? 'stabil'
        : '${delta > 0 ? '+' : ''}${delta.toStringAsFixed(1)} kg';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _BodyMetric extends StatelessWidget {
  const _BodyMetric({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: textMuted, size: 13),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class WeightHistoryCard extends StatelessWidget {
  const WeightHistoryCard({super.key, required this.log, required this.accent});

  final WeightLog log;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final hasData = log.entries.length >= 2;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Verlauf',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Text(
                hasData ? '${log.entries.length} Messungen' : '–',
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 130,
            // A11y: Verlaufslinie ist nur gezeichnet -> Spanne als Sprachwert.
            child: Semantics(
              label: 'Gewichtsverlauf',
              value: hasData
                  ? '${log.entries.length} Messungen, '
                      'zuletzt ${log.entries.last.weightKg.toStringAsFixed(1)} kg'
                  : 'Noch keine Verlaufslinie',
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: WeightLineChartPainter(
                    entries: log.entries,
                    accent: accent,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
          if (hasData) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                _Caption(_formatShort(log.entries.first.timestamp)),
                const Spacer(),
                _Caption(_formatShort(log.entries.last.timestamp)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _formatShort(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return 'heute';
    }
    return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.';
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
      ),
    );
  }
}

class _InfoButton extends StatelessWidget {
  const _InfoButton({required this.onTap, required this.tooltip});

  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    // A11y: 44x44 Hit-Target, Chip + Glyph bleiben optisch 28/15.
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 44,
        height: 44,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rControl),
          child: Center(
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: surfaceSoft,
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: const Icon(
                Icons.info_outline_rounded,
                color: textMuted,
                size: 15,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
