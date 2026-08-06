import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Re-Kompression fuer KI-Scan-Fotos aus der In-App-Kamera.
///
/// Das `camera`-Plugin liefert rohe JPEGs (veryHigh ~1080p, hohe Qualitaet)
/// ohne die Verkleinerung, die der Galerie-Pfad ueber `image_picker`
/// (imageQuality: 85, maxWidth: 1600) bereits macht. Vor dem Versand an die
/// analyze-meal Edge Function (5-MB-Cap, Base64 = +33%) wird das Foto hier auf
/// dieselben Werte gebracht: laengste Kante <= [maxDimension] px, JPEG q[quality].
///
/// WICHTIG: [img.bakeOrientation] backt die EXIF-Orientierung in die Pixel ein,
/// BEVOR skaliert wird — Vorschau, LLM-Input und jede spaetere Anzeige sehen
/// das Bild richtig herum, auch wenn ein Viewer EXIF ignoriert. Der
/// Rotations-Fix aus 7e39cff (Capture-Orientation-Lock) bleibt damit intakt.
///
/// Rein funktional (keine Plugins, kein IO) — laeuft ueber `compute()` in
/// einem Isolate und ist in VM-Tests direkt testbar. Nicht dekodierbare Bytes
/// werden unveraendert zurueckgegeben (der Server validiert ohnehin).
Uint8List compressMealPhoto(
  Uint8List original, {
  int maxDimension = 1600,
  int quality = 85,
}) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(original);
  } catch (_) {
    return original;
  }
  if (decoded == null) return original;

  // JPEGs (Kamera-Pfad) kommen aus decodeImage bereits eingebacken zurueck:
  // der JPEG-Decoder von package:image wendet die EXIF-Orientierung beim
  // Dekodieren auf die Pixel an und nullt den Orientation-Tag. bakeOrientation
  // ist das Sicherheitsnetz fuer Formate, deren Decoder das nicht tun — und
  // wird uebersprungen, wenn kein Tag (mehr) da ist, um die sonst anfallende
  // volle Buffer-Kopie zu sparen.
  final hadOrientation = decoded.exif.imageIfd.hasOrientation &&
      decoded.exif.imageIfd.orientation != 1;
  var image = hadOrientation ? img.bakeOrientation(decoded) : decoded;

  final longestSide =
      image.width >= image.height ? image.width : image.height;
  final resized = longestSide > maxDimension;
  if (resized) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxDimension : null,
      height: image.width >= image.height ? null : maxDimension,
      interpolation: img.Interpolation.linear,
    );
  }

  final encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  // Verkleinert oder gedreht: das Ergebnis ist fachlich das richtige Bild.
  // Sonst nur uebernehmen, wenn die Re-Kompression wirklich Bytes spart
  // (ein bereits kleines, staerker komprimiertes Bild nicht aufblaehen).
  if (resized || hadOrientation) return encoded;
  return encoded.lengthInBytes < original.lengthInBytes ? encoded : original;
}
