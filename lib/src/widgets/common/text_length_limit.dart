import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// How the receiving side measures a text.
enum TextLengthUnit {
  /// `String.length` in Dart and JS.
  utf16,

  /// Dart's `runes.length`, JS's `Array.from(text).length`.
  codePoints,
}

/// Caps a field the way its server counts, in [unit] and optionally in
/// UTF-8 bytes.
///
/// Deliberately NOT [LengthLimitingTextInputFormatter]: that one counts
/// GRAPHEME CLUSTERS. A family emoji is one grapheme but up to eleven UTF-16
/// units, so a grapheme cap lets text through that the request then refuses.
///
/// [truncate] cuts an overlong edit to fit, never inside a surrogate pair;
/// otherwise the edit is rejected. Either way an edit that REDUCES the
/// overflow passes, so a field filled past the cap from code can still be
/// shortened.
class TextLengthLimit extends TextInputFormatter {
  const TextLengthLimit(
    this.maximum, {
    this.unit = TextLengthUnit.utf16,
    this.maxUtf8Bytes,
    this.truncate = true,
  });

  final int maximum;
  final TextLengthUnit unit;
  final int? maxUtf8Bytes;
  final bool truncate;

  /// By how much [text] breaks the cap; <= 0 means it fits.
  int overflow(String text) => math.max(
    (unit == TextLengthUnit.utf16 ? text.length : text.runes.length) - maximum,
    maxUtf8Bytes == null ? -1 : utf8.encode(text).length - maxUtf8Bytes!,
  );

  bool fits(String text) => overflow(text) <= 0;

  /// The longest prefix of [text] that fits, ending on a code point boundary.
  String clip(String text) {
    if (fits(text)) return text;
    final buffer = StringBuffer();
    var units = 0, points = 0, bytes = 0;
    for (final rune in text.runes) {
      final width = rune > 0xffff ? 2 : 1;
      final size = rune < 0x80 ? 1 : rune < 0x800 ? 2 : rune < 0x10000 ? 3 : 4;
      final used = unit == TextLengthUnit.utf16 ? units + width : points + 1;
      if (used > maximum ||
          (maxUtf8Bytes != null && bytes + size > maxUtf8Bytes!)) {
        break;
      }
      buffer.writeCharCode(rune);
      units += width;
      points++;
      bytes += size;
    }
    return buffer.toString();
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final neu = overflow(newValue.text);
    if (neu <= 0 || neu < overflow(oldValue.text)) return newValue;
    // Like LengthLimitingTextInputFormatter: a full field keeps its text
    // instead of losing its tail to an insertion in the middle.
    if (!truncate || overflow(oldValue.text) == 0) return oldValue;
    final text = clip(newValue.text);
    TextSelection selection = newValue.selection;
    if (selection.isValid) {
      selection = selection.copyWith(
        baseOffset: math.min(selection.baseOffset, text.length),
        extentOffset: math.min(selection.extentOffset, text.length),
      );
    }
    return TextEditingValue(
      text: text,
      selection: selection,
      composing: TextRange.empty,
    );
  }
}
