import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/services/meal_photo_compressor.dart';

/// Baut ein JPEG-Fixture: [width]x[height], linke Haelfte rot, rechte blau.
/// Optional mit gesetzter EXIF-Orientierung (wie es Kamera-JPEGs tragen).
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

void main() {
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
    // Orientation 6 = 90 Grad im Uhrzeigersinn drehen: ein 2000x1000-Buffer,
    // der als Hochkant-Foto (1000x2000) angezeigt werden soll — genau das
    // liefert eine Smartphone-Kamera im Portrait-Modus. (Der JPEG-Decoder von
    // package:image backt den Tag beim Dekodieren selbst ein; entscheidend
    // ist hier das ENDE-zu-ENDE-Verhalten von compressMealPhoto: Ausgabe-
    // Pixel physisch richtig gedreht, kein Orientation-Tag mehr im Ergebnis.)
    final original = _jpegFixture(2000, 1000, exifOrientation: 6);

    final compressed = compressMealPhoto(original);
    final decoded = img.decodeImage(compressed)!;

    // Pixel physisch gedreht: aus 2000x1000 (liegend) wird Hochkant und
    // danach auf 1600 px laengste Kante verkleinert.
    expect(decoded.width, 800);
    expect(decoded.height, 1600);
    // Bei 90-Grad-CW-Drehung wandert die linke (rote) Haelfte nach oben.
    final top = decoded.getPixel(decoded.width ~/ 2, 10);
    final bottom = decoded.getPixel(decoded.width ~/ 2, decoded.height - 10);
    expect(top.r, greaterThan(180));
    expect(top.b, lessThan(80));
    expect(bottom.b, greaterThan(180));
    expect(bottom.r, lessThan(80));
    // Keine EXIF-Orientierung mehr im Ergebnis: sonst wuerden EXIF-treue
    // Viewer das bereits gedrehte Bild ein zweites Mal drehen.
    final orientation = decoded.exif.imageIfd.orientation;
    expect(orientation == null || orientation == 1, isTrue,
        reason: 'Orientierung muss nach dem Einbacken neutral sein, '
            'war: $orientation');
  });

  test(
      'Sentinel-Rest S2: nicht dekodierbare Bytes WERFEN — ungescrubbt '
      'verlaesst nichts das Geraet', () {
    // Die erste Fassung dieses Tests pinnte das Gegenteil (`same(garbage)`):
    // was der Decoder nicht lesen konnte, ging mit GPS, Geraete-Kennung und
    // Aufnahmezeit unveraendert an die Edge Function und den US-Anbieter —
    // waehrend PRIVACY.md und eatova.de/datenschutz das Scrubbing als
    // Eigenschaft JEDES Uploads zusichern. Fail-closed: werfen. Die
    // Aufrufer sind wurf-sicher (Kamera-/Galerie-Sheet zeigen eine
    // Fehlermeldung, der Coach haengt kein Bild an, der Analyzer wirft bei
    // fehlenden Bytes ohnehin).
    final garbage = Uint8List.fromList(List<int>.generate(64, (i) => i));

    expect(() => compressMealPhoto(garbage), throwsFormatException);
  });

  test('bereits kleine, stark komprimierte Bilder werden nicht aufgeblaeht',
      () {
    // q60-Fixture unter 1600 px: eine q85-Re-Kompression wuerde die Datei
    // vergroessern — dann soll das Original unveraendert zurueckkommen.
    final image = img.Image(width: 640, height: 480);
    img.fill(image, color: img.ColorRgb8(120, 180, 90));
    final original = Uint8List.fromList(img.encodeJpg(image, quality: 60));

    final result = compressMealPhoto(original);

    expect(result.lengthInBytes, lessThanOrEqualTo(original.lengthInBytes));
  });
}
