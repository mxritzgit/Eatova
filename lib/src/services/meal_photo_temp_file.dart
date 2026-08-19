import 'dart:io';

/// Loescht die Temp-Datei, die Kamera bzw. Galerie-Picker fuer ein Essensfoto
/// im App-Cache anlegen — aufzurufen, sobald deren Bytes gelesen und ueber
/// `compressMealPhoto` gescrubbt sind.
///
/// DATENSCHUTZ (Review 2026-08-19): `CameraController.takePicture()` schreibt
/// sein JPEG in ein Temp-Verzeichnis, und `ImagePicker.pickImage` legt seine
/// skalierte Kopie im Cache-Verzeichnis ab. Die App braucht davon nur die
/// Bytes; aufgeraeumt hat die Dateien bisher niemand. Sie ueberdauerten damit
/// den Scan, die Abmeldung und auch die Kontoloeschung — das Betriebssystem
/// raeumt den Cache erst unter Speicherdruck. Es geht nicht um Speicherplatz,
/// sondern um Essensfotos, die der Nutzer laengst wieder losgeworden glaubt.
///
/// Betroffen ist immer nur die KOPIE des Plugins im App-Cache, nie das
/// Original in der Galerie: `image_picker` re-encodiert wegen der gesetzten
/// `imageQuality`/`maxWidth` grundsaetzlich in eine eigene Cache-Datei. Auf
/// Desktop-Plattformen reicht `image_picker` dagegen den vom Dateidialog
/// gewaehlten Originalpfad durch — Eatova baut nur Android/iOS, deshalb ist
/// dieser Helfer dort und nur dort verdrahtet.
///
/// Ein Fehlschlag ist bewusst KEIN Fehlerfall fuer den Aufrufer: der
/// In-Memory-Weg (`XFile.fromData`) hat gar keine Datei, ein zweiter Aufruf
/// auf demselben Pfad findet nichts mehr, und die Bytes liegen zu diesem
/// Zeitpunkt ohnehin schon im Speicher.
Future<void> deleteMealPhotoTempFile(String path) async {
  if (path.isEmpty) return;
  try {
    await File(path).delete();
  } catch (_) {
    // Schon geloescht, keine Rechte, anderer Prozess: der Scan laeuft weiter.
  }
}
