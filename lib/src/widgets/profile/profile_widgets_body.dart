part of 'profile_widgets.dart';

/// Weight card: current value, delta pill, sparkline over the real history,
/// progress towards the target weight, and the log-weight action.
class WeightCard extends StatelessWidget {
  const WeightCard({
    super.key,
    required this.profile,
    required this.log,
    required this.onLogWeight,
  });

  final UserProfile profile;
  final WeightLog log;
  final ValueChanged<double> onLogWeight;

  double get _current => log.latest?.weightKg ?? profile.weightKg.toDouble();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final entries = log.entries;
    final hatVerlauf = entries.length >= 2;
    final delta = log.trendDelta;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l10n.profileWeightTitle,
                      style: AppType.display(
                        17,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      hatVerlauf
                          ? l10n.profileWeightMeasurementsCount(entries.length)
                          : '–',
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
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: <Widget>[
                          Text(
                            formatKgDe(_current, l10n),
                            style: AppType.display(34, color: t.ink),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'kg',
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w600,
                              color: t.ink2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (delta != null) ...<Widget>[
                    const SizedBox(width: 10),
                    _DeltaPill(delta: delta),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // A11y: the sparkline is painted only -> announce the range.
              Semantics(
                label: l10n.profileWeightHistorySemanticsLabel,
                value: hatVerlauf
                    ? l10n.profileWeightHistorySemanticsValue(
                        entries.length,
                        formatKgDe(entries.last.weightKg, l10n),
                      )
                    : l10n.profileWeightHistoryEmptySemantics,
                child: hatVerlauf
                    ? RepaintBoundary(
                        child: Sparkline(
                          values: <double>[
                            for (final e in entries) e.weightKg,
                          ],
                        ),
                      )
                    // Below two measurements the sparkline draws nothing, and
                    // an empty 74 px area would look like a loading error.
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          l10n.profileWeightHistoryEmptyHint,
                          style: AppType.ui(12, color: t.ink2, height: 1.4),
                        ),
                      ),
              ),
              if (hatVerlauf) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    _Caption(_formatShort(entries.first.timestamp, l10n)),
                    const Spacer(),
                    _Caption(_formatShort(entries.last.timestamp, l10n)),
                  ],
                ),
              ],
              ..._buildGoalProgress(context),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PrimaryActionButton(
          key: const ValueKey('profile-log-weight'),
          label: l10n.profileLogWeightCta,
          icon: Icons.add_rounded,
          height: 48,
          onTap: () => _promptWeight(context),
        ),
      ],
    );
  }

  /// Progress from the FIRST measured weight to the target weight.
  ///
  /// If the target sits on the start value ("maintain") the row is dropped: a
  /// 100 % bar for a non-goal would be a fake success, and (start - target)
  /// would be a zero denominator.
  List<Widget> _buildGoalProgress(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final start = log.entries.isNotEmpty
        ? log.entries.first.weightKg
        : profile.weightKg.toDouble();
    final ziel = profile.targetWeightKg.toDouble();
    final spanne = (start - ziel).abs();
    if (spanne < 0.1) return const <Widget>[];

    // Weight moving the wrong way clamps to 0 on purpose; a negative bar
    // helps nobody.
    final fortschritt = ((start - _current) / (start - ziel)).clamp(0.0, 1.0);
    final prozent = (fortschritt * 100).round();

    return <Widget>[
      const SizedBox(height: 14),
      Divider(height: 1, thickness: 1, color: t.line),
      const SizedBox(height: 14),
      Semantics(
        label: l10n.profileGoalProgressSemanticsLabel,
        value: '$prozent %',
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.profileGoalTargetLabel(formatKgDe(ziel, l10n)),
                    style: AppType.ui(
                      11.5,
                      weight: FontWeight.w600,
                      color: t.ink,
                    ),
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: fortschritt,
                      minHeight: 7,
                      backgroundColor: t.tile,
                      valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$prozent %',
              style: AppType.ui(11.5, weight: FontWeight.w700, color: t.ink2),
            ),
          ],
        ),
      ),
    ];
  }

  /// **D5, deliberately WITHOUT a discard prompt.**
  ///
  /// One field, prefilled with the last logged weight that is also shown large
  /// on the card behind; an accidental dismiss costs two or three keystrokes.
  /// A prompt would cost an extra tap on every close and protect almost
  /// nothing. Sheets with multi-part forms do keep their prompt.
  ///
  /// No `showDragHandle: true` either: the theme sets it false globally, and
  /// the route's handle is a stack sibling NEXT TO the builder child, where no
  /// sheet can reach it. Drawn inside the sheet instead, see
  /// [_ProfileSheetGrabber].
  Future<void> _promptWeight(BuildContext context) async {
    final result = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: context.t.bg,
      isScrollControlled: true,
      builder: (_) => _ProfileWeightInputSheet(initial: _current),
    );
    if (result != null) onLogWeight(result);
  }

  static String _formatShort(DateTime d, AppLocalizations l10n) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return l10n.profileWeightCaptionToday;
    }
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.';
  }
}

