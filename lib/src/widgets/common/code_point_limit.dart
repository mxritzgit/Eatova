import 'package:flutter/services.dart';

import '../../models/model_limits.dart' show truncateToChars;

/// Caps a field at [maxCodePoints] Unicode code points, the unit Postgres
/// `char_length` counts. [LengthLimitingTextInputFormatter] counts grapheme
/// clusters, so ZWJ emoji could still overshoot a column check.
///
/// Cuts on code-point boundaries, never inside a surrogate pair. An edit that
/// shortens an over-long value (set from code) always passes.
class CodePointLimitFormatter extends TextInputFormatter {
  const CodePointLimitFormatter(this.maxCodePoints);

  final int maxCodePoints;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final count = newValue.text.runes.length;
    if (count <= maxCodePoints) return newValue;
    final oldCount = oldValue.text.runes.length;
    if (count < oldCount) return newValue;
    if (oldCount >= maxCodePoints) return oldValue;
    final text = truncateToChars(newValue.text, maxCodePoints);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
