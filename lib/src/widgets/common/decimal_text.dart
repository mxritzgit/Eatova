import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/number_input.dart';

/// Locale-aware decimal for labels and field prefills: "12,5" under `de`,
/// "12.5" under `en`. Whole numbers drop the fraction ("2", not "2.0").
///
/// No digit grouping on purpose: a prefilled "1.000" would be ambiguous for
/// [NumberInput.parse].
String formatDecimal(
  num value,
  AppLocalizations l10n, {
  int maxFractionDigits = 2,
}) {
  final pattern = maxFractionDigits <= 0
      ? '0'
      : '0.${'#' * maxFractionDigits}';
  return NumberFormat(pattern, l10n.localeName).format(value);
}

/// [formatDecimal] for a field prefill that [NumberInput.parse] reads back
/// unchanged. "1,125" alone would be ambiguous (1.125 or 1125), so exactly
/// that shape gets a trailing zero: "1,1250".
String formatDecimalInput(
  num value,
  AppLocalizations l10n, {
  int maxFractionDigits = 2,
}) {
  final text = formatDecimal(
    value,
    l10n,
    maxFractionDigits: maxFractionDigits,
  );
  return NumberInput.parse(text) is AmbiguousNumberInput ? '${text}0' : text;
}

/// The field error for typed text that is not a usable number YET, or null.
///
/// Covers what every numeric field shares: ambiguous grouping ("1.000") and,
/// with [wholeNumber], a fraction in a whole-number field ("3,5"). Empty,
/// invalid and out-of-range input keep each field's own message.
String? numberInputHint(
  NumberInput input,
  AppLocalizations l10n, {
  bool wholeNumber = false,
}) => switch (input) {
  AmbiguousNumberInput(:final decimal, :final grouped) =>
    l10n.numberInputAmbiguous(
      formatDecimal(decimal, l10n, maxFractionDigits: 3),
      formatDecimal(grouped, l10n, maxFractionDigits: 3),
    ),
  ParsedNumberInput(isWhole: false) when wholeNumber =>
    l10n.numberInputWholeNumber,
  _ => null,
};

/// [LengthLimitingTextInputFormatter] that counts DIGITS, not characters:
/// separators must reach [NumberInput.parse] ("10.000" is six characters but
/// five digits) instead of the budget cutting "10.000" to "10.00" = 10.
///
/// Like the length limiter, a full field refuses the next digit and a paste
/// is cut after the last digit that fits. Characters are never filtered.
class DigitBudgetFormatter extends TextInputFormatter {
  const DigitBudgetFormatter(this.maxDigits);

  final int maxDigits;

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  static int _digits(String text) => text.codeUnits.where(_isDigit).length;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = _digits(newValue.text);
    // Within budget, or shrinking an over-long programmatic value.
    if (digits <= maxDigits || digits <= _digits(oldValue.text)) {
      return newValue;
    }
    // Typing into a full field is refused; replacing a selection is cut to the
    // budget instead, like the length limiter.
    if (_digits(oldValue.text) >= maxDigits && oldValue.selection.isCollapsed) {
      return oldValue;
    }
    var seen = 0;
    var end = 0;
    while (seen < maxDigits) {
      if (_isDigit(newValue.text.codeUnitAt(end))) seen++;
      end++;
    }
    final text = newValue.text.substring(0, end);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
