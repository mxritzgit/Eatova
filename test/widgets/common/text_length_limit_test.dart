import 'package:eatova/src/widgets/common/text_length_limit.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _value(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  const smile = '\u{1F600}'; // 1 grapheme, 1 code point, 2 UTF-16 units
  const thumbs = '\u{1F44D}\u{1F3FD}'; // 1 grapheme, 2 code points, 4 units

  group('clip', () {
    test('counts UTF-16 units and never splits a surrogate pair', () {
      const limit = TextLengthLimit(5);
      expect(limit.clip('ab$smile$smile'), 'ab$smile');
      expect(limit.clip('abc$smile'), 'abc$smile');
      expect(limit.clip('abcd$smile'), 'abcd');
    });

    test('counts code points when asked to', () {
      const limit = TextLengthLimit(3, unit: TextLengthUnit.codePoints);
      expect(limit.clip(thumbs * 2), '$thumbs\u{1F44D}');
      expect(limit.fits(thumbs), isTrue);
      expect(limit.fits(thumbs * 2), isFalse);
    });

    test('honours the UTF-8 byte belt', () {
      const limit = TextLengthLimit(100, maxUtf8Bytes: 5);
      expect(limit.clip('a$smile$smile'), 'a$smile');
    });
  });

  group('formatEditUpdate', () {
    test('truncating: an overlong edit is cut to fit', () {
      const limit = TextLengthLimit(4);
      final out = limit.formatEditUpdate(_value('a'), _value('a$smile$smile'));
      expect(out.text, 'a$smile');
      expect(out.selection.baseOffset, 3);
    });

    test('truncating: a full field keeps its text', () {
      const limit = TextLengthLimit(4);
      final full = _value('ab$smile');
      expect(limit.formatEditUpdate(full, _value('xab$smile')), full);
    });

    test('rejecting: an overlong edit keeps the old value', () {
      const limit = TextLengthLimit(4, truncate: false);
      final old = _value('a');
      expect(limit.formatEditUpdate(old, _value('a$smile$smile')), old);
    });

    test('an edit that reduces the overflow passes', () {
      for (final truncate in [true, false]) {
        final limit = TextLengthLimit(2, truncate: truncate);
        final shorter = _value('abc');
        expect(
          limit.formatEditUpdate(_value('abcd'), shorter),
          shorter,
          reason: 'truncate: $truncate',
        );
      }
    });
  });
}
