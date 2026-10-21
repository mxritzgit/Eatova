part of 'meal_plan_screen.dart';

// The shopping list as a receipt: a paper slip with torn edges, dashed
// rules, one row per ingredient for the whole week with its own check and
// the days behind it, spices and staples in a collapsed section, totals, a
// stamp once everything is bought, and the empty state.

/// The shopping list before anything is planned for the week.
class _ShoppingEmpty extends StatelessWidget {
  const _ShoppingEmpty({super.key, required this.onPlan});

  final VoidCallback onPlan;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: t.accentTint,
              borderRadius: BorderRadius.circular(rControl),
            ),
            child: Icon(
              Icons.shopping_basket_outlined,
              size: 22,
              color: t.accentText,
            ),
          ),
          const SizedBox(height: 14),
          HeadingSemantics(
            level: 2,
            child: Text(
              l.mealPlanShoppingEmptyHeading,
              style: AppType.display(19, weight: FontWeight.w700, color: t.ink),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l.mealPlanShoppingEmpty,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 16),
          SoftPillButton(
            key: const ValueKey('shopping-empty-plan'),
            label: l.mealPlanAdd,
            icon: Icons.add_rounded,
            onTap: onPlan,
          ),
        ],
      ),
    );
  }
}

/// Side inset of everything printed on the receipt.
const double _kReceiptInset = 20;

/// Depth of the torn edge's teeth.
const double _kToothDepth = 6;

/// The receipt's paper: a card surface whose top and bottom edges are torn
/// into teeth. Its child gets a transparent [Material], so row splashes
/// paint on the paper.
class _ReceiptPaper extends StatelessWidget {
  const _ReceiptPaper({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return CustomPaint(
      painter: _PaperPainter(fill: t.surf, edge: t.cardBorder),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _kToothDepth),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

class _PaperPainter extends CustomPainter {
  const _PaperPainter({required this.fill, required this.edge});

  final Color fill, edge;

  @override
  void paint(Canvas canvas, Size size) {
    // Whole teeth across the width, about 12 px each.
    final count = math.max(1, (size.width / 12).round());
    final tooth = size.width / count;
    final path = Path()..moveTo(0, _kToothDepth);
    for (var i = 0; i < count; i++) {
      path
        ..lineTo((i + .5) * tooth, 0)
        ..lineTo((i + 1) * tooth, _kToothDepth);
    }
    path.lineTo(size.width, size.height - _kToothDepth);
    for (var i = count; i > 0; i--) {
      path
        ..lineTo((i - .5) * tooth, size.height)
        ..lineTo((i - 1) * tooth, size.height - _kToothDepth);
    }
    path.close();
    canvas
      ..drawPath(path, Paint()..color = fill)
      ..drawPath(
        path,
        Paint()
          ..color = edge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(_PaperPainter old) =>
      old.fill != fill || old.edge != edge;
}

/// A dashed rule across the receipt; [doubled] draws the totals' rule.
class _ReceiptRule extends StatelessWidget {
  const _ReceiptRule({this.doubled = false});

  final bool doubled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: _kReceiptInset,
      vertical: 14,
    ),
    child: CustomPaint(
      size: Size.fromHeight(doubled ? 4 : 1),
      painter: _DashPainter(context.t.lineStrong, lines: doubled ? 2 : 1),
    ),
  );
}

class _DashPainter extends CustomPainter {
  const _DashPainter(this.color, {this.lines = 1});

  final Color color;
  final int lines;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var line = 0; line < lines; line++) {
      final y = line * 3 + .5;
      for (var x = 0.0; x < size.width; x += 9) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 5, size.width), y),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) =>
      old.color != color || old.lines != lines;
}

/// The dot leader between a name and its amount, its dots on [baseline].
class _LeaderPainter extends CustomPainter {
  const _LeaderPainter(this.color, this.baseline);

