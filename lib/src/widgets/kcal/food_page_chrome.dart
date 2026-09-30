import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/day_nutrition.dart';
import '../../services/day_math.dart';
import '../../services/kcal_format.dart';
import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'food_glyphs.dart';

// ---------------------------------------------------------------------------
// Food tab chrome (dark redesign, 2026-09-28): the title row with the
// calendar button, the day switcher pill, the day summary card and the
// floating capture dock. Values follow `design/food/template.html`.
// ---------------------------------------------------------------------------

/// Design text at Figtree's normal line height (the theme's default too).
TextStyle foodText(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color? color,
  double? letterSpacing,
}) => AppType.ui(
  size,
  weight: weight,
  color: color,
  letterSpacing: letterSpacing,
  height: AppType.normalHeight,
);

/// "Food" title and the round calendar button that opens the date picker.
class FoodPageHeader extends StatelessWidget {
  const FoodPageHeader({super.key, required this.onCalendar});

  final VoidCallback onCalendar;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: HeadingSemantics(
            level: 1,
            child: Text(
              l10n.navFood,
              style: AppType.pageTitle(t.ink),
              textScaler: AppType.pageTitleScaler(context),
            ),
          ),
        ),
        const SizedBox(width: 12),
        HeaderIconButton.custom(
          key: const ValueKey('food-date-calendar'),
          semanticLabel: l10n.foodCalendarButtonSemantics,
          onTap: onCalendar,
          child: const FoodGlyphIcon(FoodGlyph.calendar),
        ),
      ],
    );
  }
}

/// The day switcher pill: previous/next day around the selected day's name
/// ([headline], e.g. "Today") and date ([dateLabel]). Future days and days
/// more than two years back are unavailable.
class FoodDayNavigation extends StatelessWidget {
  const FoodDayNavigation({
    super.key,
    required this.day,
    required this.headline,
    required this.dateLabel,
    required this.onSelected,
  });

  final DateTime day;
  final String headline;
  final String dateLabel;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final today = DateUtils.dateOnly(clock.now());
    final first = DateTime(today.year - 2, today.month, today.day);
    Widget arrow(String key, FoodGlyph glyph, String tooltip, DateTime? to) =>
        IconButton(
          key: ValueKey(key),
          style: IconButton.styleFrom(
            minimumSize: const Size.square(44),
            fixedSize: const Size.square(44),
            // 44 px is the design's target; no extra 48 px padding.
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: t.inkMuted,
            disabledForegroundColor: t.inkDisabled,
          ),
          tooltip: tooltip,
          onPressed: to == null ? null : () => onSelected(to),
          icon: FoodGlyphIcon(glyph, size: 20),
        );
    return Container(
      key: const ValueKey('food-date-strip'),
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rPill),
        border: Border.all(color: t.cardBorder),
      ),
      child: Row(
        children: [
          arrow(
            'food-date-previous',
            FoodGlyph.chevronLeft,
            l10n.todaySemanticsDatePrev,
            day.isAfter(first) ? addDays(day, -1) : null,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline,
                  key: const ValueKey('food-date-headline'),
                  textAlign: TextAlign.center,
                  style: foodText(15, weight: FontWeight.w800, color: t.ink),
                ),
                const SizedBox(height: 1),
                Text(
                  dateLabel,
                  key: const ValueKey('food-date-selected-label'),
                  textAlign: TextAlign.center,
                  style: foodText(12, weight: FontWeight.w600, color: t.ink3),
                ),
              ],
            ),
          ),
          arrow(
            'food-date-next',
            FoodGlyph.chevronRight,
            l10n.todaySemanticsDateNext,
            day.isBefore(today) ? addDays(day, 1) : null,
          ),
        ],
      ),
    );
  }
}

/// The day summary: "LOGGED 1,221 kcal", "LEFT 902 kcal", the stacked macro
/// bar (share of kcal from protein, carbs and fat) and its legend in grams.
///
/// Numbers come from [DayNutritionSummary] (budget incl. activity credit), so
/// "left" matches the Today tab. Tapping the card opens Trends, as the old
/// kcal tile did.
class FoodDaySummaryCard extends StatelessWidget {
  const FoodDaySummaryCard({
    super.key,
    required this.summary,
    required this.loading,
    required this.onTap,
  });

  final DayNutritionSummary summary;

