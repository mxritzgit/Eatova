part of 'meal_plan_screen.dart';

// The shopping list: the empty state, amount capsules and the round check.

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

/// A weighed amount as a quiet capsule: the number in the display face, the
/// unit muted. Dimmed (bought) it keeps `ink3`, still AA on `surf2`.
class _AmountCapsule extends StatelessWidget {
  const _AmountCapsule({
    required this.value,
    required this.unit,
    required this.dimmed,
  });

  final String value, unit;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: value,
              style: AppType.display(
                15,
                weight: FontWeight.w700,
                color: dimmed ? t.ink3 : t.ink,
              ),
            ),
            TextSpan(
              text: ' $unit',
              style: AppType.ui(
                12.5,
                weight: FontWeight.w600,
                color: dimmed ? t.ink3 : t.ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The round check of a shopping row: an accent disc with a tick when
/// bought, a quiet ring before.
class _ShoppingCheck extends StatelessWidget {
  const _ShoppingCheck({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final motion = motionDuration(context, kMotionEnter);
    return AnimatedContainer(
      duration: motion,
      curve: kMotionCurve,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: checked ? t.selectedFill : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: checked ? t.selectedFill : t.ink3,
          width: 2,
        ),
      ),
      child: checked
          ? Icon(Icons.check_rounded, size: 16, color: t.onSelected)
          : null,
    );
  }
}