  final Color color;
  final double baseline;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    // Right-aligned, so every leader ends at the same column.
    for (var x = size.width - 1.5; x > 1; x -= 5) {
      canvas.drawCircle(Offset(x, baseline - 1.5), .9, paint);
    }
  }

  @override
  bool shouldRepaint(_LeaderPainter old) =>
      old.color != color || old.baseline != baseline;
}

/// A name and its amount the way a receipt prints them: on one line joined
/// by a dot leader; a name too long for that wraps with the amount at its
/// last line, a wide amount (large text) moves below it.
class _LeaderLine extends StatelessWidget {
  const _LeaderLine({
    required this.label,
    required this.amount,
    required this.labelStyle,
    required this.amountStyle,
    required this.leaderColor,
  });

  final String label;
  final String? amount;
  final TextStyle labelStyle, amountStyle;
  final Color leaderColor;

  @override
  Widget build(BuildContext context) {
    final amount = this.amount;
    if (amount == null) return Text(label, style: labelStyle);
    return LayoutBuilder(
      builder: (context, constraints) {
        final base = DefaultTextStyle.of(context).style;
        final scaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        ({double width, double height, double baseline}) measure(
          String text,
          TextStyle style,
        ) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: base.merge(style)),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          try {
            return (
              width: painter.width,
              height: painter.height,
              baseline: painter.computeDistanceToActualBaseline(
                TextBaseline.alphabetic,
              ),
            );
          } finally {
            painter.dispose();
          }
        }

        final name = measure(label, labelStyle);
        final value = measure(amount, amountStyle);
        const gap = 8.0, minLeader = 14.0;
        final amountText = Text(amount, style: amountStyle);
        if (name.width + value.width + 2 * gap + minLeader <=
            constraints.maxWidth) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: name.width.ceilToDouble(),
                child: Text(label, style: labelStyle, softWrap: false),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: CustomPaint(
                  size: Size.fromHeight(name.height),
                  painter: _LeaderPainter(leaderColor, name.baseline),
                ),
              ),
              const SizedBox(width: gap),
              amountText,
            ],
          );
        }
        if (value.width > constraints.maxWidth * .3) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: labelStyle),
              const SizedBox(height: 2),
              amountText,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Text(label, style: labelStyle)),
            const SizedBox(width: 12),
            amountText,
          ],
        );
      },
    );
  }
}

/// The square check of a receipt row: a quiet box, filled with a tick once
/// bought. [size] follows the text up to 1.5x.
class _ReceiptCheck extends StatelessWidget {
  const _ReceiptCheck({required this.checked, required this.size});
  final bool checked;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AnimatedContainer(
      duration: motionDuration(context, kMotionEnter),
      curve: kMotionCurve,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: checked ? t.selectedFill : Colors.transparent,
        borderRadius: BorderRadius.circular(size / 4),
        border: Border.all(
          color: checked ? t.selectedFill : t.ink3,
          width: 1.5,
        ),
      ),
      child: checked
          ? Icon(Icons.check_rounded, size: size * .75, color: t.onSelected)
          : null,
    );
  }
}

