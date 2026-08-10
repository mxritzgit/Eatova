import 'dart:developer' as dev;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'meal_photo_compressor.dart';

/// Lokale Ablage fuer selbst fotografierte Rezept-Bilder.
///
/// **Warum lokal und nicht Supabase Storage.** Das Projekt hat bis heute
/// keinen Bucket und keine Storage-Policies. Eine Cloud-Anbindung braeuchte
/// beides plus eine eigene Warteschlange fuer Bytes (die [SyncOp]-Outbox
/// traegt JSON, keine Megabytes) — und die Persistenzschicht ist gerade erst
/// repariert worden. Deshalb die ehrliche Variante: die Bytes liegen im
/// App-Dokumentenverzeichnis dieses Geraets, und das Rezept sagt das auch.
///
/// **Der Marker.** [FitnessRecipe.imageAsset] traegt fuer ein eigenes Foto
/// `local:<slug>.jpg` statt eines Asset-Pfades. Das Feld wandert unveraendert
/// durch `toRow()/fromRow()` (Wire-Format von `user_recipes` UND Cache-Format)
/// — ein ZWEITES Geraet liest die Referenz, findet die Datei nicht und faellt
/// sichtbar auf den Platzhalter zurueck, statt einen toten Pfad zu laden.
/// Alte Zeilen ohne Bild tragen weiterhin `''` und laufen durch denselben
/// Zweig; abwaertskompatibel, weil kein neues Feld entsteht.
///
/// **Der Dateiname** leitet sich stabil vom Rezept-Slug ab. Nichts muss
/// zusaetzlich persistiert werden: Slug rein, Pfad raus, ein Neustart findet
/// dieselbe Datei wieder.
///
/// **EXIF ist Pflicht.** Ein Kuechenfoto traegt sonst die GPS-Koordinaten der
/// Wohnung — und im Unterschied zum Upload-Pfad dauerhaft auf der Platte.
/// [save] laesst deshalb JEDE Byte-Folge durch [compressMealPhoto] (dieselbe
/// Pipeline wie Kamera-Sheet, Galerie-Auswahl und Coach-Chat) und legt nur
/// deren Ergebnis ab. Nicht dekodierbare Bytes werden fail-closed VERWORFEN,
/// nicht ungescrubbt durchgereicht.
class RecipeImageStore {
  RecipeImageStore({Future<Directory> Function()? baseDirectory})
      : _resolveBaseDirectory = baseDirectory ?? _appDocumentsFolder;

  /// Praefix, das eine lokal abgelegte Datei von einem Bundle-Asset trennt.
  static const String referencePrefix = 'local:';

  /// Unterordner im App-Dokumentenverzeichnis.
  static const String folderName = 'recipe_images';

  final Future<Directory> Function() _resolveBaseDirectory;

  /// Gecacht nach dem ersten erfolgreichen Aufloesen — danach kommt
  /// [resolveSync] ohne await aus und die Bildkacheln bauen flackerfrei.
  Directory? _base;

  /// Kein Ablageort verfuegbar (z.B. Plugin-Channel fehlt im Widget-Test).
  /// Dann liefert der Store still null statt bei jedem Bild neu zu scheitern.
  bool _baseUnavailable = false;

  Future<Directory?>? _inFlight;

  // --- Prozessweite Instanz -------------------------------------------------
  // Die Bildkacheln (`_RecipeImage`) liegen tief im Baum und teils hinter
  // einem Routen-Push (Detail-Ansicht) — ein InheritedWidget erreicht sie
  // nicht. Deshalb eine Instanz, die Tests austauschen koennen.

  static RecipeImageStore _instance = RecipeImageStore();

  static RecipeImageStore get instance => _instance;

  @visibleForTesting
  static set instance(RecipeImageStore store) => _instance = store;

  @visibleForTesting
  static void resetInstance() => _instance = RecipeImageStore();

  // --- Referenzen -----------------------------------------------------------

  /// True, wenn [imageAsset] auf eine hier abgelegte Datei zeigt.
  static bool isLocalReference(String imageAsset) =>
      imageAsset.startsWith(referencePrefix);