  /// An archive day is still loading: no numbers, no bar.
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final locale = l10n.localeName;
    final remaining = summary.remainingKcal;
    final over = remaining < 0;
    // Loading shows a dash; loaded numbers count to their value ("left"
    // down from the budget, like the Today tab).
    Widget number(Key key, int value, TextStyle style, int from) => loading
        ? Text('—', key: key, style: style)
        : CountingText(
            value: value.toDouble(),
            from: from.toDouble(),
            format: (v) => formatThousands(v.round(), locale),
            textKey: key,
            style: style,
          );
    Text eyebrow(String text) => Text(
      text.toUpperCase(),
      semanticsLabel: text,
      style: foodText(
        12,
        weight: FontWeight.w700,
        color: t.ink2,
        letterSpacing: 12 * 0.08,
      ),
    );
    // Number and unit stay separate texts (flows read the number alone);
    // very large text scales the pair down instead of overflowing.
    Widget amount(
      Key key,
      int value,
      int from,
      TextStyle style,
      double unitSize,
      double gap,
      Alignment alignment,
    ) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          number(key, value, style, from),
          SizedBox(width: gap),
          Text(
            'kcal',
            style: foodText(unitSize, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
    );
    final logged = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        eyebrow(l10n.foodSummaryLogged),
        const SizedBox(height: 2),
        amount(
          const ValueKey('food-day-total'),
          summary.consumedKcal,
          0,
          AppType.display(40, color: t.ink, height: 1),
          15,
          6,
          Alignment.centerLeft,
        ),
      ],
    );
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        eyebrow(over ? l10n.foodSummaryOver : l10n.foodSummaryLeft),
        const SizedBox(height: 2),
        amount(
          const ValueKey('food-day-left'),
          remaining.abs(),
          over ? 0 : summary.budgetKcal,
          AppType.display(
            26,
            weight: FontWeight.w700,
            color: over ? t.warning : t.accentText,
            letterSpacing: 26 * -0.02,
            height: 1,
          ),
          13,
          4,
          Alignment.centerRight,
        ),
      ],
    );
    final consumed = summary.consumed;
    final macros = <(String, double, Color)>[
      (l10n.todayMacroProtein, consumed.proteinG, t.protein),
      (l10n.todayMacroCarbs, consumed.carbsG, t.carbs),
      (l10n.todayMacroFat, consumed.fatG, t.fat),
    ];
    return PressScale(
      scale: kPressScaleCard,
      child: Material(
        color: t.surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rCard),
          side: BorderSide(color: t.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          button: true,
          hint: l10n.foodSemanticsTrends,
          child: InkWell(
            key: const ValueKey('topbar-trends'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // Large text or a narrow card stacks the two figures.
                      if (constraints.maxWidth < 280 ||
                          MediaQuery.textScalerOf(context).scale(14) > 19) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            logged,
                            const SizedBox(height: 12),
                            Align(alignment: Alignment.centerLeft, child: left),
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(child: logged),
                          const SizedBox(width: 12),
                          left,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  FoodMacroBar(
                    proteinKcal: loading ? 0 : consumed.proteinG * 4,
                    carbsKcal: loading ? 0 : consumed.carbsG * 4,
                    fatKcal: loading ? 0 : consumed.fatG * 9,
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final (label, grams, color) in macros)
                        _LegendItem(
                          label: label,
                          value: loading ? '—' : '${grams.round()} g',
                          color: color,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The stacked 10 px macro bar: one segment per macro, sized by its kcal,
/// 2 px apart; an empty day shows the bare track.
class FoodMacroBar extends StatelessWidget {
  const FoodMacroBar({
    super.key,
    required this.proteinKcal,
    required this.carbsKcal,
    required this.fatKcal,
  });

  final double proteinKcal, carbsKcal, fatKcal;

  @override
  Widget build(BuildContext context) {
    final target = (proteinKcal, carbsKcal, fatKcal);
    // A logged meal shifts the split instead of snapping it; the first
    // build starts at rest (begin == end).
    return TweenAnimationBuilder<(double, double, double)>(
      tween: _MacroSplitTween(begin: target, end: target),
      duration: motionDuration(context, kMotionValue),
      curve: kMotionCurve,
      builder: (context, split, _) => _bar(context, split),
    );
  }

  Widget _bar(BuildContext context, (double, double, double) split) {
    final t = context.t;
    final segments = <(double, Color, String)>[
      (split.$1, t.protein, 'protein'),
      (split.$2, t.carbs, 'carbs'),
      (split.$3, t.fat, 'fat'),
    ].where((s) => s.$1 > 0).toList();
    final total = segments.fold<double>(0, (sum, s) => sum + s.$1);
    return ExcludeSemantics(
      child: ClipRRect(
        key: const ValueKey('food-macro-bar'),
        borderRadius: BorderRadius.circular(rPill),
        child: SizedBox(
          height: 10,
          child: segments.isEmpty
              ? ColoredBox(color: t.tile, child: const SizedBox.expand())
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < segments.length; i++) ...[
                      if (i > 0) const SizedBox(width: 2),
                      Expanded(
                        // Integer flex; 1000 steps keep small shares visible.
                        flex: (segments[i].$1 / total * 1000).round().clamp(
                          1,
                          1000,
                        ),
                        child: ColoredBox(
                          key: ValueKey('food-macro-bar-${segments[i].$3}'),
                          color: segments[i].$2,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _MacroSplitTween extends Tween<(double, double, double)> {
  _MacroSplitTween({super.begin, super.end});

  @override
  (double, double, double) lerp(double t) {
    final (a1, a2, a3) = begin!;
    final (b1, b2, b3) = end!;
    return (a1 + (b1 - a1) * t, a2 + (b2 - a2) * t, a3 + (b3 - a3) * t);
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label, value;
  final Color color;

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
        const SizedBox(width: 6),
        // Large text wraps the label inside its run instead of overflowing.
        Flexible(child: Text(label, style: foodText(13, color: t.ink2))),
        const SizedBox(width: 6),
        Text(
          value,
          style: foodText(
            13,
            weight: FontWeight.w700,
            color: t.ink,
          ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

/// The floating capture dock above the tab bar: a search capsule that opens
/// the search sheet (long-press: manual entry), a round barcode button and
/// the accent camera button for the AI scan.
class FoodEntryDock extends StatelessWidget {
  const FoodEntryDock({
    super.key,
    required this.onSearch,
    required this.onCamera,
    required this.onBarcode,
    required this.onManual,
    this.enabled = true,
  });

  /// Height of the dock's controls (design: 54).
  static const double height = 54;

  final VoidCallback onSearch, onCamera, onBarcode, onManual;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    const radius = BorderRadius.all(Radius.circular(rPill));
    // An input look without an input: borderless soft capsule (standing
    // input rule), the search itself lives in the sheet.
    final search = PressScale(
      enabled: enabled,
      scale: kPressScaleCard,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: raisedShadow(t),
        ),
        child: Material(
          color: t.field,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: l10n.foodDockSearchLabel,
            onLongPressHint: l10n.foodManualEntryCta,
            child: InkWell(
              key: const ValueKey('food-search'),
              onTap: enabled ? onSearch : null,
              onLongPress: enabled ? onManual : null,
              child: SizedBox(
                height: height,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      FoodGlyphIcon(FoodGlyph.search, size: 20, color: t.ink2),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ExcludeSemantics(
                          child: Text(
                            l10n.foodDockSearchLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: foodText(16, color: t.ink2),
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
    return Row(
      key: const ValueKey('food-entry-dock'),
      children: [
        Expanded(child: search),
        const SizedBox(width: 8),
        _RoundDockButton(
          actionKey: const ValueKey('food-action-barcode'),
          label: l10n.foodScanBarcodeTooltip,
          glyph: FoodGlyph.barcode,
          fill: t.surfRaised,
          ink: t.inkSoft,
          border: t.lineStrong,
          shadow: raisedShadow(t),
          onTap: enabled ? onBarcode : null,
        ),
        const SizedBox(width: 8),
        _RoundDockButton(
          actionKey: const ValueKey('food-action-ai'),
          label: l10n.foodDockCameraLabel,
          glyph: FoodGlyph.camera,
          fill: t.accentFill,
          ink: t.onAccentFill,
          shadow: <BoxShadow>[
            BoxShadow(
              color: t.accentGlow,
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
          onTap: enabled ? onCamera : null,
        ),
      ],
    );
  }
}

class _RoundDockButton extends StatelessWidget {
  const _RoundDockButton({
    required this.actionKey,
    required this.label,
    required this.glyph,
    required this.fill,
    required this.ink,
    required this.shadow,
    required this.onTap,
    this.border,
  });

  final Key actionKey;
  final String label;
  final FoodGlyph glyph;
  final Color fill, ink;
  final Color? border;
  final List<BoxShadow> shadow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: PressScale(
        enabled: enabled,
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: shadow),
          child: Material(
            color: enabled
                ? fill
                : fill.withValues(alpha: fill.a * kDisabledFillAlpha),
            shape: CircleBorder(
              side: border == null
                  ? BorderSide.none
                  : BorderSide(color: border!),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: actionKey,
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: SizedBox.square(
                dimension: FoodEntryDock.height,
                child: Center(
                  child: FoodGlyphIcon(
                    glyph,
                    size: 22,
                    color: enabled ? ink : context.t.inkDisabled,
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
