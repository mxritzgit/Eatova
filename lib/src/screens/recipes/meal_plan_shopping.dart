part of 'meal_plan_screen.dart';

// The shopping list as a receipt: a paper slip with torn edges, dashed
// rules, one row per ingredient with its own check, totals, a stamp once
// everything is bought, and the empty state.

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

/// One checkable receipt row: check, name, leader and amount. A bought row
/// is struck through in place, so nothing moves under the finger; one merged
/// node like a checkbox list tile.
class _ReceiptRow extends StatelessWidget {
  const _ReceiptRow({
    super.key,
    required this.label,
    required this.amount,
    required this.checked,
    required this.onTap,
  });

  final String label;
  final String? amount;
  final bool checked;
  final VoidCallback? onTap;

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
                      child: _LeaderLine(
                        label: label,
                        amount: amount,
                        labelStyle: AppType.receipt(
                          14,
                          color: ink,
                          letterSpacing: -.2,
                          height: 1.4,
                        ).copyWith(decoration: strike, decorationColor: t.ink3),
                        amountStyle: AppType.receipt(
                          14,
                          weight: FontWeight.w500,
                          color: ink,
                          letterSpacing: -.2,
                          height: 1.4,
                        ).copyWith(decoration: strike, decorationColor: t.ink3),
                        leaderColor: t.inkFaint,
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

/// The heading of a receipt section: a recipe's title or the weighed
/// ingredients, in capitals, with an optional meta line and note.
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
          if (meta != null) ...[
            const SizedBox(height: 3),
            Text(meta!, style: AppType.receipt(12, color: t.ink2, height: 1.4)),
          ],
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note!, style: AppType.ui(12.5, color: t.ink3, height: 1.4)),
          ],
        ],
      ),
    );
  }
}

/// A section label inside a recipe's ingredients ("Topping:").
class _ReceiptSubheading extends StatelessWidget {
  const _ReceiptSubheading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(_kReceiptInset, 10, _kReceiptInset, 2),
    child: Text(
      text.toUpperCase(),
      semanticsLabel: text,
      style: AppType.receipt(
        11.5,
        weight: FontWeight.w500,
        color: context.t.ink2,
        letterSpacing: 1.2,
      ),
    ),
  );
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

/// ISO 8601 week number of the week starting on [monday].
int _isoWeek(DateTime monday) {
  final thursday = DateTime.utc(monday.year, monday.month, monday.day + 3);
  return thursday.difference(DateTime.utc(thursday.year)).inDays ~/ 7 + 1;
}
