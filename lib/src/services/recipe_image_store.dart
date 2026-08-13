import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
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
/// `local:<name>.jpg` statt eines Asset-Pfades. Das Feld wandert unveraendert
/// durch `toRow()/fromRow()` (Wire-Format von `user_recipes` UND Cache-Format)
/// — ein ZWEITES Geraet liest die Referenz, findet die Datei nicht und faellt
/// sichtbar auf den Platzhalter zurueck, statt einen toten Pfad zu laden.
/// Alte Zeilen ohne Bild tragen weiterhin `''` und laufen durch denselben
/// Zweig; abwaertskompatibel, weil kein neues Feld entsteht.
///
/// **Ein Namensraum pro Nutzer (Security-Review 2026-08-11, Finding 5).**
/// Frueher lagen alle Dateien flach in `recipe_images/` und der Name leitete
/// sich aus dem Slug ab (`user_<ms>` — Millisekunden sind erratbar). Ein
/// SPAETER auf demselben Geraet angemeldetes Konto konnte ein eigenes Rezept
/// mit einer geratenen Referenz anlegen und bekam das Kuechenfoto des
/// Vorgaengers gerendert — `fromRow()` reicht `image_asset` ungeprueft durch.
/// Jetzt gilt:
///
///   * Die Dateien liegen unter `recipe_images/<uid>/`; [resolve], [save]
///     und [deleteFor] arbeiten NUR im Namensraum der via [setActiveUser]
///     gebundenen User-ID. Ohne angemeldeten Nutzer keine Aufloesung und
///     keine Ablage (fail-closed).
///   * Neue Dateien bekommen einen Namen aus [Random.secure] — nichts
///     Slug- oder Zeit-Abgeleitetes, nichts Erratbares.
///   * Ein Identitaetswechsel innerhalb der Prozess-Laufzeit (anderer User
///     ODER Session-Verlust, nicht nur das explizite Abmelden) purgt den
///     Namensraum des Vorgaengers sofort — s. [setActiveUser]. Den Haken
///     setzt der AuthGate zentral fuer JEDEN Auth-Uebergang.
///   * Alt-Bestand (flache Dateien aus der Zeit vor den Namensraeumen)
///     wandert beim ersten Zugriff in den Namensraum des dann angemeldeten
///     Nutzers: das Geraet war bisher de facto EIN Namensraum, der erste
///     Angemeldete „erbt" ihn — nicht schlechter als der Status quo, aber
///     die Fotos der Bestandsnutzer bleiben erhalten.
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

  /// Wurzel-Unterordner im App-Dokumentenverzeichnis. Darunter liegt pro
  /// Nutzer ein eigener Namensraum `recipe_images/<uid>/`.
  static const String folderName = 'recipe_images';

  final Future<Directory> Function() _resolveBaseDirectory;

  /// Wurzel (`recipe_images/`), gecacht nach dem ersten Aufloesen.
  Directory? _root;

  /// Kein Ablageort verfuegbar (z.B. Plugin-Channel fehlt im Widget-Test).
  /// Dann liefert der Store still null statt bei jedem Bild neu zu scheitern.
  bool _rootUnavailable = false;

  Future<Directory?>? _rootInFlight;

  /// Die User-ID, an die der Store gerade gebunden ist — null heisst: niemand
  /// ist angemeldet, und resolve/save/deleteFor verweigern (fail-closed).
  String? _activeUserId;

  /// Namensraum-Verzeichnis, aufgeloest UND legacy-migriert, gueltig fuer
  /// [_namespaceUserId]. Nach dem ersten Aufloesen kommt [resolveSync] ohne
  /// await aus und die Bildkacheln bauen flackerfrei.
  Directory? _namespace;
  String? _namespaceUserId;
  Future<Directory?>? _namespaceInFlight;
  String? _namespaceInFlightUserId;

  /// Wartungs-Kette: Purge (Identitaetswechsel), Legacy-Migration und
  /// [clear] laufen strikt NACHEINANDER. Ohne die Kette koennte die Migration
  /// eines Wechsels A→B die flachen Alt-Dateien noch schnell in Bs Namensraum
  /// ziehen, bevor der Purge sie wegraeumt — genau das Leck, das dieser
  /// Umbau schliesst.
  Future<void> _maintenance = Future<void>.value();

  Future<T> _afterMaintenance<T>(Future<T> Function() action) {
    final run = _maintenance.then((_) => action());
    // Die Aktionen fangen intern alles; der catchError ist die Notbremse,
    // damit ein Fehler die Kette nicht fuer immer vergiftet.
    _maintenance = run.then<void>((_) {}).catchError((Object _) {});
    return run;
  }

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

  // --- Identitaets-Bindung --------------------------------------------------

  /// Bindet den Store an die User-ID [userId] — null heisst: niemand ist
  /// angemeldet.
  ///
  /// Der Wechsel des Namensraums passiert SYNCHRON (vor dem ersten await):
  /// ab der Rueckkehr dieses Aufrufs loest kein resolve mehr in den alten
  /// Namensraum auf, egal ob das Purgen dahinter noch laeuft.
  ///
  /// Bei einem Identitaetswechsel innerhalb der Prozess-Laufzeit — vorher war
  /// ein ANDERER Nutzer gebunden; auch der Uebergang zu null (Session-Verlust,
  /// serverseitiger Widerruf) zaehlt — wird der Namensraum des Vorgaengers
  /// lokal gepurgt. FAIL-CLOSED und bewusst auch dann, wenn derselbe Nutzer
  /// sich gleich wieder anmeldet: im Zweifel ist kein Foto besser als eines,
  /// das dem naechsten Konto auf diesem Geraet in die Haende faellt. Das
  /// explizite Abmelden raeumt zusaetzlich ueber [clear]
  /// (home_store_sync.signOutCleanup) — die beiden Wege sind idempotent.
  ///
  /// Ein Kaltstart mit Session-Restore laeuft ueber `null -> <uid>` und purgt
  /// NICHTS — sonst ueberlebte kein Foto einen App-Neustart.
  Future<void> setActiveUser(String? userId) {
    final previous = _activeUserId;
    if (previous == userId) return Future<void>.value();
    _activeUserId = userId;
    if (_namespaceUserId != userId) {
      _namespace = null;
      _namespaceUserId = null;
    }
    // Erster gebundener Nutzer dieses Prozesses: nichts zu purgen. Die
    // flachen Alt-Dateien bleiben liegen, bis seine Migration sie erbt.
    if (previous == null) return Future<void>.value();
    return _afterMaintenance(() => _purgeNamespace(previous));
  }

  @visibleForTesting
  String? get activeUserId => _activeUserId;

  // --- Referenzen -----------------------------------------------------------

  /// True, wenn [imageAsset] auf eine hier abgelegte Datei zeigt.
  static bool isLocalReference(String imageAsset) =>
      imageAsset.startsWith(referencePrefix);

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

  /// Name fuer eine NEUE Datei: 128 Bit aus [Random.secure] als Hex.
  ///
  /// Frueher leitete sich der Name aus dem Slug ab (`user_<ms>.jpg`) —
  /// Millisekunden sind vorhersagbar, und eine fremde Serverzeile konnte so
  /// gezielt die Datei eines frueheren Nutzers referenzieren (Finding 5).
  /// Persistiert werden muss trotzdem nichts extra: die Referenz selbst
  /// wandert im Rezept-Feld `image_asset` mit.
  static String _randomFileName() {
    final rng = Random.secure();
    final hex = StringBuffer();
    for (var i = 0; i < 16; i++) {
      hex.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return 'img_$hex.jpg';
  }

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

  /// Die Datei zu [imageAsset] — null, wenn es keine eigene Referenz ist, KEIN
  /// Nutzer angemeldet ist, der Ablageort fehlt oder die Bytes auf diesem
  /// Geraet (in DIESEM Namensraum) nie ankamen.
  Future<File?> resolve(String imageAsset) async {
    final name = _fileNameFor(imageAsset);
    if (name == null) return null;
    final namespace = await _ensureNamespace();
    if (namespace == null) return null;
    final file = File('${namespace.path}/$name');
    return await file.exists() ? file : null;
  }

  /// Wie [resolve], aber ohne await — liefert null, solange der Namensraum
  /// noch nicht aufgeloest (und der Alt-Bestand migriert) ist. Erlaubt der
  /// Bildkachel, im ersten Frame schon das richtige Bild zu zeigen, statt
  /// einen Platzhalter aufblitzen zu lassen.
  File? resolveSync(String imageAsset) {
    final name = _fileNameFor(imageAsset);
    final namespace = _syncNamespace();
    if (name == null || namespace == null) return null;
    final file = File('${namespace.path}/$name');
    return file.existsSync() ? file : null;
  }

  /// Der Namensraum fuer synchrone Zugriffe — nur wenn er zur AKTUELL
  /// gebundenen User-ID gehoert. Nach einem Wechsel ist der alte Eintrag
  /// damit sofort unwirksam, auch bevor das Purgen durch ist.
  Directory? _syncNamespace() {
    final uid = _activeUserId;
    if (uid == null) return null;
    if (_namespaceUserId != uid) return null;
    return _namespace;
  }

  /// True, sobald feststeht, was [resolveSync] antworten wird — entweder ist
  /// der Namensraum des aktiven Nutzers bereit, oder die Antwort ist
  /// verlaesslich null (kein Ablageort, niemand angemeldet).
  bool get baseResolved {
    if (_rootUnavailable) return true;
    final uid = _activeUserId;
    if (uid == null) return true;
    return _namespace != null && _namespaceUserId == uid;
  }

  // --- Schreiben ------------------------------------------------------------

  /// Legt [bytes] als Rezept-Bild ab und liefert die Referenz fuer
  /// `FitnessRecipe.imageAsset`. null heisst: nicht abgelegt (niemand
  /// angemeldet, kein Ablageort, nicht dekodierbar, Schreibfehler) — der
  /// Aufrufer speichert das Rezept dann ohne Bild statt mit einer Referenz
  /// ins Leere.
  Future<String?> save({required Uint8List bytes}) async {
    final namespace = await _ensureNamespace();
    if (namespace == null) return null;

    final Uint8List scrubbed;
    try {
      scrubbed = await _scrub(bytes);
    } catch (e) {
      // FAIL-CLOSED: lieber kein Bild als eines mit Standortdaten.
      dev.log('RecipeImageStore: Bild nicht dekodierbar — nicht abgelegt',
          error: e, name: 'recipe_image_store');
      return null;
    }

    final name = _randomFileName();
    try {
      // Der Ordner entsteht erst hier — Lesen legt bewusst nichts an, sonst
      // haette `clear()` ihn direkt danach wieder auf der Platte.
      if (!await namespace.exists()) await namespace.create(recursive: true);
      final file = File('${namespace.path}/$name');
      await file.writeAsBytes(scrubbed, flush: true);
      return '$referencePrefix$name';
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

  // --- /rezept-Vorschlagsbilder (Nachtrag 2026-08-13) -----------------------
  // Das KI-Bild eines Coach-Rezept-Vorschlags soll den Reload ueberleben:
  // das Rezept-JSON kommt aus chat_messages.recipe zurueck, die Bytes liegen
  // HIER — unter einem DETERMINISTISCHEN Namen pro Chat-Message-Id, damit
  // die Karte ihr Bild ohne eigenen Index wiederfindet. Gleiche
  // Lebensdauer-Regeln wie Rezept-Fotos (Namensraum pro User, Purge bei
  // Identitaetswechsel, clear() beim Logout); zusaetzlich kappt jeder Save
  // den Bestand auf die juengsten [proposalImageCap] Dateien — Vorschlaege,
  // die nie uebernommen werden, sollen die Platte nicht fuellen.
  //
  // Kein EXIF-Scrub: die Bytes stammen aus der EIGENEN Image-API der
  // Function (maschinell erzeugtes JPEG, keine Kamera-Metadaten, keine
  // Koordinaten) — der [save]-Scrub gilt fuer NUTZER-Fotos. Beim Uebernehmen
  // ins Rezept laeuft trotzdem [save] (eigene Kopie, eigener Lebenszyklus).

  /// Obergrenze gleichzeitig vorgehaltener Vorschlagsbilder pro Nutzer.
  static const int proposalImageCap = 24;

  static const String _proposalPrefix = 'proposal_';

  /// `local:`-Referenz des Vorschlagsbilds zu [messageId] (chat_messages.id).
  static String proposalReference(String messageId) =>
      '$referencePrefix$_proposalPrefix${_sanitize(messageId)}.jpg';

  /// Legt das Vorschlagsbild ab. false = nicht abgelegt (niemand angemeldet,
  /// kein Ablageort, Schreibfehler) — die Karte lebt dann nur bis zum Reload,
  /// wie vor dem Nachtrag. Kappt danach den Bestand (aelteste zuerst).
  Future<bool> saveProposalImage({
    required String messageId,
    required Uint8List bytes,
  }) async {
    final namespace = await _ensureNamespace();
    if (namespace == null) return false;
    try {
      if (!await namespace.exists()) await namespace.create(recursive: true);
      final name = '$_proposalPrefix${_sanitize(messageId)}.jpg';
      final file = File('${namespace.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      await _pruneProposalImages(namespace);
      return true;
    } catch (e, s) {
      dev.log('RecipeImageStore: Vorschlagsbild nicht abgelegt',
          error: e, stackTrace: s, name: 'recipe_image_store');
      return false;
    }
  }

  /// Bytes des Vorschlagsbilds zu [messageId] — null, wenn es (auf diesem
  /// Geraet, in diesem Namensraum) nicht liegt.
  Future<Uint8List?> readProposalImage(String messageId) async {
    final file = await resolve(proposalReference(messageId));
    if (file == null) return null;
    try {
      return await file.readAsBytes();
    } catch (e) {
      dev.log('RecipeImageStore: Vorschlagsbild nicht lesbar',
          error: e, name: 'recipe_image_store');
      return null;
    }
  }

  /// Aelteste Vorschlagsbilder ueber [proposalImageCap] hinaus loeschen.
  /// Rezept-Fotos (img_*-Dateien) bleiben unberuehrt.
  Future<void> _pruneProposalImages(Directory namespace) async {
    try {
      final proposals = <File>[];
      await for (final entity in namespace.list(followLinks: false)) {
        if (entity is! File) continue;
        if (entity.uri.pathSegments.last.startsWith(_proposalPrefix)) {
          proposals.add(entity);
        }
      }
      if (proposals.length <= proposalImageCap) return;
      final dated = <(File, DateTime)>[];
      for (final file in proposals) {
        dated.add((file, (await file.stat()).modified));
      }
      dated.sort((a, b) => a.$2.compareTo(b.$2));
      for (final entry in dated.take(dated.length - proposalImageCap)) {
        try {
          await entry.$1.delete();
        } catch (_) {
          // Einzelner Fehlschlag: beim naechsten Save faellt die Datei erneut
          // unter den Cap-Kandidaten — kein Grund, den Save scheitern zu lassen.
        }
      }
    } catch (e) {
      dev.log('RecipeImageStore: Vorschlags-Prune fehlgeschlagen',
          error: e, name: 'recipe_image_store');
    }
  }

  // --- Aufraeumen -----------------------------------------------------------

  /// Loescht das Bild zu [imageAsset] im Namensraum des aktiven Nutzers.
  /// No-Op fuer Bundle-Assets, leere Referenzen und ohne angemeldeten Nutzer.
  /// Laeuft beim Loeschen eines Eigen-Rezepts.
  Future<void> deleteFor(String imageAsset) async {
    final name = _fileNameFor(imageAsset);
    if (name == null) return;
    final namespace = await _ensureNamespace();
    if (namespace == null) return;
    try {
      final file = File('${namespace.path}/$name');
      if (await file.exists()) await file.delete();
    } catch (e) {
      dev.log('RecipeImageStore: Loeschen fehlgeschlagen',
          error: e, name: 'recipe_image_store');
    }
  }

  /// Raeumt den kompletten Wurzel-Ordner — ALLE Namensraeume und den
  /// flachen Alt-Bestand.
  ///
  /// Rezept-Fotos sind PII (ein Kuechenfoto zeigt die Wohnung) und muessen
  /// beim Ausloggen bzw. der Konto-Loeschung genauso verschwinden wie die
  /// uebrigen Slots in `LocalCache.clear()`. Bewusst breiter als der
  /// Transitions-Purge in [setActiveUser]: wer sich abmeldet, laesst auf dem
  /// Geraet gar nichts zurueck.
  Future<void> clear() {
    // Ueber die Wartungs-Kette, damit keine parallel laufende Migration eine
    // Datei in einen Namensraum schiebt, waehrend der Ordner faellt.
    return _afterMaintenance(() async {
      final root = await _ensureRoot();
      if (root == null) return;
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (e) {
        dev.log('RecipeImageStore: Raeumen fehlgeschlagen',
            error: e, name: 'recipe_image_store');
      }
      // [_root]/[_namespace] bleiben stehen: die PFADE sind weiter gueltig,
      // nur die Ordner sind weg. Das naechste [save] legt sie wieder an.
    });
  }

  /// Purgt den Namensraum von [uid] und den flachen Alt-Bestand.
  ///
  /// Die flachen Dateien stammen aus der Zeit VOR den Namensraeumen und
  /// gehoeren damit dem bisherigen Geraete-Nutzer — beim Identitaetswechsel
  /// fallen sie mit, auch wenn seine Migration nie gelaufen ist (er hat die
  /// Rezepte schlicht nie geoeffnet). Fail-closed; Fehler werden geloggt,
  /// nie weitergereicht.
  Future<void> _purgeNamespace(String uid) async {
    final root = await _ensureRoot();
    if (root == null) return;
    try {
      final dir = Directory('${root.path}/${_sanitize(uid)}');
      if (await dir.exists()) await dir.delete(recursive: true);
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is File) await entity.delete();
        }
      }
    } catch (e, s) {
      dev.log('RecipeImageStore: Purge fehlgeschlagen',
          error: e, stackTrace: s, name: 'recipe_image_store');
    }
  }

  // --- Ablageort ------------------------------------------------------------

  /// Namensraum des aktiven Nutzers — aufgeloest und legacy-migriert. null,
  /// wenn niemand angemeldet ist oder es keinen Ablageort gibt.
  Future<Directory?> _ensureNamespace() {
    final uid = _activeUserId;
    if (uid == null) return Future<Directory?>.value();
    final known = _namespace;
    if (known != null && _namespaceUserId == uid) {
      return Future<Directory?>.value(known);
    }
    if (_rootUnavailable) return Future<Directory?>.value();
    final inFlight = _namespaceInFlight;
    if (inFlight != null && _namespaceInFlightUserId == uid) return inFlight;
    final future = _openNamespace(uid);
    _namespaceInFlight = future;
    _namespaceInFlightUserId = uid;
    return future;
  }

  Future<Directory?> _openNamespace(String uid) async {
    try {
      final root = await _ensureRoot();
      if (root == null) return null;
      final namespace = Directory('${root.path}/${_sanitize(uid)}');
      // In der Wartungs-Kette NACH einem evtl. anstehenden Purge: die
      // Migration eines neuen Nutzers darf keine Dateien erben, die der
      // Wechsel gerade wegraeumt.
      await _afterMaintenance(() => _migrateLegacyInto(root, namespace));
      // Waehrenddessen gewechselt? Dann gehoert das Ergebnis niemandem mehr.
      if (_activeUserId != uid) return null;
      _namespace = namespace;
      _namespaceUserId = uid;
      return namespace;
    } finally {
      if (_namespaceInFlightUserId == uid) {
        _namespaceInFlight = null;
        _namespaceInFlightUserId = null;
      }
    }
  }

  /// Alt-Bestand uebernehmen: vor den Namensraeumen lagen die Dateien FLACH
  /// in `recipe_images/`. Das Geraet war de facto EIN Namensraum — der erste
  /// angemeldete Nutzer erbt ihn. Die Referenzen in seinen Rezeptzeilen
  /// (`local:user_<ms>.jpg`) loesen danach unveraendert auf, weil nur der
  /// Ordner wechselt, nie der Dateiname.
  Future<void> _migrateLegacyInto(Directory root, Directory namespace) async {
    try {
      if (!await root.exists()) return;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          if (!await namespace.exists()) {
            await namespace.create(recursive: true);
          }
          final name = entity.uri.pathSegments.last;
          await entity.rename('${namespace.path}/$name');
        } catch (e) {
          // Nicht verschiebbar (Kollision, Rechte): liegen lassen. Flach ist
          // ab jetzt UNERREICHBAR — [resolve] liest nur Namensraeume — und
          // der naechste Identitaetswechsel bzw. [clear] raeumt die Datei weg.
          dev.log('RecipeImageStore: Legacy-Datei nicht migriert',
              error: e, name: 'recipe_image_store');
        }
      }
    } catch (e, s) {
      dev.log('RecipeImageStore: Legacy-Migration fehlgeschlagen',
          error: e, stackTrace: s, name: 'recipe_image_store');
    }
  }

  Future<Directory?> _ensureRoot() {
    final known = _root;
    if (known != null) return Future<Directory?>.value(known);
    if (_rootUnavailable) return Future<Directory?>.value();
    return _rootInFlight ??= _openRoot();
  }

  /// Loest den Wurzel-Pfad auf — legt den Ordner bewusst NICHT an. Das tut
  /// nur [save]; sonst brauechte ein blosser Lesezugriff Schreibrechte, und
  /// [clear] haette den Ordner beim naechsten Bild sofort wieder da.
  Future<Directory?> _openRoot() async {
    try {
      final dir = await _resolveBaseDirectory();
      _root = dir;
      return dir;
    } catch (e, s) {
      // Kein Ablageort (fehlender Plugin-Channel im Widget-Test, volle Platte).
      // Die App laeuft ohne Bilder weiter — sie sind Beiwerk, kein Datum.
      dev.log('RecipeImageStore: kein Ablageort',
          error: e, stackTrace: s, name: 'recipe_image_store');
      _rootUnavailable = true;
      return null;
    } finally {
      _rootInFlight = null;
    }
  }

  static Future<Directory> _appDocumentsFolder() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/$folderName');
  }
}
