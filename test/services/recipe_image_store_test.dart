import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/services/recipe_image_store.dart';

// Eigene Rezept-Fotos liegen LOKAL (kein Supabase-Bucket, keine Policies, keine
// Byte-Warteschlange). Diese Suite haelt die vier Zusicherungen fest, an denen
// so eine Ablage steht oder faellt:
//
//   1. Der Dateiname leitet sich STABIL vom Slug ab — ein Neustart findet die
//      Bytes wieder, ohne dass irgendwo ein Pfad mitgeschleppt wird.
//   2. Der Marker `local:` ist erkennbar. Ein zweites Geraet sieht ihn, findet
//      keine Datei und faellt sauber auf den Platzhalter zurueck, statt einen
//      toten Asset-Pfad zu laden.
//   3. EXIF ist Pflicht-Scrub: ein Kuechenfoto traegt sonst die GPS-Koordinaten
//      der Wohnung — und zwar dauerhaft auf der Platte, nicht nur im Upload.
//   4. Loeschen (Rezept) und Raeumen (Logout/Konto) lassen nichts liegen.

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

void main() {
  late Directory temp;
  late RecipeImageStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('eatova_recipe_images_test');
    store = RecipeImageStore(
      baseDirectory: () async => Directory('${temp.path}/recipe_images'),
    );
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('Referenz-Format (der Marker fuer „die Bytes habe ich nicht")', () {
    test('leitet sich stabil vom Slug ab', () {
      expect(
        RecipeImageStore.referenceForSlug('user_1717500000000'),
        'local:user_1717500000000.jpg',
      );
      // Zweimal derselbe Slug -> zweimal dieselbe Referenz.
      expect(
        RecipeImageStore.referenceForSlug('user_42'),
        RecipeImageStore.referenceForSlug('user_42'),
      );
    });

    test('erkennt eigene Referenzen und laesst Bundle-Assets in Ruhe', () {
      expect(
        RecipeImageStore.isLocalReference('local:user_42.jpg'),
        isTrue,
      );
      expect(
        RecipeImageStore.isLocalReference('assets/recipes/lachs.jpg'),
        isFalse,
      );
      expect(RecipeImageStore.isLocalReference(''), isFalse);
    });

    test('ein Slug mit Pfad-Zeichen kann nicht aus dem Ordner ausbrechen', () {
      final reference = RecipeImageStore.referenceForSlug('../../etc/passwd');
      expect(reference.contains('/'), isFalse);
      expect(reference.contains('\\'), isFalse);
      expect(reference.contains('..'), isFalse);
    });
  });

  group('Speichern und Wiederfinden', () {
    test('gespeicherte Bytes ueberleben einen Neustart des Stores', () async {
      final reference =
          await store.save(slug: 'user_1', bytes: _geotaggedJpeg());
      expect(reference, 'local:user_1.jpg');

      // Ein FRISCHER Store auf demselben Verzeichnis = der naechste App-Start.
      final neu = RecipeImageStore(
        baseDirectory: () async => Directory('${temp.path}/recipe_images'),
      );
      final datei = await neu.resolve(reference!);
      expect(datei, isNotNull);
      expect(await datei!.exists(), isTrue);
      expect(img.decodeImage(await datei.readAsBytes()), isNotNull);
    });

    test('eine fehlende Datei liefert null statt eines toten Pfades', () async {
      // Genau der Fall „zweites Geraet": die Referenz kommt ueber die
      // Serverzeile, die Bytes gibt es hier nie.
      expect(await store.resolve('local:user_nie_gespeichert.jpg'), isNull);
      expect(store.resolveSync('local:user_nie_gespeichert.jpg'), isNull);
    });

    test('ein Bundle-Asset ist keine lokale Datei', () async {
      expect(await store.resolve('assets/recipes/lachs.jpg'), isNull);
      expect(await store.resolve(''), isNull);
    });

    test('resolveSync findet die Datei ohne await, sobald der Ordner steht',
        () async {
      final reference =
          await store.save(slug: 'user_2', bytes: _geotaggedJpeg());
      expect(store.resolveSync(reference!), isNotNull);
    });

    test('ohne Ablageort (Plugin fehlt) faellt alles auf null zurueck',
        () async {
      final kaputt = RecipeImageStore(
        baseDirectory: () async => throw const FileSystemException('kein Pfad'),
      );
      expect(await kaputt.save(slug: 'user_3', bytes: _geotaggedJpeg()), isNull);
      expect(await kaputt.resolve('local:user_3.jpg'), isNull);
      expect(kaputt.resolveSync('local:user_3.jpg'), isNull);
    });
  });

  group('EXIF-Scrub ist Pflicht — auch auf der Platte', () {
    test('das Fixture traegt die Metadaten wirklich (Vorbedingung)', () {
      final roh = _geotaggedJpeg();
      expect(_hasExifSegment(roh), isTrue);
      expect(img.decodeImage(roh)!.exif.gpsIfd.keys, isNotEmpty);
    });

    test('die abgelegte Datei traegt weder GPS noch Geraete-Kennung', () async {
      final reference =
          await store.save(slug: 'user_4', bytes: _geotaggedJpeg());
      final bytes = await (await store.resolve(reference!))!.readAsBytes();

      expect(_hasExifSegment(bytes), isFalse,
          reason: 'Ein Kuechenfoto darf die Wohnadresse nicht auf der Platte '
              'mitschleppen.');
      expect(img.decodeImage(bytes)!.exif.gpsIfd.keys, isEmpty);
    });

    test('nicht dekodierbare Bytes werden NICHT abgelegt (fail-closed)',
        () async {
      final muell = Uint8List.fromList(List<int>.filled(64, 7));
      expect(await store.save(slug: 'user_5', bytes: muell), isNull);
      expect(await store.resolve('local:user_5.jpg'), isNull);
    });
  });

  group('Aufraeumen', () {
    test('deleteFor loescht genau das eine Bild', () async {
      final a = await store.save(slug: 'user_a', bytes: _geotaggedJpeg());
      final b = await store.save(slug: 'user_b', bytes: _geotaggedJpeg());

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
      final a = await store.save(slug: 'user_a', bytes: _geotaggedJpeg());
      final b = await store.save(slug: 'user_b', bytes: _geotaggedJpeg());

      await store.clear();

      expect(await store.resolve(a!), isNull);
      expect(await store.resolve(b!), isNull);
      expect(Directory('${temp.path}/recipe_images').existsSync(), isFalse,
          reason: 'Kein PII-Rest im Dateisystem.');
    });

    test('nach clear() laesst sich wieder speichern', () async {
      await store.save(slug: 'user_a', bytes: _geotaggedJpeg());
      await store.clear();

      final wieder =
          await store.save(slug: 'user_c', bytes: _geotaggedJpeg());
      expect(wieder, 'local:user_c.jpg');
      expect(await store.resolve(wieder!), isNotNull);
    });
  });
}