/// BMI card: semicircle gauge, zone chip and the remaining body data.
class BmiCard extends StatelessWidget {
  const BmiCard({super.key, required this.profile, required this.log});

  final UserProfile profile;
  final WeightLog log;

  double get _bmi {
    final m = profile.heightCm / 100.0;
    if (m <= 0) return 0;
    final w = log.latest?.weightKg ?? profile.weightKg.toDouble();
    return w / (m * m);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final bmi = _bmi;
    final bmiLabel = BMIGaugePainter.labelFor(bmi, l10n);
    final bmiColor = BMIGaugePainter.colorFor(t, bmi);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.profileSectionBody,
                  style: AppType.display(
                    17,
                    weight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
              ),
              _InfoButton(
                onTap: () => _showBmiInfoSheet(context),
                tooltip: l10n.profileBmiInfoTooltip,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Center(
            child: SizedBox(
              width: 190,
              height: 108,
              // A11y: the gauge is pure CustomPaint -> announce value + zone.
              child: Semantics(
                label: 'BMI',
                value: '${formatBmiDe(bmi, l10n)} · $bmiLabel',
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: BMIGaugePainter.fromTokens(
                      t,
                      bmi,
                      formatBmiDe(bmi, l10n),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bmiColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(rControl),
              border: Border.all(color: bmiColor.withValues(alpha: 0.32)),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: bmiColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.profileBmiZoneLabel(bmiLabel),
                    style: AppType.ui(
                      12,
                      weight: FontWeight.w600,
                      color: bmiColor,
                    ),
                  ),
                ),
                Text(
                  formatBmiDe(bmi, l10n),
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w700,
                    color: bmiColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Wrap instead of Row: at large system font the two entries stack
          // instead of overflowing the line.
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: <Widget>[
              _BodyMetric(
                icon: Icons.height_rounded,
                label: '${profile.heightCm} cm',
              ),
              _BodyMetric(
                icon: Icons.cake_outlined,
                label: '${l10n.profileAgeAbbreviation(profile.ageYears)} · '
                    '${profile.sex.label(l10n)}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// `isScrollControlled` because at 2x system font the four zone rows plus
  /// the explanation exceed the 9/16 screen height an uncontrolled sheet gets
  /// (measured 1087 px overflow). The content scrolls too, see [_BmiInfoSheet].
  static void _showBmiInfoSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.t.bg,
      isScrollControlled: true,
      builder: (_) => const _BmiInfoSheet(),
    );
  }
}

/// Grab handle of the profile sheets — drawn in the sheet, not on the route.
///
/// The dismiss semantics must move along: the route handle offered a tap
/// action to TalkBack/VoiceOver, neither sheet here has a close button, and on
/// Android the barrier offers no dismiss semantics either — without this a
/// screen-reader user would be stuck.
class _ProfileSheetGrabber extends StatelessWidget {
  const _ProfileSheetGrabber();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      onTap: () => Navigator.of(context).maybePop(),
      child: SizedBox(
        width: double.infinity,
        height: 26,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.ink2.withValues(alpha: 0.5),
                borderRadius: const BorderRadius.all(Radius.circular(rPill)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BmiInfoSheet extends StatelessWidget {
  const _BmiInfoSheet();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // Name AND colour come from [BMIGaugePainter]; a second copy here is where
    // the legend would silently drift from gauge and zone chip. The sample
    // values sit in the middle of their zone.
    final zones = <(String, String, Color)>[
      for (final z in <(double, String)>[
        (17.0, '< 18.5'),
        (22.0, '18.5 – 24.9'),
        (27.0, '25.0 – 29.9'),
        (32.0, '≥ 30.0'),
      ])
        (
          BMIGaugePainter.labelFor(z.$1, l10n),
          z.$2,
          BMIGaugePainter.colorFor(t, z.$1),
        ),
    ];
    // Handle stays pinned, the rest scrolls: at 2x system font the zone list
    // is taller than the screen.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Center(child: _ProfileSheetGrabber()),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.profileBmiInfoSheetTitle,
                  style: AppType.display(20, color: t.ink),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.profileBmiInfoSheetBody,
                  style: AppType.ui(13, color: t.ink2, height: 1.45),
                ),
                const SizedBox(height: 16),
                for (final z in zones)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: z.$3.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(rControl),
                      border: Border.all(color: z.$3.withValues(alpha: 0.32)),
                    ),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 8,
                          height: 8,
                          decoration:
                              BoxDecoration(color: z.$3, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            z.$1,
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w600,
                              color: z.$3,
                            ),
                          ),
                        ),
                        // Flexible: the range text is wider than the rest of
                        // the row at 200 % system font.
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              z.$2,
                              textAlign: TextAlign.right,
                              style: AppType.ui(
                                12,
                                weight: FontWeight.w500,
                                color: t.ink2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
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
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Center(child: _ProfileSheetGrabber()),
          Text(l10n.profileLogWeightCta,
              style: AppType.display(20, color: t.ink)),
          const SizedBox(height: 16),
          // Local TextField instead of SheetField: the field must hold focus
          // on open (`autofocus`), which SheetField does not expose. The
          // InputDecoration still comes from the theme.
          TextField(
            key: const ValueKey('profile-weight-input'),
            cursorOpacityAnimates: false,
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l10n.profileWeightInputLabel,
              suffixText: 'kg',
            ),
          ),
          const SizedBox(height: 16),
          PrimaryActionButton(
            key: const ValueKey('profile-weight-save'),
            label: l10n.commonSave,
            icon: Icons.check_rounded,
            height: 50,
            onTap: () {
              final raw = _controller.text.trim().replaceAll(',', '.');
              final value = double.tryParse(raw);
              if (value != null && value > 0) Navigator.pop(context, value);
            },
          ),
        ],
      ),
    );
  }
}

