part of 'meal_plan_screen.dart';

// The week view: day headers, the day strip, meal rows with their eaten
// toggle, and the "Plan a meal" row of an empty day.

/// Edge of a meal row's photo.
const double _kMealThumb = 56;

/// A day's heading: weekday, short date and the Today badge, with the
/// day's add button on the right once it has meals, and under it the
/// planned kcal against the day's goal.
class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.isToday,
    this.add,
    this.kcal,
  });

  final DateTime day;
  final bool isToday;
  final Widget? add;

  /// "1,340 of 2,100 kcal planned"; null for an empty day.
  final String? kcal;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final kcal = this.kcal;
    return ConstrainedBox(
      // As tall as the add button where there is one.
      constraints: BoxConstraints(minHeight: add == null ? 0 : 44),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      HeadingSemantics(
                        level: 2,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: DateFormat.EEEE(l.localeName).format(day),
                                style: AppType.title2(t.ink),
                              ),
                              TextSpan(
                                text:
                                    '  ${_keepTogether(DateFormat.MMMd(l.localeName).format(day))}',
                                style: AppType.ui(
                                  14,
                                  weight: FontWeight.w600,
                                  color: t.ink3,
                                ),
                              ),
                            ],
                          ),
                          semanticsLabel: DateFormat.MMMMEEEEd(
                            l.localeName,
                          ).format(day),
                        ),
                      ),
                      if (isToday)
                        StatusPill(
                          label: l.mealPlanToday,
                          tone: StatusTone.accent,
                        ),
                    ],
                  ),
                  if (kcal != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      kcal,
                      key: ValueKey('meal-plan-day-kcal-${localDayKey(day)}'),
                      style: AppType.ui(
                        13,
                        color: t.ink2,
                        height: 1.35,
                        tabular: true,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          ?add,
        ],
      ),
    );
  }
}

/// One day of the week strip: weekday, date and a dot per planned meal in
/// its slot's hue (dimmed once eaten); today carries the accent. A tap
/// scrolls to the day.
class _StripDay extends StatelessWidget {
  const _StripDay({
    required this.date,
    required this.meals,
    required this.isToday,
    required this.onTap,
  });

  final DateTime date;
  final List<PlannedMeal> meals;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final radius = BorderRadius.circular(rControl);
    final label = [
      DateFormat.MMMMEEEEd(l.localeName).format(date),
      if (isToday) l.mealPlanToday,
      l.mealPlanPlannedCount(meals.length),
    ].join(', ');
    return Semantics(
      container: true,
      button: true,
      selected: isToday,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: isToday ? t.accent.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          key: ValueKey('meal-plan-strip-${localDayKey(date)}'),
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 9),
            child: Column(
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    todayWeekdayShort(date, l),
                    maxLines: 1,
                    style: AppType.ui(
                      12,
                      weight: isToday ? FontWeight.w700 : FontWeight.w600,
                      color: isToday ? t.accentText : t.ink3,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${date.day}',
                    maxLines: 1,
                    style: AppType.display(
                      18,
                      weight: FontWeight.w700,
                      color: isToday ? t.accentText : t.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 6,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < meals.length && i < 4; i++) ...[
                        if (i > 0) const SizedBox(width: 3),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: meals[i].slot
                                .tileInk(t)
                                .withValues(alpha: meals[i].isEaten ? 0.4 : 1),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A planned meal in the list-row geometry: photo with its slot tile, name,
/// "slot · servings · kcal", then the eaten toggle and the menu. At large
/// text the actions move up beside the photo and the text gets the full
/// width. A tap on the row outside its actions opens the recipe ([onOpen]).
class _MealRow extends StatelessWidget {
  const _MealRow({
    super.key,
    required this.recipe,
    required this.slot,
    required this.title,
    required this.meta,
    required this.toggle,
    required this.noteColor,
    required this.onOpen,
    required this.openKey,
    this.note,
    this.menu,
  });

  final FitnessRecipe recipe;
  final MealSlot slot;
  final String title, meta;
  final String? note;
  final Color noteColor;
  final Widget toggle;
  final Widget? menu;
  final VoidCallback onOpen;
  final Key openKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The row's own node: its texts, read as one button that opens the
    // recipe; the toggle and the menu stay separate controls.
    final texts = Semantics(
      container: true,
      button: true,
      hint: context.l10n.mealPlanOpenRecipe,
      onTap: onOpen,
      child: MergeSemantics(child: _texts(t)),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [toggle, ?menu],
    );
    final thumb = _MealThumb(recipe: recipe, slot: slot);
    return InkWell(
      key: openKey,
      onTap: onOpen,
      excludeFromSemantics: true,
      child: Padding(
        // The last target ends 6 px before the edge: its glyph sits about
        // on the card inset, like a list row's trailing mark.
        padding: const EdgeInsets.fromLTRB(kCardInset, 14, 6, 14),
        child: _largeText(context)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [thumb, const Spacer(), actions]),
                  const SizedBox(height: kSpace12),
                  Padding(
                    padding: const EdgeInsets.only(right: kSpace12),
                    child: texts,
                  ),
                ],
              )
            : Row(
                children: [
                  thumb,
                  const SizedBox(width: kRowLeadingGap),
                  Expanded(child: texts),
                  const SizedBox(width: kSpace4),
                  actions,
                ],
              ),
      ),
    );
  }

