/// One rule for a "complete day" (2026-10-19), pure.
///
/// A day counts as completely logged from [completeDayShare] of the daily
/// kcal goal on: emptier days are almost certainly half-logged and would
/// drag every average down. The weekly check (`EnergyCheck`), the Coach's
/// week block, the trends averages, Today's day strip and the evening
/// reminder all read this rule, so none of them disagrees on a day.
///
/// The logging streak deliberately keeps its own, lower bar of one entry:
/// it rewards the habit, while this rule guards numbers that steer a goal.
library;

/// Share of the daily kcal goal from which a day counts as complete.
const double completeDayShare = 0.5;

/// Whether [intakeKcal] logged on a day completes it for [goalKcal].
///
/// The goal is the base daily goal (without a step bonus), the one the
/// weekly check measures against. A goal <= 0 sets no bar: then any logged
/// day counts, as before the rule existed.
bool isCompleteDay({required int intakeKcal, required int goalKcal}) =>
    goalKcal <= 0 || intakeKcal >= goalKcal * completeDayShare;
