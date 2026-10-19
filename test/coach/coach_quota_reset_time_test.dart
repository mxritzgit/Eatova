// The Coach limit resets at 00:00 UTC (server rule, unchanged). The texts
// used to say "midnight (UTC)" and "more tomorrow", which is wrong between
// local midnight and the reset (00:00-01:59 in Germany in summer). They now
// name the reset as a local clock time (review 2026-10-19).

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/coach_quota_reset.dart';

Duration _cest(DateTime _) => const Duration(hours: 2);
Duration _newYork(DateTime _) => const Duration(hours: -4);
Duration _india(DateTime _) => const Duration(hours: 5, minutes: 30);

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

  test('Berlin im Sommer, 00:30 Ortszeit: heute um 02:00, nicht "morgen"', () {
    // 2026-10-19 00:30 CEST = 2026-10-18 22:30 UTC.
    final label = withClock(
      Clock.fixed(DateTime.utc(2026, 10, 18, 22, 30)),
      () => coachQuotaResetLabel('de', offsetOf: _cest),
    );
    expect(label, '02:00');
    expect(
      deL10n.coachErrorDailyLimitReached(5, label),
      "Tageslimit erreicht (5 Coach-Fragen pro Tag). Weiter geht's um 02:00 Uhr.",
    );
    expect(
      deL10n.coachErrorDailyLimitReached(5, label),
      isNot(contains('Morgen')),
    );
  });

  test('New York, abends: der Reset liegt am selben Abend', () {
    // 2026-10-19 19:30 EDT = 23:30 UTC.
    final label = withClock(
      Clock.fixed(DateTime.utc(2026, 10, 19, 23, 30)),
      () => coachQuotaResetLabel('en', offsetOf: _newYork),
    );
    expect(label, '8:00 PM');
    expect(
      enL10n.coachInfoLimitBody(0, 5, label),
      '0 of 5 questions left today. New questions from 8:00 PM.',
    );
  });

  test('halbe Stunden und 12-Stunden-Uhr', () {
    final now = DateTime.utc(2026, 10, 19, 12);
    expect(coachQuotaResetLabel('de', now: now, offsetOf: _india), '05:30');
    expect(coachQuotaResetLabel('en', now: now, offsetOf: _india), '5:30 AM');
    expect(
      coachQuotaResetLabel('en', now: now, offsetOf: (_) => Duration.zero),
      '12:00 AM',
    );
    expect(
      coachQuotaResetLabel(
        'en',
        now: now,
        offsetOf: (_) => const Duration(hours: 12),
      ),
      '12:00 PM',
    );
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