/// The change since the first measurement.
///
/// Full lime surface with `onLime` (the documented pair, dark on light in both
/// modes) instead of the mock's 45 %-opacity lime with `ink`, which would be
/// light on light in dark mode. The flat state stays quiet on `tile`.
class _DeltaPill extends StatelessWidget {
  const _DeltaPill({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final isFlat = delta.abs() < 0.05;
    final icon = isFlat
        ? Icons.remove_rounded
        : (delta > 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded);
    // U+2212 as minus, as everywhere else in the app (paceLabel).
    final label = isFlat
        ? l10n.profileStable
        : '${delta > 0 ? '+' : '−'}${formatKgDe(delta.abs(), l10n)} kg';
    final fg = isFlat ? t.ink2 : t.onLime;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isFlat ? t.tile : t.lime,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: fg, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppType.ui(11, weight: FontWeight.w700, color: fg),
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
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, color: t.ink2, size: 13),
        const SizedBox(width: 6),
        // Flexible + ellipsis: as a rigid Row child the text measured its full
        // single-line width and overflowed at large system font — a Wrap only
        // controls line breaks, not the width of one child.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
          ),
        ),
      ],
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

class _InfoButton extends StatelessWidget {
  const _InfoButton({required this.onTap, required this.tooltip});

  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: 44x44 hit target; chip and glyph stay visually 28/15.
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
                color: t.tile,
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: Icon(
                Icons.info_outline_rounded,
                color: t.ink2,
                size: 15,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
