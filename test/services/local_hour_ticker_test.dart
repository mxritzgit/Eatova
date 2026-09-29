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
    await withClock(Clock.fixed(DateTime.utc(2026, 9, 8, 12)), () async {
      final ticker = LocalHourTicker();
      var ticks = 0;
      ticker.addListener(() => ticks++);
      await tester.pump(const Duration(minutes: 5));
      expect(ticks, lessThanOrEqualTo(1));
      await tester.pump(const Duration(hours: 3));
      expect(
        ticks,
        inInclusiveRange(2, 4),
        reason: 'about one tick per hour, not a loop',
      );
      ticker.dispose();
    });
  });
}
