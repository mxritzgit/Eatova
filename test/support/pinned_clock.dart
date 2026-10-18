import 'package:clock/clock.dart';

/// Runs [body] with `clock.now()` starting at [start] and advancing with the
/// surrounding clock: wall time in a plain `test`, fake time inside
/// `testWidgets` or `fakeAsync`.
///
/// The calendar day is pinned, so date-dependent expectations cannot flip at
/// midnight, while deadlines, timers and durations still elapse. Use
/// `Clock.fixed` instead where time must not move at all. Pick a [start] at
/// noon so the day survives any realistic test duration.
Future<T> withClockAt<T>(DateTime start, Future<T> Function() body) {
  final outer = clock;
  final base = outer.now();
  return withClock(
    Clock(() => start.add(outer.now().difference(base))),
    body,
  );
}
