import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/services/meal_photo_compressor.dart';

/// Builds a JPEG fixture: [width]x[height], left half red, right half blue.
Uint8List _jpegFixture(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fillRect(image,
      x1: 0, y1: 0, x2: width ~/ 2 - 1, y2: height - 1,
      color: img.ColorRgb8(255, 0, 0));
  img.fillRect(image,
      x1: width ~/ 2, y1: 0, x2: width - 1, y2: height - 1,
      color: img.ColorRgb8(0, 0, 255));
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

/// Cheap content fingerprint (length + rolling checksum). Comparing two
/// 200-kB buffers with `equals` would dump both into the failure message.
String _fingerprint(Uint8List bytes) {
  var sum = 0;
  for (final b in bytes) {
    sum = (sum * 31 + b) & 0x3FFFFFFF;
  }
  return '${bytes.lengthInBytes}:$sum';
}

void main() {
  test('die Voreinstellungen stehen fest: 1600 px Langseite und q85', () {
    // The two numbers in the signature are the whole contract with
    // analyze-meal: 1600 px keeps the base64 payload under the 5 MB cap, q85 is
    // what the scan model gets to look at. Nothing else in the suite noticed a
    // silent q85 -> q55 — the edge tests only ever assert pixel dimensions, and
    // a lower quality merely makes the file smaller, which every size assertion
    // here happily accepts.
    final original = _jpegFixture(2000, 1200);

    final standard = _fingerprint(compressMealPhoto(original));

    expect(standard,
        _fingerprint(compressMealPhoto(original, maxDimension: 1600)));
    expect(standard,
        isNot(_fingerprint(compressMealPhoto(original, maxDimension: 1400))),
        reason: 'die Langseiten-Voreinstellung ist nicht mehr 1600 px');
    expect(standard, _fingerprint(compressMealPhoto(original, quality: 85)));
    expect(standard,
        isNot(_fingerprint(compressMealPhoto(original, quality: 55))),
        reason: 'die JPEG-Qualitaets-Voreinstellung ist nicht mehr 85');
  });

  test('die LAENGSTE Kante wird auf 1600 px begrenzt, Aspect bleibt, kleine '
      'Bilder werden nicht hochskaliert', () {
    for (final (breite, hoehe, erwartet) in <(int, int, (int, int))>[
      (2000, 1200, (1600, 960)),
      (1200, 2000, (960, 1600)),
      (800, 600, (800, 600)),
    ]) {
      final original = _jpegFixture(breite, hoehe);
      final compressed = compressMealPhoto(original);
      final decoded = img.decodeImage(compressed)!;
      expect((decoded.width, decoded.height), erwartet,
          reason: '$breite x $hoehe');
      if (breite > 1600 || hoehe > 1600) {
        expect(compressed.lengthInBytes, lessThan(original.lengthInBytes));
      }
    }
  });

  // EXIF orientation is baked into the pixels before the metadata is
  // dropped: meal_photo_exif_scrub_test.dart.

  test(
      'Sentinel-Rest S2: nicht dekodierbare Bytes WERFEN — ungescrubbt '
      'verlaesst nichts das Geraet', () {
    // Fail-closed: undecodable bytes must throw. Passing them through would
    // ship GPS, device id and capture time to the edge function, while
    // PRIVACY.md promises scrubbing on EVERY upload. All callers are
    // throw-safe.
    final garbage = Uint8List.fromList(List<int>.generate(64, (i) => i));

    expect(() => compressMealPhoto(garbage), throwsFormatException);
  });
}
