import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_hour_ticker.dart';

// LocalHourTicker: one notification per local hour boundary, and no timer at
// all while nobody listens (an unmounted view must leave nothing pending).

void main() {
  testWidgets('notifies once per hour boundary while listened to', (
    tester,
  ) async {
    var now = DateTime(2026, 9, 28, 14, 59, 30);
    await withClock(Clock(() => now), () async {
      final ticker = LocalHourTicker();
      addTearDown(ticker.dispose);
      var ticks = 0;
      void listener() => ticks++;

      expect(ticker.isArmed, isFalse, reason: 'no listener, no timer');
      ticker.addListener(listener);
      expect(ticker.isArmed, isTrue);

      // 30 s to 15:00, plus the safety margin.
      await tester.pump(const Duration(seconds: 30));
      expect(ticks, 0, reason: 'not before the margin has passed');
      now = DateTime(2026, 9, 28, 15, 0, 1);
      await tester.pump(LocalHourTicker.margin);
      expect(ticks, 1);
      expect(ticker.isArmed, isTrue, reason: 're-armed for 16:00');

      now = DateTime(2026, 9, 28, 16, 0, 1);
      await tester.pump(const Duration(hours: 1));
      expect(ticks, 2);

      ticker.removeListener(listener);
      expect(
        ticker.isArmed,
        isFalse,
        reason: 'the last listener leaving stops the timer',
      );
      await tester.pump(const Duration(hours: 2));
      expect(ticks, 2);
    });
  });

  testWidgets('crosses midnight into the next day', (tester) async {
    var now = DateTime(2026, 9, 28, 23, 59, 59);
    await withClock(Clock(() => now), () async {
      final ticker = LocalHourTicker();
      var ticks = 0;
      ticker.addListener(() => ticks++);
      now = DateTime(2026, 9, 29, 0, 0, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(ticks, 1);
      ticker.dispose();
      expect(ticker.isArmed, isFalse);
    });
  });

  testWidgets('a UTC clock (fixed test clocks) ticks hourly, never spins', (
    tester,
  ) async {
    // Regression: the next hour was built from a UTC `now` as a LOCAL time,
    // so east of UTC it lay in the past and the timer re-armed at zero delay
    // forever (training_account_route_test ran out of heap).
    final fixed = DateTime.utc(2026, 9, 8, 12);
    await withClock(Clock.fixed(fixed), () async {
      final ticker = LocalHourTicker();
      var ticks = 0;
      ticker.addListener(() => ticks++);
      // The frozen clock never reaches the next local hour, so every tick
      // re-arms for the same wait: an hour in whole-hour zones, 30 or 15
      // minutes in zones such as +05:30 or +05:45. Derived from the machine's
      // zone, so the count is exact anywhere, not just in UTC.
      final local = fixed.toLocal();
      final toNextHour = Duration(
        minutes: 60 - local.minute,
        seconds: -local.second,
      );
      final period = toNextHour + LocalHourTicker.margin;
      int expected(Duration elapsed) =>
          elapsed.inMicroseconds ~/ period.inMicroseconds;

      await tester.pump(const Duration(minutes: 5));
      expect(ticks, expected(const Duration(minutes: 5)));
      await tester.pump(const Duration(hours: 3));
      expect(
        ticks,
        expected(const Duration(hours: 3, minutes: 5)),
        reason: 'one tick per local hour boundary, not a loop',
      );
      expect(ticks, greaterThanOrEqualTo(3));
      ticker.dispose();
    });
  });

  testWidgets('resync after device sleep notifies and re-arms from the clock', (
    tester,
  ) async {
    // A one-shot timer's clock stops while the phone sleeps: armed at
    // 14:10 for 15:00, it is still 50 minutes away when the phone wakes at
    // 17:05. The resume path must catch up at once and aim at 18:00.
    var now = DateTime(2026, 9, 28, 14, 10);
    await withClock(Clock(() => now), () async {
      final ticker = LocalHourTicker();
      var ticks = 0;
      ticker.addListener(() => ticks++);

      now = DateTime(2026, 9, 28, 17, 5); // wake-up, no timer ran
      ticker.resync();
      expect(ticks, 1, reason: 'the missed hours are caught up at once');
      expect(ticker.isArmed, isTrue);

      // The stale 15:00 tick (50 min after arming) must be gone.
      await tester.pump(const Duration(minutes: 51));
      expect(ticks, 1, reason: 'no late tick from before the sleep');

      now = DateTime(2026, 9, 28, 18, 0, 1);
      await tester.pump(const Duration(minutes: 5));
      expect(ticks, 2, reason: 're-armed for 18:00 from the wake-up time');
      ticker.dispose();
    });
  });

  test('resync without listeners stays idle', () {
    final ticker = LocalHourTicker();
    var ticks = 0;
    void listener() => ticks++;
    ticker.resync();
    expect(ticker.isArmed, isFalse);
    ticker
      ..addListener(listener)
      ..removeListener(listener)
      ..resync();
    expect(ticks, 0);
    expect(ticker.isArmed, isFalse);
    ticker.dispose();
  });
}
