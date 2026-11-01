/// Cooking times in a preparation step, read for the cooking mode's timer
/// buttons: "10 Minuten", "10 min", "1 Std.", "1 hour", "1 Std. 30 Min.",
/// "1,5 Stunden", "1½ hours" and a few spoken forms ("eine halbe Stunde",
/// "half an hour").
///
/// German and English units are read in either language, because own and
/// imported recipes need not match the app language. A range ("10–12
/// Minuten") times its lower end: the cook checks early and can add time.
/// No number, no timer ("über Nacht", "a few minutes"); nothing longer than
/// [maxCookingTimer].
library;

/// The longest time a step offers as a timer; beyond it a time is a plan
/// ("24 Stunden marinieren"), not a countdown.
const Duration maxCookingTimer = Duration(hours: 12);

/// The distinct timers of [step], in reading order.
List<Duration> cookingTimersIn(String step) {
  final found = <_Time>[
    for (final match in _numeric.allMatches(step)) _Time.numeric(match),
    for (final (pattern, length, unit) in _phrases)
      for (final match in pattern.allMatches(step))
        _Time(match.start, match.end, length, unit),
  ]..sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : b.end.compareTo(a.end),
    );

  // An earlier (or, at the same start, longer) reading wins an overlap:
  // "half an hour" is not also "an hour".
  final kept = <_Time>[];
  for (final time in found) {
    if (kept.isEmpty || time.start >= kept.last.end) kept.add(time);
  }

  // "1 Std. 30 Min." and "1 hour and 15 minutes" are one timer.
  final merged = <_Time>[];
  for (final time in kept) {
    final last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        !last.range &&
        !time.range &&
        time.unit.index < last.unit.index &&
        _joiner.hasMatch(step.substring(last.end, time.start))) {
      merged[merged.length - 1] = _Time(
        last.start,
        time.end,
        last.length + time.length,
        time.unit,
      );
    } else {
      merged.add(time);
    }
  }

  final timers = <Duration>[];
  for (final time in merged) {
    final length = time.length;
    if (length <= Duration.zero || length > maxCookingTimer) continue;
    if (!timers.contains(length)) timers.add(length);
  }
  return timers;
}

enum _Unit { second, minute, hour }

const Map<_Unit, int> _unitSeconds = {
  _Unit.second: 1,
  _Unit.minute: 60,
  _Unit.hour: 3600,
};

class _Time {
  const _Time(
    this.start,
    this.end,
    this.length,
    this.unit, {
    this.range = false,
  });

  factory _Time.numeric(RegExpMatch match) {
    final unit = match.group(3) != null
        ? _Unit.hour
        : match.group(4) != null
        ? _Unit.minute
        : _Unit.second;
    final seconds = _value(match.group(1)!) * _unitSeconds[unit]!;
    return _Time(
      match.start,
      match.end,
      Duration(seconds: seconds.round()),
      unit,
      range: match.group(2) != null,
    );
  }

  final int start;
  final int end;
  final Duration length;
  final _Unit unit;

  /// A range ("10–12"): timed at its lower end, never merged.
  final bool range;
}

/// "1,5", "1.5", "1½", "1 ½" or "½".
double _value(String text) {
  final compact = text.replaceAll(RegExp(r'\s'), '');
  final fraction = switch (compact.isEmpty ? '' : compact[compact.length - 1]) {
    '½' => 0.5,
    '¼' => 0.25,
    '¾' => 0.75,
    _ => 0.0,
  };
  final whole = fraction == 0
      ? compact
      : compact.substring(0, compact.length - 1);
  return (whole.isEmpty ? 0 : double.parse(whole.replaceAll(',', '.'))) +
      fraction;
}

const String _number = r'(?:\d+(?:[.,]\d+)?(?:\s?[½¼¾])?|[½¼¾])';

// Longer spellings first: an alternation takes the first that matches.
const String _hours = r'stunden|stunde|std\.?|hours|hour|hrs\.?|hr\.?|h';
const String _minutes = r'minuten|minute|minutes|mins\.?|min\.?';
const String _seconds =
    r'sekunden|sekunde|sek\.?|seconds|second|secs\.?|sec\.?';

/// A number (or a range) and a unit. Not inside another number, a word or a
/// clock time ("1:30"), so "10–12 Minuten" never reads as "12 Minuten"; the
/// unit must end its word ("2 mini peppers", "2 heads").
final RegExp _numeric = RegExp(
  r'(?<![\p{L}\p{N}.,:½¼¾–—-])'
  '($_number)'
  r'(\s*(?:[–—-]|bis|to|oder|or)\s*'
  '$_number)?'
  r'\s*(?:('
  '$_hours'
  r')|('
  '$_minutes'
  r')|('
  '$_seconds'
  r'))(?!\p{L})',
  caseSensitive: false,
  unicode: true,
);

RegExp _phrase(String source) =>
    RegExp('\\b$source(?!\\p{L})', caseSensitive: false, unicode: true);

/// Spoken times without digits.
final List<(RegExp, Duration, _Unit)> _phrases = [
  (
    _phrase(r'(?:eine[rn]?\s+)?halben?\s+stunde'),
    const Duration(minutes: 30),
    _Unit.hour,
  ),
  (
    _phrase(r'(?:eine[rn]?\s+)?viertelstunde'),
    const Duration(minutes: 15),
    _Unit.hour,
  ),
  (
    _phrase(r'(?:anderthalb|eineinhalb)\s+stunden'),
    const Duration(minutes: 90),
    _Unit.hour,
  ),
  (_phrase(r'eine[rn]?\s+stunde'), const Duration(hours: 1), _Unit.hour),
  (_phrase(r'eine[rn]?\s+minute'), const Duration(minutes: 1), _Unit.minute),
  (_phrase(r'half\s+an\s+hour'), const Duration(minutes: 30), _Unit.hour),
  (_phrase(r'(?:an|one)\s+hour'), const Duration(hours: 1), _Unit.hour),
  (_phrase(r'(?:a|one)\s+minute'), const Duration(minutes: 1), _Unit.minute),
];

/// What may stand between the parts of one time: nothing, a comma, "und",
/// "and".
final RegExp _joiner = RegExp(r'^\s*(?:,|und|and)?\s*$', caseSensitive: false);
