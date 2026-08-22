import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/services/meal_photo_compressor.dart';

/// GPS tag IDs in the `gps` sub-IFD (EXIF spec).
const int _tagGpsVersionId = 0x0000;
const int _tagGpsLatitudeRef = 0x0001;
const int _tagGpsLatitude = 0x0002;
const int _tagGpsLongitudeRef = 0x0003;
const int _tagGpsLongitude = 0x0004;
const int _tagGpsAltitudeRef = 0x0005;
const int _tagGpsAltitude = 0x0006;
const int _tagGpsTimeStamp = 0x0007;
const int _tagGpsDateStamp = 0x001d;

/// package:image does not export `Rational`; a one-element value yields
/// instances without naming the type.
img.IfdValueRational _rationals(List<List<int>> parts) {
  final value = img.IfdValueRational(parts.first[0], parts.first[1]);
  for (final part in parts.skip(1)) {
    value.value.add(img.IfdValueRational(part[0], part[1]).value.first);
  }
  return value;
}

/// A realistic phone JPEG: pixels plus the EXIF container an OEM camera writes
/// with location tagging on — GPS sub-IFD, device model, serial, capture time.
Uint8List _geotaggedJpeg({
  int width = 480,
  int height = 360,
  int? orientation,
  int quality = 92,
}) {
  final image = img.Image(width: width, height: height);
  // Two color fields instead of one fill, so the orientation check below can
  // tell which side is up.
  img.fillRect(image,
      x1: 0,
      y1: 0,
      x2: width ~/ 2 - 1,
      y2: height - 1,
      color: img.ColorRgb8(220, 30, 30));
  img.fillRect(image,
      x1: width ~/ 2,
      y1: 0,
      x2: width - 1,
      y2: height - 1,
      color: img.ColorRgb8(30, 30, 220));

  final exif = image.exif;
  exif.imageIfd['Make'] = 'ACME';
  exif.imageIfd['Model'] = 'ACME Phone 12 Pro';
  exif.imageIfd['Software'] = 'ACME Camera 4.2';
  exif.exifIfd['DateTimeOriginal'] = '2026:08:08 12:34:56';
  exif.exifIfd['BodySerialNumber'] = 'SN-4711-ABCDEF';
  if (orientation != null) {
    exif.imageIfd.orientation = orientation;
  }

  final gps = exif.gpsIfd;
  gps[_tagGpsVersionId] =
      img.IfdValueUndefined.list(Uint8List.fromList(<int>[2, 3, 0, 0]));
  gps[_tagGpsLatitudeRef] = img.IfdValueAscii('N');
  // 52° 30' 58.68" N
  gps[_tagGpsLatitude] = _rationals(<List<int>>[
    <int>[52, 1],
    <int>[30, 1],
    <int>[5868, 100],
  ]);
  gps[_tagGpsLongitudeRef] = img.IfdValueAscii('E');
  // 13° 22' 40.32" E
  gps[_tagGpsLongitude] = _rationals(<List<int>>[
    <int>[13, 1],
    <int>[22, 1],
    <int>[4032, 100],
  ]);
  gps[_tagGpsAltitudeRef] = img.IfdByteValue(0);
  gps[_tagGpsAltitude] = img.IfdValueRational(3417, 100);
  gps[_tagGpsTimeStamp] = _rationals(<List<int>>[
    <int>[12, 1],
    <int>[34, 1],
    <int>[56, 1],
  ]);
  gps[_tagGpsDateStamp] = img.IfdValueAscii('2026:08:08');

  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

/// Searches the raw byte stream for the APP1 Exif signature ("Exif\x00\x00").
/// That is the level that matters: whatever stands here leaves the device.
bool _hasExifSegment(Uint8List bytes) {
  const signature = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // Exif\0\0
  for (var i = 0; i + signature.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < signature.length; j++) {
      if (bytes[i + j] != signature[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Collects the GPS tags still present in the result after decoding.
List<int> _gpsTagsIn(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return const <int>[];
  return decoded.exif.gpsIfd.keys.toList()..sort();
}

void main() {
  group('Fixture-Vorbedingung (sonst prueft der Scrubber-Test nichts)', () {
    test('das Fixture-JPEG traegt die GPS-Tags wirklich im Byte-Strom', () {
      final original = _geotaggedJpeg();

      expect(_hasExifSegment(original), isTrue,
          reason: 'Ohne APP1-Exif-Segment waere das Fixture wertlos');
      expect(_gpsTagsIn(original), contains(_tagGpsLatitude));
      expect(_gpsTagsIn(original), contains(_tagGpsLongitude));
      expect(_gpsTagsIn(original), contains(_tagGpsAltitude));
      expect(_gpsTagsIn(original), contains(_tagGpsTimeStamp));

      final decoded = img.decodeImage(original)!;
      expect(decoded.exif.gpsIfd[_tagGpsLatitude]!.toDouble(), closeTo(52, 0.01));
      expect(decoded.exif.gpsIfd[_tagGpsLongitude]!.toDouble(), closeTo(13, 0.01));
    });
  });

  group('C4 · compressMealPhoto strippt Standortdaten', () {
    test('Ausgabe enthaelt keine GPS-Koordinaten mehr', () {
      final original = _geotaggedJpeg();

      final scrubbed = compressMealPhoto(original);

      expect(_gpsTagsIn(scrubbed), isEmpty,
          reason: 'Breitengrad/Laengengrad/Hoehe duerfen das Geraet nicht '
              'verlassen');
    });

    test('Ausgabe traegt ueberhaupt kein EXIF-Segment mehr im Byte-Strom', () {
      final original = _geotaggedJpeg();

      final scrubbed = compressMealPhoto(original);

      expect(_hasExifSegment(scrubbed), isFalse,
          reason: 'Auch Geraetemodell, Seriennummer und Aufnahmezeit gehoeren '
              'nicht in den Upload');
    });

    test('grosse geotaggte Fotos verlieren GPS auch nach dem Verkleinern', () {
      final original = _geotaggedJpeg(width: 2400, height: 1800);

      final scrubbed = compressMealPhoto(original);
      final decoded = img.decodeImage(scrubbed)!;

      expect(decoded.width, 1600);
      expect(_gpsTagsIn(scrubbed), isEmpty);
      expect(_hasExifSegment(scrubbed), isFalse);
    });

    test(
        'kleine geotaggte Fotos werden NICHT durchgereicht, nur weil die '
        'Re-Kompression Bytes kostet', () {
      // The byte-saving branch must not be a loophole: a small, heavily
      // compressed photo with GPS would otherwise go out unchanged, because
      // re-encoding comes out larger.
      final original = _geotaggedJpeg(width: 320, height: 240, quality: 40);

      final scrubbed = compressMealPhoto(original);

      expect(scrubbed, isNot(same(original)));
      expect(_gpsTagsIn(scrubbed), isEmpty);
      expect(_hasExifSegment(scrubbed), isFalse);
    });

    test('Orientierung wird VOR dem Leeren eingebacken, Bild bleibt richtig '
        'herum', () {
      // Orientation 6 (90 degrees CW): left red, right blue, so after rotating
      // red must be on TOP. Clearing EXIF before baking would leave the image
      // landscape.
      final original =
          _geotaggedJpeg(width: 480, height: 240, orientation: 6);

      final scrubbed = compressMealPhoto(original);
      final decoded = img.decodeImage(scrubbed)!;

      expect(decoded.width, 240);
      expect(decoded.height, 480);
      final top = decoded.getPixel(decoded.width ~/ 2, 10);
      final bottom = decoded.getPixel(decoded.width ~/ 2, decoded.height - 10);
      expect(top.r, greaterThan(180));
      expect(top.b, lessThan(80));
      expect(bottom.b, greaterThan(180));
      expect(bottom.r, lessThan(80));

      expect(_gpsTagsIn(scrubbed), isEmpty);
      expect(_hasExifSegment(scrubbed), isFalse);
    });

    test('EXIF-freie Bilder bleiben unveraendert (kein unnoetiges Aufblaehen)',
        () {
      final image = img.Image(width: 640, height: 480);
      img.fill(image, color: img.ColorRgb8(120, 180, 90));
      final original = Uint8List.fromList(img.encodeJpg(image, quality: 60));

      final result = compressMealPhoto(original);

      expect(_hasExifSegment(result), isFalse);
      expect(result.lengthInBytes, lessThanOrEqualTo(original.lengthInBytes));
    });
  });
}
