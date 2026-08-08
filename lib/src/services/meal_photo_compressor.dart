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
/// DATENSCHUTZ (Review C4): die Funktion ist ausserdem der EXIF-Scrubber fuer
/// jedes Bild, das die App verlaesst. Weder `image_picker` noch der
/// JPEG-Decoder von package:image entfernen Metadaten:
/// `ImageResizer.java:66` kopiert nach dem Skalieren eine explizite Tag-Liste
/// inklusive GPS-Breitengrad/-Laengengrad/-Hoehe/-Zeitstempel zurueck, und
/// `_jpeg_quantize_io.dart:224` uebernimmt beim Dekodieren den kompletten
/// EXIF-Container (`ExifData.from`) und nullt daran nur `orientation` — das
/// `gps`-Sub-IFD ueberlebt und wird von `jpeg_encoder.dart:61`
/// (`_writeExif(fp, image.exif)`) wieder in die Ausgabe geschrieben. Ein aus
/// der Galerie gewaehltes Foto der Systemkamera traegt damit die Koordinaten
/// des Restaurants bis zur Edge Function und zum Drittanbieter-Modell.
///
/// Deshalb wird der Container hier vollstaendig geleert — nicht nur GPS, auch
/// Geraetemodell, Seriennummer und Aufnahmezeit. Das ICC-Profil bleibt: es
/// beschreibt Farben, keine Person. Die Reihenfolge ist zwingend
/// bake -> resize -> leeren: [img.bakeOrientation] liest die Orientierung aus
/// `image.exif` (`bake_orientation.dart:12-21`); wer vorher leert, bekommt ein
/// liegendes Foto.
///
/// Rein funktional (keine Plugins, kein IO) — laeuft ueber `compute()` in
/// einem Isolate und ist in VM-Tests direkt testbar.
///
/// RESTRISIKO: nicht dekodierbare Bytes gehen unveraendert (und damit
/// ungescrubbt) raus. Beide Aufrufer schliessen das praktisch aus — der
/// Kamera-Pfad liefert JPEG, und der Galerie-Pfad laesst `image_picker` mit
/// `imageQuality`/`maxWidth` erst nach JPEG konvertieren (genau deshalb
/// duerfen diese Optionen dort nicht entfallen: ohne sie reicht iOS die
/// HEIC-Originaldatei durch, die package:image nicht dekodieren kann).
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
  // Vor dem Leeren merken: traegt die Quelle ueberhaupt Metadaten? Nur dann
  // ist die Re-Kompression unten alternativlos.
  final hadExif = !decoded.exif.isEmpty;
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

  // Jetzt — nach dem Einbacken der Orientierung und nach dem Skalieren —
  // faellt der gesamte Metadaten-Container weg. `jpeg_encoder.dart:657`
  // ueberspringt das APP1-Segment bei leerem Container komplett, die Ausgabe
  // enthaelt danach also gar kein EXIF mehr.
  image.exif = img.ExifData();

  final encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  // Verkleinert, gedreht ODER mit Metadaten behaftet: das Ergebnis ist
  // fachlich bzw. datenschutzrechtlich das richtige Bild und wird uebernommen,
  // auch wenn es groesser ausfaellt. Der Byte-Spar-Zweig darf kein
  // Schlupfloch fuer GPS sein — er greift nur, wenn im Original ohnehin keine
  // Metadaten stehen (dann ist das Original bereits sauber).
  if (resized || hadOrientation || hadExif) return encoded;
  return encoded.lengthInBytes < original.lengthInBytes ? encoded : original;
}
