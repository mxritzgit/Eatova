import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/training_history.dart';
import '../../models/training_insights.dart';
import '../../models/training_session.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import 'training_actual_fields.dart' show formatTrainingWeight;

// In-tab building blocks of the redesigned Training root (dark redesign
// 2026-09-28). They only render values the store derived
// (`models/training_insights.dart`); none of them computes a training rule.

/// Figtree's natural line height, the design's CSS `normal` (the theme's
/// default since the final wave; kept explicit for the measured rows).
const double kTrainingLine = AppType.normalHeight;

/// Text scaler for the 30 px card headings: they are large text already and
/// grow to 42 px, so a long single word ("Oberkörper") still fits the card
/// on a 320 px phone instead of breaking mid-word.
TextScaler trainingHeadingScaler(BuildContext context) =>
    MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.4);

/// The workout card's surface: a hero card with an accent hairline and a
/// violet glow in its top right corner. A [Material], so rows ripple on it.
class TrainingHeroCard extends StatelessWidget {
  const TrainingHeroCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surf,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rHero),
        side: BorderSide(color: t.accent.withValues(alpha: 0.18)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -90,
            top: -120,
            width: 300,
            height: 300,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      t.arcStart.withValues(alpha: 0.3),
                      t.arcStart.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// A calm list card (1 px border) that ripples its rows.
class _InkCard extends StatelessWidget {
  const _InkCard({required this.child, required this.padding});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surf,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.cardBorder),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// "This week": the finished workouts per local day (Monday to Sunday), the
/// today highlight and the "done of planned" count. Plans carry no weekday
/// schedule, so a day never claims a planned type or a rest day.
class TrainingWeekCard extends StatelessWidget {
  const TrainingWeekCard({super.key, required this.week});

  final TrainingWeek week;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final dates = DateFormat.MMMd(l10n.localeName);
    final range = '${dates.format(week.start)} – ${dates.format(week.end)}';
    final planned = week.plannedSessions;
    final count = planned == null
        ? '${week.doneSessions}'
        : l10n.trainingWeekDoneOf(week.doneSessions, planned);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 12,
              runSpacing: 2,
              children: [
                HeadingSemantics(
                  level: 2,
                  child: Text(
                    l10n.trainingWeekTitle,
                    style: AppType.ui(
                      15,
                      weight: FontWeight.w700,
                      color: t.ink,
                      height: kTrainingLine,
                    ),
                  ),
                ),
                Text.rich(
                  key: const ValueKey('training-week-summary'),
                  TextSpan(
                    children: [
                      TextSpan(
                        text: count,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: t.ink,
                        ),
                      ),
                      TextSpan(text: ' ${l10n.trainingWeekDone} · $range'),
                    ],
                  ),
                  style: AppType.ui(13, color: t.ink2, height: kTrainingLine),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < week.days.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(child: _WeekDayCell(day: week.days[i])),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _WeekDayCell extends StatelessWidget {
  const _WeekDayCell({required this.day});

  final TrainingWeekDay day;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final locale = l10n.localeName;
    // Two letters like the design ("Mo", "Tu"; German "Mo." without dot).
    final short = DateFormat(null, locale)
        .dateSymbols
        .SHORTWEEKDAYS[day.date.weekday % 7]
        .replaceAll('.', '')
        .characters
        .take(2)
        .toString();
    final today = day.isToday;
    final label = [
      DateFormat.MMMMEEEEd(locale).format(day.date),
      if (today) l10n.trainingWeekDayToday,
      day.done ? l10n.trainingWeekDayDone : l10n.trainingWeekDayOpen,
    ].join(', ');
    final marker = day.done
        ? DecoratedBox(
            key: ValueKey('training-week-done-${day.date.weekday}'),
            decoration: BoxDecoration(
              color: t.accentFill,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: t.accentGlow.withValues(alpha: 0.45),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: SizedBox.square(
              dimension: 34,
              child: Center(
                child: AppIcon(
                  AppSymbol.training,
                  size: 18,
                  color: t.onAccentFill,
                ),
              ),
            ),
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: t.surfRaised,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(
              dimension: 34,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: today ? t.accentText : t.inkFaint,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 6),
                ),
              ),
            ),
          );
    return Semantics(
      key: ValueKey('training-week-day-${day.date.weekday}'),
      container: true,
      selected: today,
      label: label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: today
            ? BoxDecoration(
                color: t.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
              )
            : null,
        child: Column(
          children: [
            Text(
              short,
              maxLines: 1,
              style: AppType.ui(
                12,
                weight: today ? FontWeight.w700 : FontWeight.w600,
                color: today ? t.accentText : t.ink3,
                height: kTrainingLine,
              ),
            ),
            const SizedBox(height: 6),
            marker,
            const SizedBox(height: 6),
            Text(
              '${day.date.day}',
              maxLines: 1,
              style: AppType.ui(
                11,
                weight: today ? FontWeight.w800 : FontWeight.w600,
                color: today
                    ? t.accentText
                    : day.done
                    ? t.inkMuted
                    : t.ink3,
                height: kTrainingLine,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One meta item of the workout card ("6 exercises", "≈ 50 min").
class TrainingMetaItem extends StatelessWidget {
  const TrainingMetaItem({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: t.ink2),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            style: AppType.ui(
              13,
              weight: FontWeight.w600,
              color: t.ink2,
              height: kTrainingLine,
            ),
          ),
        ),
      ],
    );
  }
}

/// "Last time 75 kg × 8" for the best set of the last session, or null
/// (never trained, or a timed set without repetitions).
String? trainingLastTimeText(AppLocalizations l10n, TrainingSetActual? set) {
  final reps = set?.reps;
  if (set == null || reps == null) return null;
  final weight = set.weightKg;
  return weight == null || weight <= 0
      ? l10n.trainingLastTimeReps(reps)
      : l10n.trainingLastTimeWeight(formatTrainingWeight(weight, l10n), reps);
}

/// The workout card's exercise list: the first three rows with "Last time"
/// and the prescription, then the remaining names. A row reveals its rest and
/// notes on tap; the names line shows every row.
class TrainingExerciseRows extends StatefulWidget {
  const TrainingExerciseRows({super.key, required this.exercises});

  final List<TrainingExercisePreview> exercises;

  @override
  State<TrainingExerciseRows> createState() => _TrainingExerciseRowsState();
}

class _TrainingExerciseRowsState extends State<TrainingExerciseRows> {
  final Set<int> _expanded = {};
  bool _all = false;

  static List<String?> _ids(List<TrainingExercisePreview> exercises) => [
    for (final preview in exercises) preview.exercise.id,
  ];

  @override
  void didUpdateWidget(covariant TrainingExerciseRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The store allocates a new preview list per build; only another set of
    // exercises resets what the user opened.
    final before = _ids(oldWidget.exercises);
    final after = _ids(widget.exercises);
    if (before.length != after.length ||
        [
          for (var i = 0; i < after.length; i++) before[i] == after[i],
        ].contains(false)) {
      _expanded.clear();
      _all = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final exercises = widget.exercises;
    final visible = _all ? exercises.length : math.min(3, exercises.length);
    final divider = BoxDecoration(
      border: Border(top: BorderSide(color: t.cardBorder)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < visible; i++)
          DecoratedBox(decoration: divider, child: _row(context, i)),
        if (exercises.length > 3)
          DecoratedBox(
            decoration: divider,
            child: Semantics(
              button: true,
              label: _all
                  ? l10n.trainingStudioLessExercises
                  : l10n.trainingStudioAllExercises(exercises.length),
              child: InkWell(
                key: const ValueKey('training-all-exercises'),
                onTap: () => setState(() => _all = !_all),
                child: ExcludeSemantics(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(40, 9, 0, 9),
                      child: Text(
                        _all
                            ? l10n.trainingStudioLessExercises
                            : l10n.trainingMoreExercises(
                                exercises
                                    .skip(3)
                                    .map((preview) => preview.exercise.name)
                                    .join(', '),
                              ),
                        style: AppType.ui(13, color: t.ink3, height: 1.35),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, int i) {
    final t = context.t;
    final l10n = context.l10n;
    final preview = widget.exercises[i];
    final exercise = preview.exercise;
    final timed = exercise.isTimed;
    final prescription = timed
        ? l10n.trainingPageSetsTime(exercise.sets, exercise.durationSeconds!)
        : l10n.trainingSetsRepsShort(exercise.sets, exercise.reps!);
    final spoken = timed
        ? prescription
        : l10n.trainingPageSetsReps(exercise.sets, exercise.reps!);
    final last = trainingLastTimeText(l10n, preview.lastTopSet);
    final expanded = _expanded.contains(i);
    // From 1.5x text the prescription moves under the name.
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    final prescriptionText = Text(
      prescription,
      textAlign: large ? TextAlign.start : TextAlign.end,
      style: AppType.ui(
        14,
        weight: FontWeight.w700,
        color: t.inkMuted,
        height: kTrainingLine,
      ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          label: ['${i + 1}. ${exercise.name}', spoken, ?last].join(', '),
          child: InkWell(
            key: ValueKey('training-exercise-$i'),
            onTap: () => setState(() {
              expanded ? _expanded.remove(i) : _expanded.add(i);
            }),
            child: ExcludeSemantics(
              child: Container(
                // A row without "Last time" still is a 44 px target.
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(vertical: 9),
                alignment: AlignmentDirectional.centerStart,
                child: Row(
                  children: [
                    Container(
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: t.surf2,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        '${i + 1}',
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w800,
                          color: t.ink2,
                          height: kTrainingLine,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            exercise.name,
                            style: AppType.ui(
                              15,
                              weight: FontWeight.w700,
                              color: t.ink,
                              height: kTrainingLine,
                            ),
                          ),
                          if (last != null) ...[
                            const SizedBox(height: 1),
                            Text(
                              last,
                              style: AppType.ui(
                                12,
                                color: t.ink3,
                                height: kTrainingLine,
                              ),
                            ),
                          ],
                          if (large) ...[
                            const SizedBox(height: 2),
                            prescriptionText,
                          ],
                        ],
                      ),
                    ),
                    if (!large) ...[
                      const SizedBox(width: 8),
                      // Long localized prescriptions wrap instead of pushing
                      // the name out of the row.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: prescriptionText,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        maybeAnimatedSize(
          context,
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(40, 0, 0, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.trainingPageRestSeconds(exercise.restSeconds),
                        style: AppType.ui(
                          12,
                          weight: FontWeight.w600,
                          color: t.accentText,
                          height: kTrainingLine,
                        ),
                      ),
                      if (exercise.notes.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          exercise.notes,
                          style: AppType.ui(13, color: t.ink2, height: 1.45),
                        ),
                      ],
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// The round secondary action next to "Start workout" (54 px).
class TrainingRoundButton extends StatelessWidget {
  const TrainingRoundButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  /// Shows a spinner instead of the glyph (e.g. while a plan is deleted).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      child: PressScale(
        enabled: onTap != null,
        child: Material(
          color: t.surf2,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox.square(
              dimension: 54,
              child: Center(
                child: busy
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: t.accent,
                        ),
                      )
                    : Icon(icon, size: 20, color: t.inkMuted),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One tile of the "Quick start" grid: icon tile plus label, 64 px high.
class TrainingQuickTile extends StatelessWidget {
  const TrainingQuickTile({
    super.key,
    required this.icon,
    required this.label,
    required this.tint,
    required this.ink,
    required this.onTap,
    this.semanticLabel,
  });

  /// An [Icon] or [AppIcon]; it inherits size and color.
  final Widget icon;
  final String label;
  final Color tint;
  final Color ink;
  final VoidCallback onTap;

  /// Spoken instead of the short visible [label], when that needs context.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      container: true,
      button: true,
      label: semanticLabel ?? label,
      child: PressScale(
        child: Material(
          color: t.surf,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rTile),
            side: BorderSide(color: t.cardBorder),
          ),
          child: InkWell(
            onTap: onTap,
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: tint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconTheme(
                          data: IconThemeData(size: 20, color: ink),
                          child: Center(child: icon),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          style: AppType.ui(
                            14,
                            weight: FontWeight.w700,
                            color: t.ink,
                            height: kTrainingLine,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays [tiles] out two per row like the design, one per row when a label
/// would have to break inside a word (narrow phones, large text). An odd last
/// tile takes the whole row.
class TrainingQuickGrid extends StatelessWidget {
  const TrainingQuickGrid({super.key, required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final font = MediaQuery.textScalerOf(context).scale(14);
        // Tile padding 2 × 12, icon tile 38, gap 10.
        final labelWidth = (constraints.maxWidth - 10) / 2 - 72;
        final columns = labelWidth >= font * 4.5 ? 2 : 1;
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += columns) {
          if (rows.isNotEmpty) rows.add(const SizedBox(height: 10));
          final pair = columns == 2 && i + 1 < tiles.length;
          rows.add(
            pair
                ? IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: tiles[i]),
                        const SizedBox(width: 10),
                        Expanded(child: tiles[i + 1]),
                      ],
                    ),
                  )
                : tiles[i],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

/// "Weekly volume": tonnes of the last full week, its change against the
/// week before, and bars for five full weeks plus the current one.
class TrainingVolumeCard extends StatelessWidget {
  const TrainingVolumeCard({super.key, required this.trend});

  final TrainingVolumeTrend trend;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final locale = l10n.localeName;
    final tonnes = NumberFormat('0.0', locale);
    final weeks = trend.weeks;
    final highest = weeks.fold<double>(
      0,
      (max, week) => math.max(max, week.volumeKg),
    );
    final lastFull = trend.lastFullWeek;
    final change = trend.changePercent?.round();
    final title = HeadingSemantics(
      level: 2,
      child: Text(
        l10n.trainingVolumeTitle,
        style: AppType.ui(
          13,
          weight: FontWeight.w700,
          color: t.ink2,
          height: kTrainingLine,
        ),
      ),
    );
    if (highest <= 0 || lastFull == null) {
      return AppCard(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            title,
            const SizedBox(height: 6),
            Text(
              l10n.trainingVolumeEmpty,
              key: const ValueKey('training-volume-empty'),
              style: AppType.ui(14, color: t.ink2, height: 1.45),
            ),
          ],
        ),
      );
    }
    final dates = DateFormat.MMMd(locale);
    final highlight = weeks.length - 2;
    final spoken = [
      for (final week in weeks)
        week.isCurrent
            ? l10n.trainingVolumeCurrentSemantics(tonnes.format(week.tonnes))
            : l10n.trainingVolumeWeekSemantics(
                dates.format(week.start),
                tonnes.format(week.tonnes),
              ),
    ].join('. ');
    // The value label sits in the 124 px chart; it may grow, not overflow.
    final chartScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.3);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          const SizedBox(height: 2),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 4,
            children: [
              CountingText(
                value: lastFull.tonnes,
                format: tonnes.format,
                textKey: const ValueKey('training-volume-value'),
                style: AppType.display(
                  30,
                  color: t.ink,
                  letterSpacing: -0.6,
                  height: 1.1,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l10n.trainingVolumeLastWeek,
                  style: AppType.ui(
                    15,
                    weight: FontWeight.w600,
                    color: t.ink2,
                    height: kTrainingLine,
                  ),
                ),
              ),
            ],
          ),
          if (change != null) ...[
            const SizedBox(height: 2),
            Text(
              change > 0
                  ? l10n.trainingVolumeUp(change)
                  : change < 0
                  ? l10n.trainingVolumeDown(-change)
                  : l10n.trainingVolumeSame,
              key: const ValueKey('training-volume-change'),
              style: AppType.ui(13, color: t.ink3, height: kTrainingLine),
            ),
          ],
          const SizedBox(height: 16),
          Semantics(
            key: const ValueKey('training-volume-chart'),
            container: true,
            label: spoken,
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 124,
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: t.lineStrong)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < weeks.length; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (i == highlight) ...[
                                  Text(
                                    tonnes.format(weeks[i].tonnes),
                                    maxLines: 1,
                                    softWrap: false,
                                    textScaler: chartScaler,
                                    style: AppType.ui(
                                      12,
                                      weight: FontWeight.w800,
                                      color: t.ink,
                                      height: kTrainingLine,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                ],
                                // Grows in on first display and moves to
                                // a new height when a workout lands.
                                TweenAnimationBuilder<double>(
                                  tween: Tween<double>(
                                    begin: 0,
                                    end: math.max(
                                      4,
                                      96 * weeks[i].volumeKg / highest,
                                    ),
                                  ),
                                  duration: motionDuration(
                                    context,
                                    kMotionValue,
                                  ),
                                  curve: kMotionCurve,
                                  builder: (context, height, _) => Container(
                                    key: ValueKey('training-volume-bar-$i'),
                                    height: height,
                                    decoration: BoxDecoration(
                                      color: i == highlight
                                          ? t.accentFill
                                          : t.chartViolet,
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(4),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < weeks.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            weeks[i].isCurrent
                                ? l10n.trainingVolumeNow
                                : dates.format(weeks[i].start),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            style: AppType.ui(
                              11,
                              weight: i == highlight
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: i == highlight ? t.inkMuted : t.ink3,
                              height: kTrainingLine,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Recent": the newest workouts with date, duration and PR badge; a row
/// opens that workout, "All workouts" the history.
class TrainingRecentSection extends StatelessWidget {
  const TrainingRecentSection({
    super.key,
    required this.workouts,
    this.onOpen,
    this.onOpenAll,
  });

  final List<TrainingWorkoutSummary> workouts;
  final ValueChanged<TrainingHistoryEntry>? onOpen;
  final VoidCallback? onOpenAll;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: HeadingSemantics(
                  level: 2,
                  child: Text(
                    l10n.trainingRecentTitle,
                    style: AppType.display(
                      20,
                      weight: FontWeight.w700,
                      color: t.ink,
                      letterSpacing: -0.2,
                      height: kTrainingLine,
                    ),
                  ),
                ),
              ),
            ),
            if (onOpenAll != null)
              Flexible(
                // Flexible keeps the title safe on narrow phones; Align
                // pins the link to the right edge of its share.
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const ValueKey('training-recent-all'),
                    onPressed: onOpenAll,
                    style: TextButton.styleFrom(
                      foregroundColor: t.accentText,
                      minimumSize: const Size(44, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      textStyle: AppType.ui(
                        14,
                        weight: FontWeight.w700,
                        height: kTrainingLine,
                      ),
                    ),
                    child: Text(l10n.trainingRecentAll),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        _InkCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < workouts.length; i++) ...[
                if (i > 0)
                  Divider(height: 1, thickness: 1, color: t.cardBorder),
                _RecentRow(summary: workouts[i], onOpen: onOpen),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.summary, this.onOpen});

  final TrainingWorkoutSummary summary;
  final ValueChanged<TrainingHistoryEntry>? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final date = DateFormat.MMMEd(
      l10n.localeName,
    ).format(summary.finishedAt.toLocal());
    final minutes = (summary.duration.inSeconds / 60).round();
    final meta = '$date · ${l10n.trainingDurationMinutes(minutes)}';
    final records = summary.personalRecords;
    final badge = records > 0 ? l10n.trainingRecentPrs(records) : null;
    // A stable hue per workout of the plan; it encodes no workout type.
    final (tint, ink) = switch (summary.entry.snapshot.workoutIndex % 3) {
      0 => (t.accentTintStrong, t.accentText),
      1 => (t.carbsSurface, t.carbsInk),
      _ => (t.proteinSurface, t.proteinInk),
    };
    final open = onOpen;
    return Semantics(
      container: true,
      button: open != null,
      label: [summary.title, meta, ?badge].join(', '),
      child: InkWell(
        key: ValueKey('training-recent-${summary.entry.id}'),
        onTap: open == null ? null : () => open(summary.entry),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: tint,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: AppIcon(AppSymbol.training, size: 22, color: ink),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          16,
                          weight: FontWeight.w700,
                          color: t.ink,
                          height: kTrainingLine,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        style: AppType.ui(
                          13,
                          color: t.ink3,
                          height: kTrainingLine,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (badge != null)
                  Container(
                    key: ValueKey('training-recent-pr-${summary.entry.id}'),
                    constraints: const BoxConstraints(
                      minHeight: 28,
                      maxWidth: 120,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: t.fatSurface,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.emoji_events_outlined,
                          size: 14,
                          color: t.fatInk,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            badge,
                            style: AppType.ui(
                              12,
                              weight: FontWeight.w800,
                              color: t.fatInk,
                              height: kTrainingLine,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Icon(Icons.chevron_right_rounded, size: 22, color: t.ink3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