  Widget _texts(AppTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppType.rowTitle(t.ink).copyWith(height: 1.25)),
        const SizedBox(height: 3),
        Text(
          meta,
          style: AppType.ui(13, color: t.ink2, height: 1.35, tabular: true),
        ),
        if (note != null) ...[
          const SizedBox(height: kSpace4),
          Text(note!, style: AppType.caption(noteColor).copyWith(height: 1.35)),
        ],
      ],
    );
  }
}

/// The recipe photo with the slot's icon tile on its lower left corner
/// (the right one keeps the photos' "AI Generated" mark visible).
class _MealThumb extends StatelessWidget {
  const _MealThumb({required this.recipe, required this.slot});

  final FitnessRecipe recipe;
  final MealSlot slot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SizedBox.square(
      dimension: _kMealThumb,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(rThumb - 2),
              child: ExcludeSemantics(child: RecipePhoto(recipe: recipe)),
            ),
          ),
          Positioned(
            left: -6,
            bottom: -6,
            child: Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                color: t.surf,
                borderRadius: BorderRadius.circular(rChip - 1),
              ),
              child: SlotIconTile(slot: slot, size: 26),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Eaten today" as the row's accent icon button: the fork while the meal is
/// open, the filled check circle once it is in the diary. An eaten meal
/// cannot be unticked (the diary entry is real): it stays a full-strength
/// "done" that its own button never sees a touch on (a tap there is the
/// row's), and is read as a checked, disabled checkbox.
class _EatToggle extends StatelessWidget {
  const _EatToggle({
    super.key,
    required this.eaten,
    required this.label,
    required this.onTap,
  });

  final bool eaten;
  final String label;
  final VoidCallback? onTap;

  static void _done() {}

  @override
  Widget build(BuildContext context) {
    final button = AppIconButton(
      icon: eaten ? AppIcons.checkCircle : AppIcons.restaurant,
      semanticLabel: label,
      tone: IconButtonTone.accent,
      size: IconButtonSize.compact,
      selected: eaten,
      // Not dimmed like an unavailable action; it never gets the pointer.
      onTap: eaten ? _done : onTap,
    );
    return Semantics(
      container: true,
      button: !eaten,
      checked: eaten,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: eaten ? AbsorbPointer(child: button) : button,
    );
  }
}

/// An empty day's "Plan a meal": one row with a dashed edge, an open slot to
/// fill, that opens the editor; the list-row geometry with a small accent
/// badge. Outside the planning window it stays, dimmed and disabled.
class _PlanMealRow extends StatelessWidget {
  const _PlanMealRow({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(rCard),
    );
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: PressScale(
          enabled: enabled,
          scale: kPressScaleCard,
          child: CustomPaint(
            foregroundPainter: _DashedEdge(color: t.inkFaint, radius: rCard),
            child: Material(
              color: Colors.transparent,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                customBorder: shape,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      kCardInset,
                      kSpace12,
                      kCardInset,
                      kSpace12,
                    ),
                    child: Row(
                      children: [
                        const IconBadge(
                          icon: AppIcons.add,
                          size: IconBadgeSize.sm,
                          tone: IconBadgeTone.accent,
                        ),
                        const SizedBox(width: kRowLeadingGap),
                        Expanded(
                          child: Text(label, style: AppType.rowTitle(t.ink2)),
                        ),
                      ],
                    ),
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

/// A dashed rounded edge, inset by half the stroke.
class _DashedEdge extends CustomPainter {
  const _DashedEdge({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const double _dash = 6, _gap = 5, _stroke = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(_stroke / 2),
      Radius.circular(radius),
    );
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    for (final metric in (Path()..addRRect(edge)).computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += _dash + _gap) {
        final stop = d + _dash < metric.length ? d + _dash : metric.length;
        canvas.drawPath(metric.extractPath(d, stop), pen);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedEdge old) =>
      old.color != color || old.radius != radius;
}
