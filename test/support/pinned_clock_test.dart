import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pinned_clock.dart';

final DateTime _mittag = DateTime(2026, 3, 14, 12);

void main() {
  test('pins the day and keeps wall time running in a plain test', () async {
    await withClockAt(_mittag, () async {
      final first = clock.now();
      expect(first.difference(_mittag), lessThan(const Duration(seconds: 1)));
      final timer = Completer<void>();
      Timer(const Duration(milliseconds: 20), timer.complete);
      await timer.future;
      // Async continuations stay in the pinned zone and see time pass.
      expect(clock.now().isAfter(first), isTrue);
      final now = clock.now();
      expect((now.year, now.month, now.day), (2026, 3, 14));
    });
  });

  test('advances with fake time inside fakeAsync', () {
    fakeAsync((async) {
      unawaited(withClockAt(_mittag, () async {
        expect(clock.now(), _mittag);
        async.elapse(const Duration(hours: 3));
        expect(clock.now(), _mittag.add(const Duration(hours: 3)));
      }));
      async.flushMicrotasks();
    });
  });

  testWidgets('advances with pumped time inside testWidgets', (tester) async {
    await withClockAt(_mittag, () async {
      expect(clock.now(), _mittag);
      await tester.pump(const Duration(minutes: 5));
      expect(clock.now(), _mittag.add(const Duration(minutes: 5)));
    });
  });
}
