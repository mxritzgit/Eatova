import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/user_recipe_reads.dart';

import '../outbox/outbox_test_helpers.dart';
import '../support/atomic_store_faults.dart';

// Review 2026-08-31, Befund A: der Foto-Abgleich (P3-04) loescht jede
// img_*-Datei, die im uebergebenen Behalte-Satz fehlt — und die Bytes liegen
// AUSSCHLIESSLICH auf diesem Geraet. Das Tor davor war
// `HomeStore.userRecipesAuthoritative` = „der Boot-Load hat geantwortet".
//
// Eine Antwort ist aber nicht dasselbe wie eine vollstaendige Antwort. Zwei
// Lagen liefern eine geantwortete, unvollstaendige Liste:
//
//   1. Der Nutzer hat mehr Rezepte als eine Serverseite fasst
//      (`UserRecipeReads.pageSize`). Hydriert der Rezept-Slot nicht
//      (DEK-Neupraegung, Parse-Fehler, No-Cache-Fenster), ist die Liste die
//      Seite — und jedes Foto ab Rezept #201 gilt als verwaist.
//   2. Der Outbox-Slot wirft beim Lesen, waehrend der Rezept-Slot
//      veraltet-leer ist: das eingereihte `recipeUpsert` wird nicht
//      nachgelegt, sein Rezept fehlt in der Liste, sein Foto faellt.
//
// Beide Faelle stehen hier gegen ihre Gegenprobe: „wirklich keine Rezepte,
// Sammlung vollstaendig geladen" muss weiterhin aufraeumen — ein Waechter, der
// das mitnimmt, waere die falsche Reparatur (P3-04b).

late Directory _temp;
late Directory _wurzel;

/// Bytes, wie eine FRUEHERE Sitzung sie abgelegt haette: im Namensraum des
/// Nutzers, aber ohne dass der pruefende Store sie selbst geschrieben hat —
/// `_writtenThisSession` schuetzt sie also nicht.
String _fotoAusFrueherSitzung(String name) {
  final namensraum = Directory('${_wurzel.path}/user-outbox');
  if (!namensraum.existsSync()) namensraum.createSync(recursive: true);
  File(
    '${namensraum.path}/$name.jpg',
  ).writeAsBytesSync(Uint8List.fromList(List<int>.generate(64, (i) => i)));
  return '${RecipeImageStore.referencePrefix}$name.jpg';
}

/// Ein Bildspeicher auf demselben Verzeichnis = der naechste App-Start.
Future<RecipeImageStore> _bildspeicher() async {
  final speicher = RecipeImageStore(baseDirectory: () async => _wurzel);
  await speicher.setActiveUser('user-outbox');
  return speicher;
}

/// Exakt das, was `_RecipesScreenState._sweepOrphanPhotos` tut: das Tor lesen,
/// und nur dahinter die `imageAsset`-Werte der bekannten Rezepte uebergeben.
/// Rueckgabe ist die Zahl gefallener Dateien.
Future<int> _abgleichWieDerScreen(
  HomeStore store,
  RecipeImageStore speicher,
) async {
  if (!store.userRecipesAuthoritative) return 0;
  return speicher.reconcileRecipePhotos({
    ...store.recipePhotoReferences,
    ...store.userRecipes.map((r) => r.imageAsset),
  });
}

FitnessRecipe _eigenesMitFoto(String slug, String referenz) => FitnessRecipe(
  slug: slug,
  title: 'Eigene Bowl',
  description: 'Eigenes Rezept',
  portion: '1 Teller',
  ingredients: 'Reis\nHaehnchen',
  preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
  professionalHint: 'Selbst angelegt.',
  imageAsset: referenz,
  caloriesKcal: 600,
  proteinG: 50,
  carbsG: 60,
  fatG: 15,
  estimatedGrams: 400,
  categories: const <String>['Eigene'],
  userCreated: true,
);