/// One checkable receipt row: check, name, leader and amount, and an
/// optional [detail] line with the meals behind it. A bought row is struck
/// through in place, so nothing moves under the finger; one merged node like
/// a checkbox list tile.
class _ReceiptRow extends StatelessWidget {
  const _ReceiptRow({
    super.key,
    required this.label,
    required this.amount,
    required this.checked,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? amount;
  final bool checked;
  final VoidCallback? onTap;

  /// The meals behind the row: "Mo 300 g · Do 250 g".
  final List<_DetailEntry>? detail;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ink = checked ? t.ink3 : t.ink;
    final strike = checked ? TextDecoration.lineThrough : null;
    final scaler = MediaQuery.textScalerOf(context);
    final box = math.min(scaler.scale(20), 30.0);
    // Centered on the first line of text.
    final lift = math.max(0.0, (scaler.scale(14) * 1.4 - box) / 2);
    return MergeSemantics(
      child: Semantics(
        checked: checked,
        enabled: onTap != null,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              heightFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _kReceiptInset,
                  vertical: 7,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: lift),
                      child: _ReceiptCheck(checked: checked, size: box),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _LeaderLine(
                            label: label,
                            amount: amount,
                            labelStyle:
                                AppType.receipt(
                                  14,
                                  color: ink,
                                  letterSpacing: -.2,
                                  height: 1.4,
                                ).copyWith(
                                  decoration: strike,
                                  decorationColor: t.ink3,
                                ),
                            amountStyle:
                                AppType.receipt(
                                  14,
                                  weight: FontWeight.w500,
                                  color: ink,
                                  letterSpacing: -.2,
                                  height: 1.4,
                                ).copyWith(
                                  decoration: strike,
                                  decorationColor: t.ink3,
                                ),
                            leaderColor: t.inkFaint,
                          ),
                          if (detail case final detail?)
                            _ReceiptDetail(entries: detail, checked: checked),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row's detail line, like a till's line under an article: the meals
/// behind it, small and quiet, struck through with the row. A meal stays on
/// one line ("Do Abend 180 g") where it fits; with large text, or when one
/// does not fit, each meal gets a line of its own and what wraps hangs under
/// its text, never broken inside a word. Days alone stay one line ("Mo · Di
/// · Do"). A screen reader hears full weekdays.
class _ReceiptDetail extends StatelessWidget {
  const _ReceiptDetail({required this.entries, required this.checked});

  final List<_DetailEntry> entries;
  final bool checked;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final style = AppType.receipt(12, color: t.ink3, height: 1.45).copyWith(
      decoration: checked ? TextDecoration.lineThrough : null,
      decorationColor: t.ink3,
    );
    final label = entries.map((e) => e.spoken).join(', ');
    final large = _largeText(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          double width(String text) => _lineWidth(context, text, style);
          final heads = [for (final e in entries) _keepTogether(e.head)];
          final stacked =
              entries.any((e) => e.amounts.isNotEmpty) &&
              (large || heads.any((h) => width(h) > constraints.maxWidth));
          if (!stacked) {
            // The dot stays at the end of a line, never starts one.
            return Text(
              [
                for (var i = 0; i < entries.length; i++)
                  [heads[i], ?entries[i].note].join(' '),
              ].join('\u00A0· '),
              semanticsLabel: label,
              style: style,
            );
          }
          const gap = 6.0;
          final marker = Text(
            '·',
            style: style.copyWith(decoration: TextDecoration.none),
          );
          final room = constraints.maxWidth - width('·') - gap;
          // Whole where it fits the line, else at its spaces.
          String keep(String text) =>
              width(_keepTogether(text)) <= room ? _keepTogether(text) : text;
          return Semantics(
            label: label,
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final entry in entries)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        marker,
                        const SizedBox(width: gap),
                        Expanded(
                          child: Text(
                            [
                              keep(entry.day),
                              if (entry.amounts.isNotEmpty)
                                entry.amounts.map(keep).join('\u00A0+ '),
                              ?entry.note,
                            ].join(' '),
                            style: style,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The width of [text] on one line in [style] as [context] scales it.
double _lineWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  try {
    return painter.width;
  } finally {
    painter.dispose();
  }
}

/// "Gewürze & Vorrat" after the main rows: spices and staples most kitchens
/// already have, with their own count outside the totals. Collapsed, their
/// names run as one line; expanded, each is a row with its own check.
class _ReceiptPantry extends StatelessWidget {
  const _ReceiptPantry({
    super.key,
    required this.progress,
    required this.names,
    required this.expanded,
    required this.onToggle,
    required this.rows,
  });

  final ({int done, int total}) progress;
  final List<({String label, bool checked})> names;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final bought = TextStyle(
      color: t.ink3,
      decoration: TextDecoration.lineThrough,
      decorationColor: t.ink3,
    );
    final style = AppType.receipt(13, color: t.ink2, height: 1.55);
    final summary = Padding(
      padding: const EdgeInsets.fromLTRB(_kReceiptInset, 2, _kReceiptInset, 0),
      // A node of its own: read after the heading and its count, not with
      // the receipt's header.
      child: Semantics(
        container: true,
        child: LayoutBuilder(
          builder: (context, constraints) => Text.rich(
            key: const ValueKey('shopping-pantry-summary'),
            TextSpan(
              children: [
                for (var i = 0; i < names.length; i++) ...[
                  // The dot stays at the end of a line, never starts one.
                  if (i > 0) const TextSpan(text: '\u00A0· '),
                  TextSpan(
                    // A name stays whole where it fits a line ("Öl zum
                    // Braten"); a longer one wraps at its spaces.
                    text:
                        _lineWidth(
                              context,
                              '${_keepTogether(names[i].label)}\u00A0·',
                              style,
                            ) <=
                            constraints.maxWidth
                        ? _keepTogether(names[i].label)
                        : names[i].label,
                    style: names[i].checked ? bought : null,
                  ),
                ],
              ],
            ),
            // One name per line, so a comma in a name is not a new item.
            semanticsLabel: names
                .map(
                  (n) => n.checked
                      ? l.mealPlanPantryCheckedName(n.label)
                      : n.label,
                )
                .join('\n'),
            style: style,
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReceiptHeading(
          title: l.mealPlanPantryTitle,
          meta: l.mealPlanShoppingProgress(progress.done, progress.total),
          note: l.mealPlanPantryNote,
        ),
        maybeAnimatedSize(
          context,
          duration: kMotionEnter,
          curve: kMotionCurve,
          alignment: Alignment.topCenter,
          child: expanded
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                )
              : summary,
        ),
        _PantryToggle(expanded: expanded, onTap: onToggle),
      ],
    );
  }
}

/// Opens or closes the pantry's rows: a full-width 48 px target that
/// announces its expanded state.
class _PantryToggle extends StatelessWidget {
  const _PantryToggle({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final label = expanded ? l.mealPlanPantryCollapse : l.mealPlanPantryExpand;
    return Semantics(
      key: const ValueKey('shopping-pantry-toggle'),
      container: true,
      button: true,
      expanded: expanded,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _kReceiptInset,
              vertical: 8,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              // The chevron follows the last word, also when it wraps.
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '$label\u00A0'),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: AnimatedRotation(
                        turns: expanded ? .5 : 0,
                        duration: motionDuration(context, kMotionEnter),
                        curve: kMotionCurve,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: math.min(
                            MediaQuery.textScalerOf(context).scale(20),
                            30,
                          ),
                          color: t.ink2,
                        ),
                      ),
                    ),
                  ],
                ),
                style: AppType.receipt(
                  13,
                  weight: FontWeight.w500,
                  color: t.ink,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Planned recipes without an ingredient list, named once under the rows
/// with their weekday; a screen reader hears the full weekday.
class _EmptyRecipesNote extends StatelessWidget {
  const _EmptyRecipesNote({
    super.key,
    required this.recipes,
    required this.spaced,
  });

  final List<ShoppingEmptyRecipe> recipes;

  /// Under rows: keeps its distance from the last one.
  final bool spaced;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    String names(String Function(DateTime day) weekday) => recipes
        .map((r) => '${r.title} (${weekday(DateTime.parse(r.day))})')
        .join(', ');
    final full = DateFormat.EEEE(l.localeName);
    // A node of its own, so a screen reader stops on the note.
    return Semantics(
      container: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          _kReceiptInset,
          spaced ? 10 : 0,
          _kReceiptInset,
          0,
        ),
        child: Text(
          l.mealPlanNoIngredientsNote(
            recipes.length,
            names((day) => todayWeekdayShort(day, l)),
          ),
          semanticsLabel: l.mealPlanNoIngredientsNote(
            recipes.length,
            names(full.format),
          ),
          style: AppType.ui(13.5, color: context.t.ink2, height: 1.4),
        ),
      ),
    );
  }
}

/// Under [_EmptyRecipesNote]: one link per recipe to its read-only detail,
/// where the missing list can be checked.
class _EmptyRecipeLink extends StatelessWidget {
  const _EmptyRecipeLink({
    super.key,
    required this.recipe,
    required this.onTap,
  });

  final ShoppingEmptyRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final day = DateTime.parse(recipe.day);
    final label = '${recipe.title} (${todayWeekdayShort(day, l)})';
    return Semantics(
      container: true,
      button: true,
      label: '${recipe.title}, ${DateFormat.EEEE(l.localeName).format(day)}',
      hint: l.mealPlanOpenRecipe,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _kReceiptInset,
              vertical: 8,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              // The chevron follows the last word, also when it wraps.
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '$label '),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: math.min(
                          MediaQuery.textScalerOf(context).scale(18),
                          28,
                        ),
                        color: t.accentText,
                      ),
                    ),
                  ],
                ),
                style: AppType.ui(
                  13.5,
                  weight: FontWeight.w600,
                  color: t.accentText,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The heading of a receipt section, in capitals, with an optional meta
/// line and note.
class _ReceiptHeading extends StatelessWidget {
  const _ReceiptHeading({required this.title, this.meta, this.note});

  final String title;
  final String? meta, note;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_kReceiptInset, 0, _kReceiptInset, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HeadingSemantics(
            level: 2,
            child: Text(
              title.toUpperCase(),
              semanticsLabel: title,
              style: AppType.receipt(
                14,
                weight: FontWeight.w500,
                color: t.ink,
                letterSpacing: .6,
                height: 1.35,
              ),
            ),
          ),
          // A node of its own, read right after the heading.
          if (meta != null || note != null)
            Semantics(
              container: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (meta != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      meta!,
                      style: AppType.receipt(12, color: t.ink2, height: 1.4),
                    ),
                  ],
                  if (note != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      note!,
                      style: AppType.ui(12.5, color: t.ink3, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The store line on top: brand, title, and the week with its meal count.
class _ReceiptHeader extends StatelessWidget {
  const _ReceiptHeader({required this.week, required this.meals});

  final int week, meals;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_kReceiptInset, 18, _kReceiptInset, 0),
      child: Column(
        children: [
          ExcludeSemantics(
            child: Text(
              'EATOVA',
              textAlign: TextAlign.center,
              style: AppType.display(
                22,
                weight: FontWeight.w800,
                color: t.ink,
                letterSpacing: 6,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l.mealPlanShopping.toUpperCase(),
            semanticsLabel: l.mealPlanShopping,
            textAlign: TextAlign.center,
            style: AppType.receipt(
              12,
              weight: FontWeight.w500,
              color: t.ink2,
              letterSpacing: 2.4,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            l.mealPlanReceiptMeta(week, meals),
            textAlign: TextAlign.center,
            style: AppType.receipt(12, color: t.ink3, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// The totals under the double rule, stamped once everything is bought.
class _ReceiptTotals extends StatelessWidget {
  const _ReceiptTotals({required this.done, required this.total});

  final int done, total;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final complete = total > 0 && done == total;
    Widget row(String label, String value, {required bool strong}) =>
        _LeaderLine(
          label: label.toUpperCase(),
          amount: value,
          labelStyle: AppType.receipt(
            13,
            weight: strong ? FontWeight.w500 : FontWeight.w400,
            color: strong ? t.ink : t.ink2,
            letterSpacing: .8,
            height: 1.5,
          ),
          amountStyle: AppType.receipt(
            strong ? 15 : 13,
            weight: FontWeight.w500,
            color: strong ? t.ink : t.ink2,
            height: 1.5,
          ),
          leaderColor: t.inkFaint,
        );
    final motion = motionDuration(context, kMotionEnter * 2);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kReceiptInset),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row(l.mealPlanReceiptItems, '$total', strong: false),
              const SizedBox(height: 2),
              row(l.mealPlanReceiptOpen, '${total - done}', strong: true),
            ],
          ),
          // The progress above already announces the done state.
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: Align(
                  alignment: const Alignment(.45, 0),
                  child: AnimatedOpacity(
                    duration: motion,
                    curve: kMotionCurve,
                    opacity: complete ? 1 : 0,
                    child: AnimatedScale(
                      duration: motion,
                      curve: Curves.easeOutBack,
                      scale: complete ? 1 : 1.6,
                      child: Transform.rotate(
                        angle: -.14,
                        child: _ReceiptStamp(
                          key: complete
                              ? const ValueKey('shopping-receipt-stamp')
                              : null,
                          text: l.mealPlanReceiptStamp,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A rubber stamp: framed capitals in the success tone on a paper backing,
/// so the totals under it stay calm.
class _ReceiptStamp extends StatelessWidget {
  const _ReceiptStamp({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: t.surf.withValues(alpha: .88),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.success, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_rounded, size: 18, color: t.success),
          const SizedBox(width: 6),
          Text(
            text.toUpperCase(),
            style: AppType.receipt(
              15,
              weight: FontWeight.w500,
              color: t.success,
              letterSpacing: 3,
            ),
          ),
        ],
      ),
    );
  }
}

/// The closing line and a decorative barcode drawn from the week.
class _ReceiptFooter extends StatelessWidget {
  const _ReceiptFooter({required this.seed});

  final String seed;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_kReceiptInset, 22, _kReceiptInset, 20),
      child: Column(
        children: [
          Text(
            '* ${l.mealPlanReceiptThanks} *',
            semanticsLabel: l.mealPlanReceiptThanks,
            textAlign: TextAlign.center,
            style: AppType.receipt(12.5, color: t.ink2, letterSpacing: .4),
          ),
          const SizedBox(height: 14),
          ExcludeSemantics(
            child: CustomPaint(
              size: const Size(176, 34),
              painter: _BarcodePainter(t.ink2, seed),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarcodePainter extends CustomPainter {
  const _BarcodePainter(this.color, this.seed);

  final Color color;
  final String seed;

  @override
  void paint(Canvas canvas, Size size) {
    // A small deterministic generator, so a week always prints the same bars.
    var state = seed.codeUnits.fold<int>(17, (h, c) => (h * 31 + c) & 0x7fffffff);
    int next(int range) {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      return state % range;
    }

    final paint = Paint()..color = color;
    var x = 0.0;
    while (x < size.width) {
      final bar = 1.0 + next(3);
      canvas.drawRect(
        Rect.fromLTWH(x, 0, math.min(bar, size.width - x), size.height),
        paint,
      );
      x += bar + 1.5 + next(3);
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter old) =>
      old.color != color || old.seed != seed;
}

/// The week's receipt as plain text for the clipboard: the receipt's title
/// line, one line per row as "- 550 g Hähnchenbrustfilet" ("✓" once
/// bought), then the pantry rows under their heading. Amounts read as on the
/// receipt.
String shoppingReceiptText(
  ShoppingReceipt receipt, {
  required Map<String, bool> checks,
  required int week,
  required int meals,
  required AppLocalizations l,
}) {
  String line(ShoppingRow row) {
    final amount = _receiptAmount(row, l);
    final item = amount == null ? row.label : '$amount ${row.label}';
    return '${row.isChecked(checks) ? '✓' : '-'} $item';
  }

  return [
    '${l.mealPlanShopping} · ${l.mealPlanReceiptMeta(week, meals)}',
    if (receipt.rows.isNotEmpty) '',
    for (final row in receipt.rows) line(row),
    if (receipt.pantry.isNotEmpty) ...[
      '',
      l.mealPlanPantryTitle,
      for (final row in receipt.pantry) line(row),
    ],
  ].join('\n');
}

/// A row's amounts and its unparsed ones as the receipt prints them: "550 g",
/// "2 EL + 1 TL", "300 g + 1 Handvoll"; null when it has none.
String? _receiptAmount(ShoppingRow row, AppLocalizations l) {
  final cloves = _namesCloves(row.label);
  final pieces = [
    for (final amount in row.total) _amountText(amount, l, cloves: cloves),
    ...row.texts,
  ];
  return pieces.isEmpty ? null : pieces.join(' + ');
}

/// "Knoblauchzehen", "garlic cloves": the name already says what is counted.
bool _namesCloves(String label) =>
    RegExp('zehe|clove', caseSensitive: false).hasMatch(label);

/// One amount: "550 g", "1,2 kg", "3", "2 Dosen", "1 1/2 EL", "ca. 4–5".
/// Grams and millilitres switch to kilos and litres at 1,000. With [cloves]
/// a clove count is a bare number.
String _amountText(
  ShoppingAmount amount,
  AppLocalizations l, {
  bool cloves = false,
}) {
  final locale = l.localeName;
  final metric =
      amount.unit == ShoppingUnit.mass || amount.unit == ShoppingUnit.volume;
  final large = metric && amount.high >= 999.5;
  String number(double value) {
    if (!metric) return _countNumber(value, locale);
    if (large) return NumberFormat('0.##', locale).format(value / 1000);
    return NumberFormat(value >= 10 ? '0' : '0.#', locale).format(value);
  }

  final value = amount.isRange
      ? '${number(amount.low)}–${number(amount.high)}'
      : number(amount.low);
  // "1/2 Dose", "2 Dosen": up to one, the singular reads naturally.
  final count = amount.high <= 1 ? 1 : amount.high;
  final text = switch (amount.unit) {
    ShoppingUnit.mass => '$value ${large ? 'kg' : 'g'}',
    ShoppingUnit.volume => '$value ${large ? 'l' : 'ml'}',
    ShoppingUnit.piece => value,
    ShoppingUnit.clove when cloves => value,
    ShoppingUnit.clove => l.mealPlanUnitClove(count, value),
    ShoppingUnit.slice => l.mealPlanUnitSlice(count, value),
    ShoppingUnit.can => l.mealPlanUnitCan(count, value),
    ShoppingUnit.jar => l.mealPlanUnitJar(count, value),
    ShoppingUnit.tub => l.mealPlanUnitTub(count, value),
    ShoppingUnit.pack => l.mealPlanUnitPack(count, value),
    ShoppingUnit.bunch => l.mealPlanUnitBunch(count, value),
    ShoppingUnit.sprig => l.mealPlanUnitSprig(count, value),
    ShoppingUnit.handful => l.mealPlanUnitHandful(count, value),
    ShoppingUnit.cup => l.mealPlanUnitCup(count, value),
    ShoppingUnit.tbsp => l.mealPlanUnitTbsp(count, value),
    ShoppingUnit.tsp => l.mealPlanUnitTsp(count, value),
    ShoppingUnit.pinch => l.mealPlanUnitPinch(count, value),
    ShoppingUnit.centimetre => l.mealPlanUnitCentimetre(count, value),
  };
  return amount.approx ? l.mealPlanAmountApprox(text) : text;
}

/// A count the way recipes write it: whole or with a common fraction ("1
/// 1/2", "1/4", "5/8"), else with up to two decimals.
String _countNumber(double value, String locale) {
  final whole = value.floor();
  final rest = value - whole;
  if (rest < .01) return '$whole';
  if (rest > .99) return '${whole + 1}';
  for (final (fraction, text) in _kCountFractions) {
    if ((rest - fraction).abs() < .01) {
      return whole == 0 ? text : '$whole $text';
    }
  }
  return NumberFormat('0.##', locale).format(value);
}

const _kCountFractions = [
  (1 / 8, '1/8'),
  (1 / 4, '1/4'),
  (1 / 3, '1/3'),
  (3 / 8, '3/8'),
  (1 / 2, '1/2'),
  (5 / 8, '5/8'),
  (2 / 3, '2/3'),
  (3 / 4, '3/4'),
  (7 / 8, '7/8'),
];

/// One planned meal behind a row: its day and amounts, as shown and as a
/// screen reader hears them.
class _DetailEntry {
  const _DetailEntry({
    required this.day,
    required this.spokenDay,
    required this.amounts,
    this.note,
    this.spokenNote,
  });

  /// "Do Abend"; [spokenDay] "Donnerstag Abend".
  final String day, spokenDay;
  final List<String> amounts;

  /// "(Rezept für 4 Port.)"; [spokenNote] without the abbreviation.
  final String? note, spokenNote;

  /// "Do Abend 180 g".
  String get head =>
      [day, if (amounts.isNotEmpty) amounts.join(' + ')].join(' ');

  String get spoken => [
    spokenDay,
    if (amounts.isNotEmpty) amounts.join(' + '),
    ?spokenNote,
  ].join(' ');
}

/// The meals behind [row], one entry per planned meal by day: "Mo 300 g",
/// "Do 250 g", with the slot when a day has two of them, and an amount the
/// recipe gives unconverted marked as such. Null when the row is one meal's
/// planned amount.
List<_DetailEntry>? _receiptDetail(ShoppingRow row, AppLocalizations l) {
  if (!row.showsDetail) return null;
  final meals = <String, List<ShoppingUse>>{};
  for (final use in row.uses) {
    (meals[use.planId] ??= []).add(use);
  }
  // Two lines of one recipe: the amount already says it all.
  if (meals.length < 2 && !row.hasUnscaled) return null;
  final perDay = <String, int>{};
  for (final uses in meals.values) {
    perDay.update(uses.first.day, (n) => n + 1, ifAbsent: () => 1);
  }
  final fullDay = DateFormat.EEEE(l.localeName);
  final cloves = _namesCloves(row.label);
  return [
    for (final uses in meals.values)
      _detailEntry(
        uses,
        l,
        fullDay: fullDay,
        cloves: cloves,
        slot: perDay[uses.first.day]! > 1,
      ),
  ];
}

_DetailEntry _detailEntry(
  List<ShoppingUse> uses,
  AppLocalizations l, {
  required DateFormat fullDay,
  required bool cloves,
  required bool slot,
}) {
  final first = uses.first;
  final date = DateTime.parse(first.day);
  final slotLabel = slot ? ' ${first.slot.shortLabel(l)}' : '';
  final planned = [
    for (final amount in sumShoppingAmounts([
      for (final use in uses)
        if (use.amount case final amount?) amount,
    ]))
      _amountText(amount, l, cloves: cloves),
    for (final use in uses)
      if (use.amount == null && use.text != null && !use.unscaled) use.text!,
  ];
  final original = [
    for (final use in uses)
      if (use.unscaled && use.text != null) use.text!,
  ];
  // One recipe has one serving basis: one note for its amounts, also for
  // one left in the name ("Reis (300 g gekocht)").
  final (note, spokenNote) = switch (uses
      .where((u) => u.unscaled)
      .firstOrNull) {
    null => (null, null),
    ShoppingUse(scale: ShoppingScale.batch, :final batchServings?) => (
      l.mealPlanReceiptBatchNote(
        NumberFormat('0.##', l.localeName).format(batchServings),
      ),
      l.mealPlanReceiptBatchNoteSpoken(batchServings),
    ),
    _ => (l.mealPlanReceiptOriginalNote, l.mealPlanReceiptOriginalNote),
  };
  return _DetailEntry(
    day: todayWeekdayShort(date, l) + slotLabel,
    spokenDay: fullDay.format(date) + slotLabel,
    amounts: [...planned, ...original],
    note: note,
    spokenNote: spokenNote,
  );
}

/// ISO 8601 week number of the week starting on [monday].
int _isoWeek(DateTime monday) {
  final thursday = DateTime.utc(monday.year, monday.month, monday.day + 3);
  return thursday.difference(DateTime.utc(thursday.year)).inDays ~/ 7 + 1;
}
