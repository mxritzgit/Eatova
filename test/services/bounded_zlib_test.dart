import 'dart:io';
import 'dart:typed_data';

import 'package:eatova/src/services/bounded_zlib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final count in [0, 1, 64, 32768, 65537]) {
    test(
      'bounded zlib preserves valid $count byte streams and sliding history',
      () {
        final raw = List.generate(count, (i) => (i * 31 + i ~/ 71) & 255);
        final compressed = Uint8List.fromList(zlib.encode(raw));
        expect(
          () => validateZlibOutput(
            compressed,
            maxBytes: count,
            expectedBytes: count,
          ),
          returnsNormally,
        );
        if (count > 0) {
          expect(
            () => validateZlibOutput(compressed, maxBytes: count - 1),
            throwsFormatException,
          );
        }
      },
    );
  }
  test(
    'bad checksum, truncated streams and wrong expected size fail closed',
    () {
      final compressed = Uint8List.fromList(zlib.encode([1, 2, 3, 4]));
      final invalid = Uint8List.fromList(compressed)..last ^= 1;
      expect(
        () => validateZlibOutput(invalid, maxBytes: 100),
        throwsFormatException,
      );
      expect(
        () => validateZlibOutput(compressed.sublist(0, 5), maxBytes: 100),
        throwsFormatException,
      );
      expect(
        () => validateZlibOutput(compressed, maxBytes: 100, expectedBytes: 8),
        throwsFormatException,
      );
    },
  );
}
