import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/services/meal_photo_compressor.dart';

/// Builds a JPEG fixture: [width]x[height], left half red, right half blue.
/// Optionally with an EXIF orientation, as camera JPEGs carry.
Uint8List _jpegFixture(int width, int height, {int? exifOrientation}) {
  final image = img.Image(width: width, height: height);
  img.fillRect(image,
      x1: 0, y1: 0, x2: width ~/ 2 - 1, y2: height - 1,
      color: img.ColorRgb8(255, 0, 0));
  img.fillRect(image,
      x1: width ~/ 2, y1: 0, x2: width - 1, y2: height - 1,
      color: img.ColorRgb8(0, 0, 255));
  if (exifOrientation != null) {
    image.exif.imageIfd.orientation = exifOrientation;
  }
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

  test('verkleinert grosse Fotos auf 1600 px laengste Kante, Aspect bleibt',
      () {
    final original = _jpegFixture(2000, 1200);

    final compressed = compressMealPhoto(original);
    final decoded = img.decodeImage(compressed)!;

    expect(decoded.width, 1600);
    expect(decoded.height, 960); // 1200 * (1600 / 2000)
    expect(compressed.lengthInBytes, lessThan(original.lengthInBytes));
  });

  test('Hochkant: die LAENGSTE Kante wird auf 1600 px begrenzt', () {
    final original = _jpegFixture(1200, 2000);

    final decoded = img.decodeImage(compressMealPhoto(original))!;

    expect(decoded.width, 960);
    expect(decoded.height, 1600);
  });

  test('kleine Bilder werden nicht hochskaliert', () {
    final original = _jpegFixture(800, 600);

    final decoded = img.decodeImage(compressMealPhoto(original))!;

    expect(decoded.width, 800);
    expect(decoded.height, 600);
  });

  test('EXIF-Orientierung wird eingebacken statt verworfen (Fix 7e39cff)', () {
    // Orientation 6 = rotate 90 degrees clockwise: a 2000x1000 buffer meant to
    // display as portrait, what a phone camera produces. What matters is the
    // end-to-end behaviour of compressMealPhoto: output pixels physically
    // rotated, no orientation tag left.
    final original = _jpegFixture(2000, 1000, exifOrientation: 6);

    final compressed = compressMealPhoto(original);
    final decoded = img.decodeImage(compressed)!;

    // Pixels physically rotated: 2000x1000 landscape becomes portrait, then is
    // scaled to a 1600 px longest edge.
    expect(decoded.width, 800);
    expect(decoded.height, 1600);
    // A 90-degree CW rotation moves the left (red) half to the top.
    final top = decoded.getPixel(decoded.width ~/ 2, 10);
    final bottom = decoded.getPixel(decoded.width ~/ 2, decoded.height - 10);
    expect(top.r, greaterThan(180));
    expect(top.b, lessThan(80));
    expect(bottom.b, greaterThan(180));
    expect(bottom.r, lessThan(80));
    // No EXIF orientation left, or EXIF-aware viewers would rotate the already
    // rotated image a second time.
    final orientation = decoded.exif.imageIfd.orientation;
    expect(orientation == null || orientation == 1, isTrue,
        reason: 'Orientierung muss nach dem Einbacken neutral sein, '
            'war: $orientation');
  });

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

  test('bereits kleine, stark komprimierte Bilder werden nicht aufgeblaeht',
      () {
    // q60 fixture below 1600 px: a q85 recompression would grow the file, so
    // the original must come back unchanged.
    final image = img.Image(width: 640, height: 480);
    img.fill(image, color: img.ColorRgb8(120, 180, 90));
    final original = Uint8List.fromList(img.encodeJpg(image, quality: 60));

    final result = compressMealPhoto(original);

    expect(result.lengthInBytes, lessThanOrEqualTo(original.lengthInBytes));
  });
}
