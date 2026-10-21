// The Coach limit resets at 00:00 UTC (server rule, unchanged). The texts
// used to say "midnight (UTC)" and "more tomorrow", which is wrong between
// local midnight and the reset (00:00-01:59 in Germany in summer). They now
// name the reset as a local clock time (review 2026-10-19).

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/coach_quota_reset.dart';

void main() {
  test('der Reset ist die naechste UTC-Mitternacht', () {
    expect(
      nextCoachQuotaReset(DateTime.utc(2026, 10, 19, 22, 30)),
      DateTime.utc(2026, 10, 20),
    );
    expect(
      nextCoachQuotaReset(DateTime.utc(2026, 12, 31, 0, 0, 1)),
      DateTime.utc(2027, 1, 1),
    );
  });

  test('das Label nennt den Reset in Ortszeit, 24 h deutsch, 12 h englisch', () {
    // 2026-10-19 00:30 CEST = 2026-10-18 22:30 UTC: today at 02:00, not
    // "tomorrow". Read from the clock, as the app does.
    expect(
      withClock(
        Clock.fixed(DateTime.utc(2026, 10, 18, 22, 30)),
        () => coachQuotaResetLabel(
          'de',
          offsetOf: (_) => const Duration(hours: 2),
        ),
      ),
      '02:00',
    );
    final now = DateTime.utc(2026, 10, 19, 12);
    for (final (locale, offset, label) in <(String, Duration, String)>[
      // New York in the evening: the reset is the same evening.
      ('en', const Duration(hours: -4), '8:00 PM'),
      // Half hours.
      ('de', const Duration(hours: 5, minutes: 30), '05:30'),
      ('en', const Duration(hours: 5, minutes: 30), '5:30 AM'),
      // The 12-hour clock's two edges.
      ('en', Duration.zero, '12:00 AM'),
      ('en', const Duration(hours: 12), '12:00 PM'),
    ]) {
      expect(
        coachQuotaResetLabel(locale, now: now, offsetOf: (_) => offset),
        label,
        reason: '$locale $offset',
      );
    }
  });

  test('kein Text nennt mehr Mitternacht (UTC) oder morgen', () {
    for (final l10n in [deL10n, enL10n]) {
      final texts = [
        l10n.coachInfoLimitBody(3, 5, '02:00'),
        l10n.coachInfoLimitUnknown('02:00'),
        l10n.coachErrorDailyLimitReached(5, '02:00'),
        l10n.coachErrorQuotaFallback('02:00'),
      ];
      for (final text in texts) {
        expect(text, contains('02:00'));
        expect(text.toLowerCase(), isNot(contains('utc')));
        expect(text.toLowerCase(), isNot(contains('morgen')));
        expect(text.toLowerCase(), isNot(contains('tomorrow')));
      }
    }
  });
}
