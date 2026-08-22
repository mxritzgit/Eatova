import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_day.dart';

// DATA-6: canonical local day key. localDayKey is a pure, stable YYYY-MM-DD
// function that meal bucketing (logged_meals.local_day) builds on.

void main() {
  group('localDayKey (rein + stabil)', () {
    test('formatiert YYYY-MM-DD mit Zero-Padding', () {
      expect(localDayKey(DateTime(2026, 6, 4, 23, 45)), '2026-06-04');
      expect(localDayKey(DateTime(2026, 1, 9, 0, 1)), '2026-01-09');
      expect(localDayKey(DateTime(7, 2, 3)), '0007-02-03');
    });

    test('haengt nur am Kalendertag, nicht an der Uhrzeit', () {
      final day = DateTime(2026, 6, 4);
      expect(localDayKey(DateTime(2026, 6, 4, 0, 0)), localDayKey(day));
      expect(localDayKey(DateTime(2026, 6, 4, 23, 59, 59)), localDayKey(day));
    });

    test('deterministisch ueber mehrfachen Aufruf', () {
      final t = DateTime(2026, 6, 4, 23, 45);
      expect(localDayKey(t), localDayKey(t));
    });
  });
}
