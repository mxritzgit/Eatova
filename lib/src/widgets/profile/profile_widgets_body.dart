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
  final PersistValueChanged<double> onLogWeight;

  double get _current => log.latest?.weightKg ?? profile.weightKg.toDouble();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final entries = log.entries;
    final hatVerlauf = entries.length >= 2;
    final delta = log.trendDelta;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.profileWeightTitle,
                  style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                hatVerlauf
                    ? l10n.profileWeightMeasurementsCount(entries.length)
                    : '–',
                textAlign: TextAlign.right,
                style: AppType.ui(12, weight: FontWeight.w500, color: t.ink3),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
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
                        style: AppType.display(
                          40,
                          weight: FontWeight.w700,
                          color: t.ink,
                          letterSpacing: -0.8,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'kg',
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w600,
                          color: t.ink3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (delta != null) ...<Widget>[
                const SizedBox(width: 12),
                _DeltaPill(delta: delta),
              ],
            ],
          ),
          const SizedBox(height: 16),
          // A11y: the chart is painted only -> announce the range.
          Semantics(
            label: l10n.profileWeightHistorySemanticsLabel,
            value: hatVerlauf
                ? l10n.profileWeightHistorySemanticsValue(
                    entries.length,
                    formatKgDe(entries.last.weightKg, l10n),
                  )
                : l10n.profileWeightHistoryEmptySemantics,
            child: hatVerlauf
                ? _WeightChart(
                    values: <double>[for (final e in entries) e.weightKg],
                  )
                // Below two measurements there is no line, and an empty chart
                // area would look like a loading error.
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: t.surfRaised,
                      borderRadius: BorderRadius.circular(rControl),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.show_chart_rounded,
                          size: 18,
                          color: t.accentText,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            l10n.profileWeightHistoryEmptyHint,
                            style: AppType.ui(
                              12.5,
                              color: t.ink2,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          if (hatVerlauf) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                // Baseline and latest — the same two points delta pill and
                // progress bar are built on (F7-03).
                _Caption(_formatShort(log.baseline!.timestamp, l10n)),
                const Spacer(),
                _Caption(_formatShort(log.latest!.timestamp, l10n)),
              ],
            ),
          ],
          ..._buildGoalProgress(context),
          const SizedBox(height: 18),
          PrimaryActionButton(
            key: const ValueKey('profile-log-weight'),
            label: l10n.profileLogWeightCta,
            icon: Icons.add_rounded,
            height: 48,
            onTap: () => _promptWeight(context),
          ),
        ],
      ),
    );
  }

  /// Progress from the explicit baseline ([WeightLog.baseline], the first
  /// weigh-in still in the history; the onboarding weight without one) to
  /// the target weight (F7-03).
  ///
  /// If the target sits on the start value ("maintain") the row is dropped: a
  /// 100 % bar for a non-goal would be a fake success, and (start - target)
  /// would be a zero denominator.
  List<Widget> _buildGoalProgress(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final start = log.baseline?.weightKg ?? profile.weightKg.toDouble();
    final ziel = profile.targetWeightKg.toDouble();
    final spanne = (start - ziel).abs();
    if (spanne < 0.1) return const <Widget>[];

    // Weight moving the wrong way clamps to 0 on purpose; a negative bar
    // helps nobody.
    final fortschritt = ((start - _current) / (start - ziel)).clamp(0.0, 1.0);
    final prozent = (fortschritt * 100).round();

    return <Widget>[
      const SizedBox(height: 16),
      Divider(height: 1, thickness: 1, color: t.line),
      const SizedBox(height: 16),
      Semantics(
        label: l10n.profileGoalProgressSemanticsLabel,
        value: '$prozent %',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.flag_rounded, size: 15, color: t.accentText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.profileGoalTargetLabel(formatKgDe(ziel, l10n)),
                    style: AppType.ui(
                      13,
                      weight: FontWeight.w600,
                      color: t.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$prozent %',
                  style: AppType.ui(
                    13,
                    weight: FontWeight.w700,
                    color: t.accentText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: fortschritt),
              duration: motionDuration(context, kMotionValue),
              curve: kMotionCurve,
              builder: (context, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  backgroundColor: t.tile,
                  valueColor: AlwaysStoppedAnimation<Color>(t.progressAccent),
                ),
              ),
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
  /// sheet can reach it. Drawn inside the sheet instead: a [SheetHandle] with
  /// the dismiss action.
  Future<void> _promptWeight(BuildContext context) async {
    await showModalBottomSheet<double>(
      showDragHandle: false,
      context: context,
      backgroundColor: context.t.bg,
      isScrollControlled: true,
      builder: (_) =>
          _ProfileWeightInputSheet(initial: _current, onSave: onLogWeight),
    );
  }

  static String _formatShort(DateTime d, AppLocalizations l10n) {
    final now = clock.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return l10n.profileWeightCaptionToday;
    }
    return formatShortDate(d, l10n);
  }
}

/// BMI card: value, zone chip and the remaining body data.
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
    final bmiLabel = BmiZones.labelFor(bmi, l10n);
    final bmiColor = BmiZones.colorFor(t, bmi);

    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 10, 8, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.profileStudioBodyDetails,
                  style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
                ),
              ),
              _InfoButton(
                onTap: () => _showBmiInfoSheet(context, bmi),
                tooltip: l10n.profileBmiInfoTooltip,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 2),
                Semantics(
                  key: const ValueKey('profile-bmi-summary'),
                  label: 'BMI',
                  value: '${formatBmiDe(bmi, l10n)} · $bmiLabel',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 12,
                        runSpacing: 8,
                        children: <Widget>[
                          // Wrap, not Row: at 2x the number alone fills a
                          // small phone and "BMI" moves below it.
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.end,
                            spacing: 6,
                            children: <Widget>[
                              Text(
                                formatBmiDe(bmi, l10n),
                                style: AppType.display(
                                  40,
                                  weight: FontWeight.w700,
                                  color: t.ink,
                                  letterSpacing: -0.8,
                                  height: 1.05,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  'BMI',
                                  style: AppType.ui(
                                    13,
                                    weight: FontWeight.w600,
                                    color: t.ink3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          _ZonePill(label: bmiLabel, color: bmiColor),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _BmiScale(bmi: bmi),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Divider(height: 1, thickness: 1, color: t.line),
                const SizedBox(height: 16),
                // Wrap instead of Row: at large system font the facts stack
                // instead of overflowing the line.
                LayoutBuilder(
                  builder: (context, constraints) {
                    final facts = <Widget>[
                      _BodyFact(
                        label: l10n.goalsFieldHeight,
                        value: '${profile.heightCm} cm',
                      ),
                      _BodyFact(
                        label: l10n.goalsFieldAge,
                        value: l10n.profileAgeAbbreviation(profile.ageYears),
                      ),
                      _BodyFact(
                        label: l10n.goalsFieldSex,
                        value: profile.sex.label(l10n),
                      ),
                    ];
                    final fits =
                        constraints.maxWidth / 3 >=
                        MediaQuery.textScalerOf(context).scale(84);
                    if (!fits) {
                      return Wrap(
                        spacing: 24,
                        runSpacing: 12,
                        children: facts,
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (final fact in facts) Expanded(child: fact),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `isScrollControlled` because at 2x system font the four zone rows plus
  /// the explanation exceed the 9/16 screen height an uncontrolled sheet gets
  /// (measured 1087 px overflow). The content scrolls too, see [_BmiInfoSheet].
  static void _showBmiInfoSheet(BuildContext context, double bmi) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.t.bg,
      isScrollControlled: true,
      builder: (_) => _BmiInfoSheet(bmi: bmi),
    );
  }
}

class _BmiInfoSheet extends StatelessWidget {
  const _BmiInfoSheet({required this.bmi});

  /// The user's BMI; its zone row is highlighted.
  final double bmi;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final current = BmiZones.labelFor(bmi, l10n);
    // Name AND colour come from [BmiZones]; a second copy here is where
    // the legend would silently drift from the zone chip. The sample
    // values sit in the middle of their zone.
    final zones = <(String, String, Color)>[
      for (final z in <(double, String)>[
        (17.0, '< 18.5'),
        (22.0, '18.5 – 24.9'),
        (27.0, '25.0 – 29.9'),
        (32.0, '≥ 30.0'),
      ])
        (
          BmiZones.labelFor(z.$1, l10n),
          z.$2,
          BmiZones.colorFor(t, z.$1),
        ),
    ];
    // Handle stays pinned, the rest scrolls: at 2x system font the zone list
    // is taller than the screen.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Neither profile sheet has a close button: the handle carries the
        // screen-reader dismiss action.
        SheetHandle(
          padding: const EdgeInsets.symmetric(vertical: 11),
          onDismiss: () => Navigator.of(context).maybePop(),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                HeadingSemantics(
                  level: 1,
                  child: Text(
                    l10n.profileBmiInfoSheetTitle,
                    style: AppType.display(24, color: t.ink),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.profileBmiInfoSheetBody,
                  style: AppType.ui(13.5, color: t.ink2, height: 1.45),
                ),
                const SizedBox(height: 18),
                AppCard(
                  clip: true,
                  child: Column(
                    children: <Widget>[
                      for (var i = 0; i < zones.length; i++) ...<Widget>[
                        if (i > 0)
                          Divider(height: 1, thickness: 1, color: t.line),
                        _ZoneRow(
                          name: zones[i].$1,
                          range: zones[i].$2,
                          color: zones[i].$3,
                          current: zones[i].$1 == current,
                        ),
                      ],
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

/// One BMI zone in the guide: dot, name, range right-aligned; the user's own
/// zone sits on a raised fill.
class _ZoneRow extends StatelessWidget {
  const _ZoneRow({
    required this.name,
    required this.range,
    required this.color,
    required this.current,
  });

  final String name;
  final String range;
  final Color color;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      selected: current,
      child: Container(
        color: current ? t.surfRaised : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            // The range moves under the name at 200 % system font.
            Expanded(
              child: _SpreadRow(
                start: Text(
                  name,
                  style: AppType.ui(
                    14,
                    weight: current ? FontWeight.w700 : FontWeight.w600,
                    color: current ? t.ink : t.inkSoft,
                  ),
                ),
                end: Text(
                  range,
                  textAlign: TextAlign.right,
                  style: AppType.ui(
                    13,
                    weight: FontWeight.w600,
                    color: current ? t.ink : t.ink2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileWeightInputSheet extends StatefulWidget {
  const _ProfileWeightInputSheet({required this.initial, required this.onSave});

  final double initial;
  final PersistValueChanged<double> onSave;

  @override
  State<_ProfileWeightInputSheet> createState() =>
      _ProfileWeightInputSheetState();
}

class _ProfileWeightInputSheetState extends State<_ProfileWeightInputSheet> {
  // Created on the first dependency pass: "72,5" under de needs the locale,
  // which initState cannot read.
  TextEditingController? _field;
  TextEditingController get _controller => _field!;
  final FocusNode _focus = FocusNode();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _field ??= TextEditingController(
      text: formatKgDe(widget.initial, context.l10n),
    )..addListener(_onChanged);
  }

  @override
  void dispose() {
    _field?.removeListener(_onChanged);
    _field?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// The typed value, or null when it is not a number (or an ambiguous
  /// "1.000", which is 1 or 1000 kg).
  double? get _value => NumberInput.parse(_controller.text).value;

  /// Range check against the `weight_log` table (20..400 kg, F7-02). Before
  /// this, "7.55" (slipped decimal) went to log, cache and HealthKit, the
  /// server rejected it with 23514 and the value vanished on the next boot.
  bool get _valid {
    final v = _value;
    return v != null && isValidWeightLogKg(v);
  }

  /// Error text under the field; only once something is typed.
  String? _errorText(AppLocalizations l10n) {
    if (_controller.text.trim().isEmpty || _valid) return null;
    final hinweis = numberInputHint(NumberInput.parse(_controller.text), l10n);
    if (hinweis != null) return hinweis;
    return l10n.profileWeightInputRangeError(
      WeightLogLimits.weightKgMin.toInt(),
      WeightLogLimits.weightKgMax.toInt(),
    );
  }

  bool _saving = false;

  Future<void> _save() async {
    final v = _value;
    if (v == null || !isValidWeightLogKg(v) || _saving) return;
    setState(() => _saving = true);
    final saved = await tryPersistChange(context, () => widget.onSave(v));
    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => CommitDismissGuard(
    pending: _saving,
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final fehler = _errorText(l10n);
    final gesperrt = !_valid || _saving;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SheetHandle(
              padding: const EdgeInsets.symmetric(vertical: 11),
              onDismiss: () => Navigator.of(context).maybePop(),
            ),
            HeadingSemantics(
              level: 1,
              child: Text(
                l10n.profileLogWeightCta,
                style: AppType.display(24, color: t.ink),
              ),
            ),
            const SizedBox(height: 16),
            // Local TextField on a [FieldCapsule] (field / fieldFocus /
            // fieldError, shadow, no ring) instead of SheetField: the floating
            // `labelText` and the `kg` suffix are not part of its API.
            FieldCapsule(
              focusNode: _focus,
              error: fehler != null,
              padding: EdgeInsets.zero,
              child: TextField(
                key: const ValueKey('profile-weight-input'),
                cursorOpacityAnimates: false,
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onSubmitted: (_) => _save(),
                style: AppType.ui(16, weight: FontWeight.w600, color: t.ink),
                decoration: InputDecoration(
                  labelText: l10n.profileWeightInputLabel,
                  suffixText: 'kg',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
            ),
            if (fehler != null) ...<Widget>[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  fehler,
                  key: const ValueKey('profile-weight-error'),
                  style: AppType.ui(
                    11.5,
                    weight: FontWeight.w500,
                    color: t.danger,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Semantics(
              // Same pattern as the goals page: PrimaryActionButton cannot
              // express "disabled" itself.
              button: true,
              enabled: !gesperrt,
              child: Opacity(
                opacity: gesperrt ? 0.4 : 1,
                child: PrimaryActionButton(
                  key: const ValueKey('profile-weight-save'),
                  label: l10n.commonSave,
                  icon: Icons.check_rounded,
                  height: 50,
                  onTap: gesperrt ? null : _save,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The change since the first measurement, as the redesign's tinted pill
/// (accent tint with accent text, like "58% eaten"). The flat state stays
/// quiet on `tile`.
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
    final fg = isFlat ? t.ink2 : t.accentText;
    return Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: isFlat ? t.tile : t.accentTint,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: fg, size: 15),
          const SizedBox(width: 5),
          Text(
            label,
            style: AppType.ui(13, weight: FontWeight.w700, color: fg),
          ),
        ],
      ),
    );
  }
}

/// The weight line on a quiet grid: three hairlines with the range's top and
/// bottom value on the right, a soft accent fill under the line, and the
/// shared [Sparkline] on top.
class _WeightChart extends StatelessWidget {
  const _WeightChart({required this.values});

  final List<double> values;

  static const double _height = 116;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final axis = AppType.ui(11, weight: FontWeight.w500, color: t.ink3);
    return SizedBox(
      height: _height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: RepaintBoundary(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _WeightAreaPainter(
                        values: values,
                        grid: t.lineStrong,
                        fill: t.accent,
                      ),
                    ),
                  ),
                  Sparkline(values: values, height: _height),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Top and bottom of the drawn range; the line's pad is 6 px.
          ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(formatKgDe(maxV, l10n), style: axis),
                Text(formatKgDe(minV, l10n), style: axis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Grid and area under the weight line. Uses [Sparkline]'s exact mapping
/// (6 px inset, min..max range) so the fill meets the line it sits under.
class _WeightAreaPainter extends CustomPainter {
  _WeightAreaPainter({
    required this.values,
    required this.grid,
    required this.fill,
  });

  final List<double> values;
  final Color grid, fill;

  static const double _pad = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final f in const <double>[0, 0.5, 1]) {
      final y = _pad + (size.height - _pad * 2) * f;
      for (double x = 0; x < size.width; x += 6) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), gridPaint);
      }
    }
    if (values.length < 2) return;
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    if (!minV.isFinite || !maxV.isFinite) return;
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : maxV - minV;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = _pad + (size.width - _pad * 2) * (i / (values.length - 1));
      final y =
          _pad + (size.height - _pad * 2) * (1 - (values[i] - minV) / range);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    path
      ..lineTo(size.width - _pad, size.height)
      ..lineTo(_pad, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            fill.withValues(alpha: 0.22),
            fill.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_WeightAreaPainter old) =>
      old.grid != grid || old.fill != fill || !listEquals(old.values, values);
}

/// The BMI zone as a tinted capsule with its dot.
class _ZonePill extends StatelessWidget {
  const _ZonePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              style: AppType.ui(
                13,
                weight: FontWeight.w700,
                color: t.readableOnTint(color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The four BMI zones as one segmented track (15–35) with a marker at the
/// user's value and the zone limits underneath. Visual only: the summary
/// node above it reads value and zone aloud.
class _BmiScale extends StatelessWidget {
  const _BmiScale({required this.bmi});

  final double bmi;

  static const double _min = 15, _max = 35;
  static const List<double> _limits = <double>[18.5, 25, 30];

  /// Zone color of [segment]; full for the user's zone, faded otherwise.
  static Color _tone(
    AppTokens t,
    AppLocalizations l10n,
    (double, double) segment,
    String active,
  ) {
    final mid = (segment.$1 + segment.$2) / 2;
    final color = BmiZones.colorFor(t, mid);
    return BmiZones.labelFor(mid, l10n) == active
        ? color
        : color.withValues(alpha: 0.3);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final segments = <(double, double)>[
      (_min, 18.5),
      (18.5, 25),
      (25, 30),
      (30, _max),
    ];
    final active = BmiZones.labelFor(bmi, l10n);
    final tick = AppType.ui(11, weight: FontWeight.w500, color: t.ink3);
    final tickHeight = MediaQuery.textScalerOf(context).scale(11) * 1.4;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        double xOf(double v) => (v - _min) / (_max - _min) * w;
        final marker = bmi.isFinite
            ? xOf(bmi.clamp(_min, _max).toDouble())
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 16,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 5,
                    height: 6,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (var i = 0; i < segments.length; i++) ...<Widget>[
                          if (i > 0) const SizedBox(width: 3),
                          Expanded(
                            flex: ((segments[i].$2 - segments[i].$1) * 10)
                                .round(),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: _tone(t, l10n, segments[i], active),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (marker != null)
                    Positioned(
                      left: (marker - 8).clamp(-2, w - 14).toDouble(),
                      top: 0,
                      width: 16,
                      height: 16,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: t.ink,
                          shape: BoxShape.circle,
                          border: Border.all(color: t.surf, width: 3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: tickHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  for (final limit in _limits)
                    Positioned(
                      left: xOf(limit),
                      top: 0,
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, 0),
                        child: Text(formatKgDe(limit, l10n), style: tick),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One body fact: small caps label over the value.
class _BodyFact extends StatelessWidget {
  const _BodyFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label.toUpperCase(), style: AppType.eyebrow(t.ink2, size: 10.5)),
        const SizedBox(height: 5),
        Text(
          value,
          style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
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
              child: Icon(Icons.info_outline_rounded, color: t.ink2, size: 15),
            ),
          ),
        ),
      ),
    );
  }
}
