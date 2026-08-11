import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/services/recipe_image_store.dart';

// Eigene Rezept-Fotos liegen LOKAL (kein Supabase-Bucket, keine Policies, keine
// Byte-Warteschlange). Diese Suite haelt die Zusicherungen fest, an denen so
// eine Ablage steht oder faellt:
//
//   1. Der Marker `local:` ist erkennbar. Ein zweites Geraet sieht ihn, findet
//      keine Datei und faellt sauber auf den Platzhalter zurueck, statt einen
//      toten Asset-Pfad zu laden.
//   2. EXIF ist Pflicht-Scrub: ein Kuechenfoto traegt sonst die GPS-Koordinaten
//      der Wohnung — und zwar dauerhaft auf der Platte, nicht nur im Upload.
//   3. Loeschen (Rezept) und Raeumen (Logout/Konto) lassen nichts liegen.
//   4. Finding 5 (Security-Review 2026-08-11): jeder Nutzer hat seinen
//      eigenen Namensraum, Dateinamen sind nicht erratbar, und ein
//      Identitaetswechsel purgt den Bestand des Vorgaengers — auch ohne
//      explizites Abmelden.

/// Ein JPEG mit dem EXIF-Container, den eine OEM-Kamera mit aktiviertem
/// Standort-Tagging schreibt. Klein gehalten — geprueft wird der Container,
/// nicht die Skalierung (das macht meal_photo_exif_scrub_test).
Uint8List _geotaggedJpeg({int width = 320, int height = 240}) {
  final image = img.Image(width: width, height: height);
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
  exif.exifIfd['DateTimeOriginal'] = '2026:08:10 12:34:56';
  final gps = exif.gpsIfd;
  gps[0x0001] = img.IfdValueAscii('N');
  gps[0x0002] = img.IfdValueRational(52, 1);
  gps[0x0003] = img.IfdValueAscii('E');
  gps[0x0004] = img.IfdValueRational(13, 1);
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

/// Sucht die APP1-Exif-Signatur ("Exif\x00\x00") im rohen Byte-Strom.
bool _hasExifSegment(Uint8List bytes) {
  const signature = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
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

/// Das Format, das [RecipeImageStore.save] seit Finding 5 vergibt: 128 Bit
/// aus Random.secure als Hex — nichts Slug- oder Zeit-Abgeleitetes.
final RegExp _zufallsReferenz = RegExp(r'^local:img_[0-9a-f]{32}\.jpg$');

void main() {
  late Directory temp;
  late Directory wurzel;
  late RecipeImageStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('eatova_recipe_images_test');
    wurzel = Directory('${temp.path}/recipe_images');
    store = RecipeImageStore(baseDirectory: () async => wurzel);
    // Die allermeisten Zusicherungen gelten IM Namensraum eines angemeldeten
    // Nutzers; die Faelle ohne Nutzer prueft die Finding-5-Gruppe explizit.
    await store.setActiveUser('nutzer-a');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  /// Ein frischer Store auf demselben Verzeichnis = der naechste App-Start.
  Future<RecipeImageStore> neustart({String? userId = 'nutzer-a'}) async {
    final neu = RecipeImageStore(baseDirectory: () async => wurzel);
    await neu.setActiveUser(userId);
    return neu;
  }

  group('Referenz-Format (der Marker fuer „die Bytes habe ich nicht")', () {
    test('erkennt eigene Referenzen und laesst Bundle-Assets in Ruhe', () {
      expect(
        RecipeImageStore.isLocalReference('local:img_00ff.jpg'),
        isTrue,
      );
      expect(
        RecipeImageStore.isLocalReference('assets/recipes/lachs.jpg'),
        isFalse,
      );
      expect(RecipeImageStore.isLocalReference(''), isFalse);
    });

    test('eine Referenz mit Pfad-Zeichen kann nicht aus dem Ordner ausbrechen',
        () async {
      // Eine Referenz kommt ungeprueft aus der Serverzeile — eine Datei
      // AUSSERHALB des Namensraums darf sie nie erreichen.
      final geheim = File('${temp.path}/geheim.jpg');
      await geheim.writeAsBytes(_geotaggedJpeg());

      expect(await store.resolve('local:../geheim.jpg'), isNull);
      expect(await store.resolve('local:..\\geheim.jpg'), isNull);
      expect(await store.resolve('local:../../geheim.jpg'), isNull);
      expect(geheim.existsSync(), isTrue,
          reason: 'Die fremde Datei bleibt unangetastet und unerreichbar.');
    });
  });

  group('Speichern und Wiederfinden', () {
    test('gespeicherte Bytes ueberleben einen Neustart des Stores', () async {
      final reference = await store.save(bytes: _geotaggedJpeg());
      expect(reference, matches(_zufallsReferenz));

      final neu = await neustart();
      final datei = await neu.resolve(reference!);
      expect(datei, isNotNull);
      expect(await datei!.exists(), isTrue);
      expect(img.decodeImage(await datei.readAsBytes()), isNotNull);
    });

    test('eine fehlende Datei liefert null statt eines toten Pfades', () async {
      // Genau der Fall „zweites Geraet": die Referenz kommt ueber die
      // Serverzeile, die Bytes gibt es hier nie.
      expect(await store.resolve('local:img_nie_gespeichert.jpg'), isNull);
      expect(store.resolveSync('local:img_nie_gespeichert.jpg'), isNull);
    });

    test('ein Bundle-Asset ist keine lokale Datei', () async {
      expect(await store.resolve('assets/recipes/lachs.jpg'), isNull);
      expect(await store.resolve(''), isNull);
    });

    test('resolveSync findet die Datei ohne await, sobald der Ordner steht',
        () async {
      final reference = await store.save(bytes: _geotaggedJpeg());
      expect(store.resolveSync(reference!), isNotNull);
    });

    test('ohne Ablageort (Plugin fehlt) faellt alles auf null zurueck',
        () async {
      final kaputt = RecipeImageStore(
        baseDirectory: () async => throw const FileSystemException('kein Pfad'),
      );
      await kaputt.setActiveUser('nutzer-a');
      expect(await kaputt.save(bytes: _geotaggedJpeg()), isNull);
      expect(await kaputt.resolve('local:img_x.jpg'), isNull);
      expect(kaputt.resolveSync('local:img_x.jpg'), isNull);
    });
  });

  group('EXIF-Scrub ist Pflicht — auch auf der Platte', () {
    test('das Fixture traegt die Metadaten wirklich (Vorbedingung)', () {
      final roh = _geotaggedJpeg();
      expect(_hasExifSegment(roh), isTrue);
      expect(img.decodeImage(roh)!.exif.gpsIfd.keys, isNotEmpty);
    });

    test('die abgelegte Datei traegt weder GPS noch Geraete-Kennung', () async {
      final reference = await store.save(bytes: _geotaggedJpeg());
      final bytes = await (await store.resolve(reference!))!.readAsBytes();

      expect(_hasExifSegment(bytes), isFalse,
          reason: 'Ein Kuechenfoto darf die Wohnadresse nicht auf der Platte '
              'mitschleppen.');
      expect(img.decodeImage(bytes)!.exif.gpsIfd.keys, isEmpty);
    });

    test('nicht dekodierbare Bytes werden NICHT abgelegt (fail-closed)',
        () async {
      final muell = Uint8List.fromList(List<int>.filled(64, 7));
      expect(await store.save(bytes: muell), isNull);
    });
  });

  group('Aufraeumen', () {
    test('deleteFor loescht genau das eine Bild', () async {
      final a = await store.save(bytes: _geotaggedJpeg());
      final b = await store.save(bytes: _geotaggedJpeg());

      await store.deleteFor(a!);

      expect(await store.resolve(a), isNull);
      expect(await store.resolve(b!), isNotNull);
    });

    test('deleteFor auf einem Bundle-Asset ist ein No-Op', () async {
      await store.deleteFor('assets/recipes/lachs.jpg');
      await store.deleteFor('');
      // Kein Wurf ist die Zusicherung.
    });

    test('clear() raeumt den ganzen Ordner (Logout / Konto-Loeschung)',
        () async {
      final a = await store.save(bytes: _geotaggedJpeg());
      final b = await store.save(bytes: _geotaggedJpeg());

      await store.clear();

      expect(await store.resolve(a!), isNull);
      expect(await store.resolve(b!), isNull);
      expect(wurzel.existsSync(), isFalse,
          reason: 'Kein PII-Rest im Dateisystem — auch kein Namensraum.');
    });

    test('nach clear() laesst sich wieder speichern', () async {
      await store.save(bytes: _geotaggedJpeg());
      await store.clear();

      final wieder = await store.save(bytes: _geotaggedJpeg());
      expect(wieder, matches(_zufallsReferenz));
      expect(await store.resolve(wieder!), isNotNull);
    });
  });

  group('Finding 5 — ein Namensraum pro Nutzer', () {
    test('ohne angemeldeten Nutzer keine Ablage und keine Aufloesung',
        () async {
      final anonym = RecipeImageStore(baseDirectory: () async => wurzel);
      expect(await anonym.save(bytes: _geotaggedJpeg()), isNull);
      expect(await anonym.resolve('local:img_x.jpg'), isNull);
      expect(anonym.resolveSync('local:img_x.jpg'), isNull);
      // baseResolved sagt „die Antwort steht fest" — und die ist null.
      expect(anonym.baseResolved, isTrue);
    });

    test('Wechsel A -> B: B kann As Referenz nicht aufloesen, As Dateien '
        'sind gepurgt', () async {
      final reference = await store.save(bytes: _geotaggedJpeg());
      final dateiA = await store.resolve(reference!);
      expect(dateiA, isNotNull);

      await store.setActiveUser('nutzer-b');

      expect(await store.resolve(reference), isNull,
          reason: 'Eine bekannte/geratene Referenz von A darf bei B nie '
              'aufloesen — genau das war das Leck.');
      expect(store.resolveSync(reference), isNull);
      expect(dateiA!.existsSync(), isFalse,
          reason: 'Der Namensraum des Vorgaengers wird beim Wechsel gepurgt, '
              'nicht nur versteckt.');
      expect(Directory('${wurzel.path}/nutzer-a').existsSync(), isFalse);
    });

    test('B sieht seine eigenen Bilder, A nach dem Rueckwechsel NICHT die '
        'von B', () async {
      await store.setActiveUser('nutzer-b');
      final refB = await store.save(bytes: _geotaggedJpeg());
      expect(await store.resolve(refB!), isNotNull);

      await store.setActiveUser('nutzer-a');
      expect(await store.resolve(refB), isNull);
    });

    test('Session-Verlust (A -> null) purgt As Namensraum (fail-closed)',
        () async {
      final reference = await store.save(bytes: _geotaggedJpeg());
      final datei = await store.resolve(reference!);

      await store.setActiveUser(null);

      expect(await store.resolve(reference), isNull);
      expect(datei!.existsSync(), isFalse,
          reason: 'Auch der unfreiwillige Session-Verlust laeuft nicht ueber '
              'signOutCleanup — der Store muss selbst purgen.');
    });

    test('ein Token-Refresh (dieselbe id erneut) purgt NICHT', () async {
      final reference = await store.save(bytes: _geotaggedJpeg());

      await store.setActiveUser('nutzer-a');

      expect(await store.resolve(reference!), isNotNull);
    });

    test('Kaltstart mit Session-Restore (null -> uid) purgt NICHT', () async {
      final reference = await store.save(bytes: _geotaggedJpeg());

      final neu = await neustart();

      expect(await neu.resolve(reference!), isNotNull,
          reason: 'Sonst ueberlebte kein Foto einen App-Neustart.');
    });
  });

  group('Finding 5 — Dateinamen sind nicht erratbar', () {
    test('save vergibt Zufalls-Hex statt des Slug-/Timestamp-Schemas',
        () async {
      final reference = await store.save(bytes: _geotaggedJpeg());
      expect(reference, matches(_zufallsReferenz));
      // Das alte, vorhersagbare Schema (`user_<ms>.jpg`) darf nie wieder
      // entstehen — Millisekunden kann ein Angreifer durchprobieren.
      expect(reference, isNot(matches(RegExp(r'user_\d+'))));
    });

    test('zwei Ablagen bekommen zwei verschiedene Namen', () async {
      final bytes = _geotaggedJpeg();
      final gesehen = <String>{};
      for (var i = 0; i < 4; i++) {
        final reference = await store.save(bytes: bytes);
        expect(reference, isNotNull);
        expect(gesehen.add(reference!), isTrue,
            reason: 'Gleiche Bytes, gleicher Moment — trotzdem nie derselbe '
                'Name.');
      }
    });
  });

  group('Finding 5 — Legacy-Migration (flacher Alt-Bestand)', () {
    /// Legt eine Datei so ab, wie sie VOR den Namensraeumen lag: flach in
    /// recipe_images/, Name aus dem Slug abgeleitet.
    Future<File> legeAltbestandAb(String name) async {
      if (!wurzel.existsSync()) wurzel.createSync(recursive: true);
      final datei = File('${wurzel.path}/$name');
      await datei.writeAsBytes(_geotaggedJpeg());
      return datei;
    }

    test('der erste angemeldete Nutzer erbt die flachen Dateien', () async {
      final flach = await legeAltbestandAb('user_1717500000000.jpg');

      // Frischer Store = App-Start nach dem Update, Session-Restore.
      final neu = await neustart();
      final datei = await neu.resolve('local:user_1717500000000.jpg');

      expect(datei, isNotNull,
          reason: 'Die alte Referenz aus der Rezeptzeile muss weiter '
              'aufloesen — nur der Ordner wechselt, nie der Name.');
      expect(datei!.path.replaceAll('\\', '/'),
          contains('/recipe_images/nutzer-a/'));
      expect(flach.existsSync(), isFalse,
          reason: 'Verschoben, nicht kopiert — flach bleibt nichts liegen.');
    });

    test('der ZWEITE Nutzer erbt nicht: der Wechsel purgt den Alt-Bestand '
        'mit, auch wenn der erste ihn nie angefasst hat', () async {
      final flach = await legeAltbestandAb('user_1717500000000.jpg');

      // Nutzer A ist angemeldet, oeffnet die Rezepte aber nie (kein Zugriff,
      // keine Migration). Dann meldet sich B an.
      final neu = await neustart();
      await neu.setActiveUser('nutzer-b');

      expect(await neu.resolve('local:user_1717500000000.jpg'), isNull,
          reason: 'Flache Alt-Dateien gehoeren dem bisherigen Geraete-Nutzer '
              '— B darf sie weder erben noch aufloesen.');
      expect(flach.existsSync(), isFalse,
          reason: 'Fail-closed: beim Identitaetswechsel faellt der '
              'Alt-Bestand mit.');
    });
  });
}