/// Fuellt die Servertabelle mit [anzahl] Rezepten; das erste traegt [mitFoto].
void _seedRezepte(FakeServer server, int anzahl, {String? mitFoto}) {
  for (var i = 0; i < anzahl; i++) {
    final slug = 'user_$i';
    server.recipeRows[slug] = <String, dynamic>{
      ...serverRecipeRow(slug),
      if (i == 0 && mitFoto != null) 'image_asset': mitFoto,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _temp = await Directory.systemTemp.createTemp('eatova_a_foto_abgleich');
    _wurzel = Directory('${_temp.path}/recipe_images');
  });

  tearDown(() async {
    if (_temp.existsSync()) await _temp.delete(recursive: true);
  });

  group('A: complete paginated recipe snapshot', () {
    test(
      '451 recipes preserve photos on later pages and remove real orphans',
      () async {
        final kv = InMemoryKeyValueStore();
        final s = setup(kv: kv);
        await s.cache.writeProfile(
          const UserProfile(weightKg: 80, onboardingCompleted: true),
        );
        final first = _fotoAusFrueherSitzung(
          'img_11111111111111111111111111111111',
        );
        final later = _fotoAusFrueherSitzung(
          'img_22222222222222222222222222222222',
        );
        final orphan = _fotoAusFrueherSitzung(
          'img_33333333333333333333333333333333',
        );
        _seedRezepte(s.server, 451, mitFoto: first);
        s.server.recipeRows['user_400']!['image_asset'] = later;
        await bootUntilIdle(s.store);
        expect(s.store.userRecipes, hasLength(451));
        expect(s.server.recipeReads.pageCalls, 3);
        expect(s.store.userRecipesAuthoritative, isTrue);
        final images = await _bildspeicher();
        expect(await _abgleichWieDerScreen(s.store, images), 1);
        expect(await images.resolve(first), isNotNull);
        expect(await images.resolve(later), isNotNull);
        expect(await images.resolve(orphan), isNull);
      },
    );

    test(
      'exactly one full page is authoritative and still collects orphans',
      () async {
        final s = setup(kv: InMemoryKeyValueStore());
        await s.cache.writeProfile(
          const UserProfile(weightKg: 80, onboardingCompleted: true),
        );
        final keep = _fotoAusFrueherSitzung(
          'img_44444444444444444444444444444444',
        );
        final orphan = _fotoAusFrueherSitzung(
          'img_55555555555555555555555555555555',
        );
        _seedRezepte(s.server, UserRecipeReads.pageSize, mitFoto: keep);
        await bootUntilIdle(s.store);
        expect(s.store.userRecipesAuthoritative, isTrue);
        final images = await _bildspeicher();
        expect(await _abgleichWieDerScreen(s.store, images), 1);
        expect(await images.resolve(keep), isNotNull);
        expect(await images.resolve(orphan), isNull);
      },
    );

    test(
      'a failed second page does not publish a partial library or remove photos',
      () async {
        final s = setup(kv: InMemoryKeyValueStore());
        await s.cache.writeProfile(
          const UserProfile(weightKg: 80, onboardingCompleted: true),
        );
        final later = _fotoAusFrueherSitzung(
          'img_66666666666666666666666666666666',
        );
        _seedRezepte(s.server, 451);
        s.server.recipeRows['user_400']!['image_asset'] = later;
        s.server.recipeReads.failPage = 2;
        await bootUntilIdle(s.store);
        expect(s.store.userRecipes, isEmpty);
        expect(s.store.userRecipesAuthoritative, isFalse);
        final images = await _bildspeicher();
        expect(await _abgleichWieDerScreen(s.store, images), 0);
        expect(await images.resolve(later), isNotNull);
        s.server.recipeReads.failPage = null;
        await s.store.retryBoot();
        expect(s.store.userRecipes, hasLength(451));
        expect(s.store.userRecipesAuthoritative, isTrue);
        expect(await _abgleichWieDerScreen(s.store, images), 0);
        expect(await images.resolve(later), isNotNull);
      },
    );
  });

  test(
    'historical photo refs survive deletion while unrelated files are collected',
    () async {
      final s = setup(kv: InMemoryKeyValueStore());
      await s.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true),
      );
      final history = _fotoAusFrueherSitzung(
        'img_77777777777777777777777777777777',
      );
      final orphan = _fotoAusFrueherSitzung(
        'img_88888888888888888888888888888888',
      );
      s.server.recipeReads.historicalPhotos.add(history);
      s.server.recipeReads.failPhotoPage = 1;
      await bootUntilIdle(s.store);
      final images = await _bildspeicher();
      expect(s.store.userRecipesAuthoritative, isFalse);
      expect(await _abgleichWieDerScreen(s.store, images), 0);
      expect(await images.resolve(orphan), isNotNull);
      s.server.recipeReads.failPhotoPage = null;
      await s.store.retryBoot();
      expect(s.store.userRecipesAuthoritative, isTrue);
      expect(s.store.recipePhotoReferences, contains(history));
      expect(await _abgleichWieDerScreen(s.store, images), 1);
      expect(await images.resolve(history), isNotNull);
      expect(await images.resolve(orphan), isNull);
    },
  );

  group('A: unlesbarer Outbox-Slot', () {
    test('eingereihtes Rezept unsichtbar + veraltet-leerer Rezept-Slot: sein '
        'Foto ueberlebt', () async {
      final foto = _fotoAusFrueherSitzung('img_${'e' * 32}');

      final kv = InMemoryKeyValueStore();
      final a = setup(kv: kv);
      await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true),
      );
      await bootUntilIdle(a.store);

      // Offline angelegt: die Op liegt persistiert in der Outbox, der Server
      // erfaehrt nichts davon.
      a.server.offline = true;
      await a.store.createUserRecipe(_eigenesMitFoto('user_eingereiht', foto));
      a.store.flushPendingWrites();
      await settle();
      expect(
        a.store.pendingOutbox,
        isNotEmpty,
        reason: 'Vorbedingung: die Zustellung steht noch aus.',
      );
      // Der Kill im 400-ms-Entprellfenster: der Rezept-Slot hat den Eintrag
      // nie gesehen.
      await a.cache.writeUserRecipes(const <FitnessRecipe>[]);

      // Kaltstart MIT Netz, aber der Outbox-Slot wirft beim Lesen: die Op wird
      // nicht nachgelegt, und der Server kennt das Rezept nicht.
      final faults = AtomicStoreFaults(kv)
        ..beforeRead = (keys) async {
          if (keys.any((key) => key.contains('.outbox.'))) {
            throw StateError('Unreadable outbox');
          }
        };
      final b = setup(injizierterCache: LocalCache(faults, 'user-outbox'));
      await bootUntilIdle(b.store);

      expect(
        b.store.userRecipes,
        isEmpty,
        reason:
            'Vorbedingung: weder Cache noch Outbox noch Server nennen '
            'das Rezept — die Liste ist leer, das Rezept existiert.',
      );
      expect(
        b.store.userRecipesAuthoritative,
        isFalse,
        reason:
            'Solange der Outbox-Slot unlesbar ist, fehlen der Liste '
            'moeglicherweise eingereihte Rezepte; aus einem fehlenden '
            'Eintrag darf dann nichts gefolgert werden.',
      );

      final speicher = await _bildspeicher();
      expect(await _abgleichWieDerScreen(b.store, speicher), 0);
      expect(
        await speicher.resolve(foto),
        isNotNull,
        reason:
            'Das Rezept kommt mit der Reparatur der Outbox zurueck — '
            'mit einer ins Leere zeigenden local:-Referenz, waere das Foto '
            'jetzt gefallen.',
      );
    });

    test('Gegenprobe: lesbarer Outbox-Slot und wirklich keine Rezepte — der '
        'Abgleich raeumt weiterhin auf', () async {
      final verwaist = _fotoAusFrueherSitzung('img_${'f' * 32}');

      final kv = InMemoryKeyValueStore();
      final s = setup(kv: kv);
      await s.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true),
      );
      await bootUntilIdle(s.store);

      expect(s.store.userRecipes, isEmpty);
      expect(
        s.store.userRecipesAuthoritative,
        isTrue,
        reason:
            '„Der Nutzer hat alle Rezepte geloescht" ist ein gueltiger '
            'Zustand, der aufgeraeumt werden MUSS — ein Waechter, der leere '
            'Listen pauschal schuetzt, waere die falsche Reparatur.',
      );

      final speicher = await _bildspeicher();
      expect(await _abgleichWieDerScreen(s.store, speicher), 1);
      expect(
        await speicher.resolve(verwaist),
        isNull,
        reason: 'Sonst blieben 200-400 kB PII pro Foto fuer immer liegen.',
      );
    });
  });
}