  /// Die Referenz, die ein Rezept mit dem Slug [slug] traegt.
  static String referenceForSlug(String slug) =>
      '$referencePrefix${_fileNameForSlug(slug)}';

  /// Dateiname aus einer Referenz — null, wenn es keine eigene ist.
  ///
  /// Der Name wird beim Lesen NOCHMALS gesaeubert: eine Referenz kann aus
  /// einer Serverzeile stammen, und ein `../` darin duerfte den Ordner nie
  /// verlassen.
  static String? _fileNameFor(String imageAsset) {
    if (!isLocalReference(imageAsset)) return null;
    final raw = imageAsset.substring(referencePrefix.length);
    if (raw.isEmpty) return null;
    return _sanitize(raw);
  }

  static String _fileNameForSlug(String slug) => '${_sanitize(slug)}.jpg';

  /// Nur `A-Z a-z 0-9 _ - .` ueberleben; alles andere wird zu `_`. Damit kann
  /// weder ein Pfadtrenner noch ein `..`-Segment entstehen.
  static String _sanitize(String value) {
    final buffer = StringBuffer();
    for (final code in value.codeUnits) {
      final isDigit = code >= 0x30 && code <= 0x39;
      final isUpper = code >= 0x41 && code <= 0x5A;
      final isLower = code >= 0x61 && code <= 0x7A;
      final isSafePunct = code == 0x5F || code == 0x2D; // _ -
      final isDot = code == 0x2E;
      buffer.writeCharCode(
        isDigit || isUpper || isLower || isSafePunct || isDot ? code : 0x5F,
      );
    }
    // `..` bliebe sonst als Segment stehen (Punkte sind fuer die Endung noetig).
    final safe = buffer.toString().replaceAll('..', '__');
    return safe.isEmpty ? 'rezept' : safe;
  }

  // --- Lesen ----------------------------------------------------------------

  /// Die Datei zu [imageAsset] — null, wenn es keine eigene Referenz ist, der
  /// Ablageort fehlt oder die Bytes auf diesem Geraet nie ankamen.
  Future<File?> resolve(String imageAsset) async {
    final name = _fileNameFor(imageAsset);
    if (name == null) return null;
    final base = await _ensureBase();
    if (base == null) return null;
    final file = File('${base.path}/$name');
    return await file.exists() ? file : null;
  }

  /// Wie [resolve], aber ohne await — liefert null, solange der Ablageort noch
  /// nicht aufgeloest ist. Erlaubt der Bildkachel, im ersten Frame schon das
  /// richtige Bild zu zeigen, statt einen Platzhalter aufblitzen zu lassen.
  File? resolveSync(String imageAsset) {
    final name = _fileNameFor(imageAsset);
    final base = _base;
    if (name == null || base == null) return null;
    final file = File('${base.path}/$name');
    return file.existsSync() ? file : null;
  }

  /// True, sobald feststeht, ob es einen Ablageort gibt — danach ist
  /// [resolveSync] verlaesslich.
  bool get baseResolved => _base != null || _baseUnavailable;

  // --- Schreiben ------------------------------------------------------------

  /// Legt [bytes] als Bild des Rezepts [slug] ab und liefert die Referenz fuer
  /// `FitnessRecipe.imageAsset`. null heisst: nicht abgelegt (kein Ablageort,
  /// nicht dekodierbar, Schreibfehler) — der Aufrufer speichert das Rezept
  /// dann ohne Bild statt mit einer Referenz ins Leere.
  Future<String?> save({required String slug, required Uint8List bytes}) async {
    final base = await _ensureBase();
    if (base == null) return null;

    final Uint8List scrubbed;
    try {
      scrubbed = await _scrub(bytes);
    } catch (e) {
      // FAIL-CLOSED: lieber kein Bild als eines mit Standortdaten.
      dev.log('RecipeImageStore: Bild nicht dekodierbar — nicht abgelegt',
          error: e, name: 'recipe_image_store');
      return null;
    }

    final reference = referenceForSlug(slug);
    try {
      // Der Ordner entsteht erst hier — Lesen legt bewusst nichts an, sonst
      // haette `clear()` ihn direkt danach wieder auf der Platte.
      if (!await base.exists()) await base.create(recursive: true);
      final file = File('${base.path}/${_fileNameFor(reference)}');
      await file.writeAsBytes(scrubbed, flush: true);
      return reference;
    } catch (e, s) {
      dev.log('RecipeImageStore: Schreiben fehlgeschlagen',
          error: e, stackTrace: s, name: 'recipe_image_store');
      return null;
    }
  }

