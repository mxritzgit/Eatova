import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/services/recipe_image_store.dart';

// Own recipe photos live locally (no Supabase bucket, policies or byte queue).
// This suite pins the guarantees such a store stands or falls on:
//
//   1. The `local:` marker is recognizable, so a second device falls back to
//      the placeholder instead of loading a dead asset path.
//   2. EXIF scrubbing is mandatory: a kitchen photo would otherwise carry the
//      home GPS coordinates permanently on disk.
//   3. Deleting (recipe) and clearing (logout/account) leave nothing behind.
//   4. Finding 5: every user has their own namespace, file names are not
//      guessable, and an identity change purges the predecessor's files even
//      without an explicit sign-out.

/// A JPEG with the EXIF container an OEM camera with location tagging writes.
/// Kept small: the container is the subject, not scaling.
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

/// Looks for the APP1 EXIF signature ("Exif\x00\x00") in the raw bytes.
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

/// The format [RecipeImageStore.save] assigns since Finding 5: 128 bits from
/// Random.secure as hex, nothing slug- or time-derived.
final RegExp _zufallsReferenz = RegExp(r'^local:img_[0-9a-f]{32}\.jpg$');

void main() {
  late Directory temp;
  late Directory wurzel;
  late RecipeImageStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('eatova_recipe_images_test');
    wurzel = Directory('${temp.path}/recipe_images');
    store = RecipeImageStore(baseDirectory: () async => wurzel);
    // Almost all guarantees hold inside a signed-in user's namespace; the
    // Finding 5 group covers the cases without a user.
    await store.setActiveUser('nutzer-a');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  /// A fresh store on the same directory = the next app start.
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
      // A reference arrives unvalidated from the server row, so it must never
      // reach a file outside the namespace.
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
      // The second-device case: the reference arrives via the server row, the
      // bytes never exist here.
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
      // Not throwing is the guarantee.
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
      // baseResolved means the answer is settled, and it is null.
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
      // The old predictable scheme (`user_<ms>.jpg`) must never return:
      // milliseconds are brute-forceable.
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
    /// Places a file the way it lay before namespaces: flat in
    /// recipe_images/, name derived from the slug.
    Future<File> legeAltbestandAb(String name) async {
      if (!wurzel.existsSync()) wurzel.createSync(recursive: true);
      final datei = File('${wurzel.path}/$name');
      await datei.writeAsBytes(_geotaggedJpeg());
      return datei;
    }

    test('der erste angemeldete Nutzer erbt die flachen Dateien', () async {
      final flach = await legeAltbestandAb('user_1717500000000.jpg');

      // Fresh store = app start after the update, with session restore.
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

      // User A is signed in but never opens the recipes (no access, no
      // migration). Then B signs in.
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

  group('/recipe-Vorschlagsbilder (Nachtrag 2026-08-13)', () {
    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));

    test('Roundtrip unter der Message-Id, Referenz ist deterministisch',
        () async {
      expect(
        await store.saveProposalImage(messageId: 'msg-1', bytes: bytes),
        isTrue,
      );
      expect(await store.readProposalImage('msg-1'), bytes);
      // Deterministic, so the reload card finds its image without an index.
      expect(
        RecipeImageStore.proposalReference('msg-1'),
        'local:proposal_msg-1.jpg',
      );
    });

    test('ueberlebt den Neustart (frischer Store, gleiche Platte)', () async {
      await store.saveProposalImage(messageId: 'msg-1', bytes: bytes);
      final neu = await neustart();
      expect(await neu.readProposalImage('msg-1'), bytes);
    });

    test('ohne angemeldeten Nutzer: kein Save, kein Read (fail-closed)',
        () async {
      final ohne = RecipeImageStore(baseDirectory: () async => wurzel);
      expect(
        await ohne.saveProposalImage(messageId: 'msg-1', bytes: bytes),
        isFalse,
      );
      expect(await ohne.readProposalImage('msg-1'), isNull);
    });

    test('Cap: aelteste Vorschlagsbilder fallen, Rezept-Fotos bleiben',
        () async {
      // A recipe photo (img_*) as the control group for the prune.
      final fotoRef = await store.save(bytes: _geotaggedJpeg());
      expect(fotoRef, isNotNull);

      const ueberCap = RecipeImageStore.proposalImageCap + 3;
      for (var i = 0; i < ueberCap; i++) {
        expect(
          await store.saveProposalImage(messageId: 'msg-$i', bytes: bytes),
          isTrue,
        );
        // mtime carries the prune order; the delay avoids timestamp ties on
        // coarse file systems.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(await store.readProposalImage('msg-0'), isNull,
          reason: 'das aelteste Vorschlagsbild faellt am Cap');
      expect(await store.readProposalImage('msg-${ueberCap - 1}'), isNotNull,
          reason: 'das juengste bleibt');
      expect(await store.resolve(fotoRef!), isNotNull,
          reason: 'Rezept-Fotos (img_*) beruehrt der Prune nie');
    });
  });
}
