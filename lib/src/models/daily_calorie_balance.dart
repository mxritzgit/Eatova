/// The base goal and measured activity credit remain separate, while both
/// contribute to the day's budget. A negative remainder means over budget.
class DailyCalorieBalance {
  DailyCalorieBalance({
    required int goalKcal,
    required int consumedKcal,
    required int burnedKcal,
  }) : goalKcal = goalKcal <= 0 ? 1 : goalKcal,
       consumedKcal = consumedKcal.clamp(0, 99999),
       burnedKcal = burnedKcal.clamp(0, 99999);

  final int goalKcal;
  final int consumedKcal;
  final int burnedKcal;

  int get budgetKcal => goalKcal + burnedKcal;
  int get remainingKcal => (budgetKcal - consumedKcal).clamp(-99999, 99999);
  double get progress => (consumedKcal / budgetKcal).clamp(0.0, 1.0);
}