  /// EXIF leeren, Orientierung einbacken, laengste Kante deckeln — dieselbe
  /// Funktion wie im Upload-Pfad. `compute()`, damit Dekodieren + Re-Encoden
  /// nicht den UI-Isolate blockiert; scheitert der Isolate-Start, wird synchron
  /// gescrubbt (ein Ruckler ist besser als ein Foto mit Koordinaten).
  Future<Uint8List> _scrub(Uint8List raw) async {
    try {
      return await compute(compressMealPhoto, raw);
    } on FormatException {
      rethrow; // nicht dekodierbar — der Aufrufer verwirft.
    } catch (_) {
      return compressMealPhoto(raw);
    }
  }

  // --- Aufraeumen -----------------------------------------------------------

  /// Loescht das Bild zu [imageAsset]. No-Op fuer Bundle-Assets und leere
  /// Referenzen. Laeuft beim Loeschen eines Eigen-Rezepts.
  Future<void> deleteFor(String imageAsset) async {
    final name = _fileNameFor(imageAsset);
    if (name == null) return;
    final base = await _ensureBase();
    if (base == null) return;
    try {
      final file = File('${base.path}/$name');
      if (await file.exists()) await file.delete();
    } catch (e) {
      dev.log('RecipeImageStore: Loeschen fehlgeschlagen',
          error: e, name: 'recipe_image_store');
    }
  }

  /// Raeumt den kompletten Ordner.
  ///
  /// Rezept-Fotos sind PII (ein Kuechenfoto zeigt die Wohnung) und muessen
  /// beim Ausloggen bzw. der Konto-Loeschung genauso verschwinden wie die
  /// uebrigen Slots in `LocalCache.clear()`.
  Future<void> clear() async {
    final base = await _ensureBase();
    if (base == null) return;
    try {
      if (await base.exists()) await base.delete(recursive: true);
    } catch (e) {
      dev.log('RecipeImageStore: Raeumen fehlgeschlagen',
          error: e, name: 'recipe_image_store');
    }
    // [_base] bleibt stehen: der PFAD ist weiter gueltig, nur der Ordner ist
    // weg. Das naechste [save] legt ihn wieder an.
  }

  // --- Ablageort ------------------------------------------------------------

  Future<Directory?> _ensureBase() {
    final known = _base;
    if (known != null) return Future<Directory?>.value(known);
    if (_baseUnavailable) return Future<Directory?>.value();
    return _inFlight ??= _openBase();
  }

  /// Loest den Pfad auf — legt den Ordner bewusst NICHT an. Das tut nur
  /// [save]; sonst brauechte ein blosser Lesezugriff Schreibrechte, und
  /// [clear] haette den Ordner beim naechsten Bild sofort wieder da.
  Future<Directory?> _openBase() async {
    try {
      final dir = await _resolveBaseDirectory();
      _base = dir;
      return dir;
    } catch (e, s) {
      // Kein Ablageort (fehlender Plugin-Channel im Widget-Test, volle Platte).
      // Die App laeuft ohne Bilder weiter — sie sind Beiwerk, kein Datum.
      dev.log('RecipeImageStore: kein Ablageort',
          error: e, stackTrace: s, name: 'recipe_image_store');
      _baseUnavailable = true;
      return null;
    } finally {
      _inFlight = null;
    }
  }

  static Future<Directory> _appDocumentsFolder() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/$folderName');
  }
}
