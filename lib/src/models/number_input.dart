/// What the text of a numeric form field means.
///
/// One parser for every field that takes a typed number, so "3,5" cannot mean
/// 3.5 in one sheet and 35 in the next. Locale-independent on purpose: German
/// users type "," or "." (many keyboards only offer the dot), English users
/// type "." — both must work in either language.
///
/// Rules:
/// - "3,5" and "3.5" are 3.5; a lone leading or trailing mark is allowed
///   (",5" is 0.5, "5," is 5).
/// - Grouping is accepted only where nothing else fits: "1.000,5",
///   "1,000.5", "1.000.000".
/// - One mark with exactly three digits after a 1–3 digit integer part that
///   does not start with 0 ("1.000", "2,500") reads as a decimal AND as a
///   thousands group. It is reported as [AmbiguousNumberInput], never guessed.
///   "0,125" and "1234,567" are not ambiguous.
/// - Anything else (letters, signs, spaces, exponents, repeated or misplaced
///   marks) is [InvalidNumberInput]. Characters are never stripped.
///
/// Surrounding whitespace is ignored.
sealed class NumberInput {
  const NumberInput();

  factory NumberInput.parse(String text) => _parse(text.trim());

  /// The number, or null while the text is empty, ambiguous or invalid.
  double? get value;

  /// [value] as an int when it is a whole number, else null. `"3,0"` is 3;
  /// `"3,5"` is null, not 35.
  int? get wholeValue;
}

/// Nothing typed (or whitespace only).
final class EmptyNumberInput extends NumberInput {
  const EmptyNumberInput();

  @override
  double? get value => null;

  @override
  int? get wholeValue => null;
}

/// An unambiguous, finite, non-negative number.
final class ParsedNumberInput extends NumberInput {
  const ParsedNumberInput(this.value);

  @override
  final double value;

  /// No fractional part.
  bool get isWhole => value == value.truncateToDouble();

  @override
  int? get wholeValue =>
      isWhole && value <= _maxSafeInteger ? value.toInt() : null;
}

/// A mark that is either a decimal separator ([decimal], "1.000" = 1) or a
/// thousands separator ([grouped], "1.000" = 1000).
final class AmbiguousNumberInput extends NumberInput {
  const AmbiguousNumberInput({required this.decimal, required this.grouped});

  final double decimal;
  final double grouped;

  @override
  double? get value => null;

  @override
  int? get wholeValue => null;
}

/// Not a number any field accepts.
final class InvalidNumberInput extends NumberInput {
  const InvalidNumberInput();

  @override
  double? get value => null;

  @override
  int? get wholeValue => null;
}

/// 2^53 - 1: above it a double no longer holds every integer exactly.
const double _maxSafeInteger = 9007199254740991;

final RegExp _allowed = RegExp(r'^[0-9.,]+$');
final RegExp _digit = RegExp('[0-9]');
final RegExp _leadingGroup = RegExp(r'^[1-9][0-9]{0,2}$');
final RegExp _group = RegExp(r'^[0-9]{3}$');

NumberInput _parse(String text) {
  if (text.isEmpty) return const EmptyNumberInput();
  if (!_allowed.hasMatch(text) || !text.contains(_digit)) {
    return const InvalidNumberInput();
  }
  final lastDot = text.lastIndexOf('.');
  final lastComma = text.lastIndexOf(',');

  // Both marks: the later one is the decimal mark, the earlier kind groups.
  if (lastDot >= 0 && lastComma >= 0) {
    final decimalAt = lastDot > lastComma ? lastDot : lastComma;
    final groupMark = lastDot > lastComma ? ',' : '.';
    final whole = text.substring(0, decimalAt);
    final fraction = text.substring(decimalAt + 1);
    if (fraction.contains(RegExp('[.,]'))) return const InvalidNumberInput();
    final groups = whole.split(groupMark);
    if (!_isGrouping(groups)) return const InvalidNumberInput();
    return _number(groups.join(), fraction);
  }

  // No mark: plain digits.
  if (lastDot < 0 && lastComma < 0) return _number(text, '');

  final parts = text.split(lastDot >= 0 ? '.' : ',');
  if (parts.length > 2) {
    // Several marks of one kind can only be grouping: "1.000.000".
    return _isGrouping(parts)
        ? _number(parts.join(), '')
        : const InvalidNumberInput();
  }
  final whole = parts.first;
  final fraction = parts.last;
  if (_leadingGroup.hasMatch(whole) && _group.hasMatch(fraction)) {
    return AmbiguousNumberInput(
      decimal: double.parse('$whole.$fraction'),
      grouped: double.parse('$whole$fraction'),
    );
  }
  return _number(whole, fraction);
}

/// "1", "000", "000" — a valid thousands grouping of an integer part.
bool _isGrouping(List<String> groups) =>
    groups.length > 1 &&
    _leadingGroup.hasMatch(groups.first) &&
    groups.skip(1).every(_group.hasMatch);

/// [whole] and [fraction] are digit strings; one of them holds a digit.
NumberInput _number(String whole, String fraction) {
  final value = double.parse(
    '${whole.isEmpty ? '0' : whole}.${fraction.isEmpty ? '0' : fraction}',
  );
  return value.isFinite
      ? ParsedNumberInput(value)
      : const InvalidNumberInput();
}
