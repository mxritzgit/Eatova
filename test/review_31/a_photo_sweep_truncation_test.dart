import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/user_recipes_sync.dart';

import '../outbox/outbox_test_helpers.dart';

// Review 2026-08-31, Befund A: der Foto-Abgleich (P3-04) loescht jede
// img_*-Datei, die im uebergebenen Behalte-Satz fehlt — und die Bytes liegen
// AUSSCHLIESSLICH auf diesem Geraet. Das Tor davor war
// `HomeStore.userRecipesAuthoritative` = „der Boot-Load hat geantwortet".
//
// Eine Antwort ist aber nicht dasselbe wie eine vollstaendige Antwort. Zwei
// Lagen liefern eine geantwortete, unvollstaendige Liste:
//
//   1. Der Nutzer hat mehr Rezepte als eine Serverseite fasst
//      (`UserRecipesSync.userRecipesLimit`). Hydriert der Rezept-Slot nicht
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
  File('${namensraum.path}/$name.jpg')
      .writeAsBytesSync(Uint8List.fromList(List<int>.generate(64, (i) => i)));
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
  return speicher.reconcileRecipePhotos(
    store.userRecipes.map((r) => r.imageAsset).toList(growable: false),
  );
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

  group('A: ausgeschoepfte Serverseite', () {
    test(
        'mehr Rezepte als eine Seite fasst: die Fotos der abgeschnittenen '
        'Rezepte ueberleben', () async {
      final kv = InMemoryKeyValueStore();
      final s = setup(kv: kv);
      await s.cache.writeProfile(
          const UserProfile(weightKg: 80, onboardingCompleted: true));

      // Ein Foto gehoert einem Rezept AUF der Seite, das andere einem
      // dahinter — der Server liefert dessen Zeile nie mit.
      final aufDerSeite = _fotoAusFrueherSitzung('img_${'a' * 32}');
      final abgeschnitten = _fotoAusFrueherSitzung('img_${'b' * 32}');
      _seedRezepte(s.server, UserRecipesSync.userRecipesLimit,
          mitFoto: aufDerSeite);

      // Wait for the CONDITION, not for 60 turns of the event queue: 200 rows
      // are ~50 kB on the wire, and postgrest decodes anything over 10 kB in a
      // background isolate. That round trip costs wall clock, so `boot()` came
      // back with an empty list wherever the turns were cheap (CI, 2026-08-31:
      // "Expected: length 200, Actual: []").
      await bootUntilIdle(s.store);

      expect(s.store.userRecipes, hasLength(UserRecipesSync.userRecipesLimit),
          reason: 'Vorbedingung: der Boot-Load hat geantwortet und die Seite '
              'ist voll ausgeschoepft.');
      expect(s.store.userRecipesAuthoritative, isFalse,
          reason: 'Eine volle Seite ist ein Ausschnitt, keine Aussage ueber '
              'die Sammlung: Rezept #201 und aelter stehen nicht darin.');

      final speicher = await _bildspeicher();
      expect(await _abgleichWieDerScreen(s.store, speicher), 0);

      expect(await speicher.resolve(abgeschnitten), isNotNull,
          reason: 'Das Foto des abgeschnittenen Rezepts liegt NUR hier — ein '
              'Abgleich gegen die Seite haette es unwiederbringlich '
              'geloescht.');
      expect(await speicher.resolve(aufDerSeite), isNotNull);
    });

    test(
        'Gegenprobe: eine NICHT ausgeschoepfte Seite bleibt eine vollstaendige '
        'Aussage und raeumt auf', () async {
      final kv = InMemoryKeyValueStore();
      final s = setup(kv: kv);
      await s.cache.writeProfile(
          const UserProfile(weightKg: 80, onboardingCompleted: true));

      final behalten = _fotoAusFrueherSitzung('img_${'c' * 32}');
      final verwaist = _fotoAusFrueherSitzung('img_${'d' * 32}');
      _seedRezepte(s.server, UserRecipesSync.userRecipesLimit - 1,
          mitFoto: behalten);

      await bootUntilIdle(s.store);

      expect(s.store.userRecipesAuthoritative, isTrue,
          reason: 'Wer unter dem Limit bleibt, hat die ganze Sammlung — sonst '
              'raeumte ab hier nie wieder jemand auf.');

      final speicher = await _bildspeicher();
      expect(await _abgleichWieDerScreen(s.store, speicher), 1);
      expect(await speicher.resolve(verwaist), isNull);
      expect(await speicher.resolve(behalten), isNotNull,
          reason: 'Das Foto eines existierenden Rezepts faellt nie.');
    });
  });

  group('A: unlesbarer Outbox-Slot', () {
    test(
        'eingereihtes Rezept unsichtbar + veraltet-leerer Rezept-Slot: sein '
        'Foto ueberlebt', () async {
      final foto = _fotoAusFrueherSitzung('img_${'e' * 32}');

      final kv = InMemoryKeyValueStore();
      final a = setup(kv: kv);
      await a.cache.writeProfile(
          const UserProfile(weightKg: 80, onboardingCompleted: true));
      await bootUntilIdle(a.store);

      // Offline angelegt: die Op liegt persistiert in der Outbox, der Server
      // erfaehrt nichts davon.
      a.server.offline = true;
      await a.store.createUserRecipe(_eigenesMitFoto('user_eingereiht', foto));
      a.store.flushPendingWrites();
      await settle();
      expect(a.store.pendingOutbox, isNotEmpty,
          reason: 'Vorbedingung: die Zustellung steht noch aus.');
      // Der Kill im 400-ms-Entprellfenster: der Rezept-Slot hat den Eintrag
      // nie gesehen.
      await a.cache.writeUserRecipes(const <FitnessRecipe>[]);

      // Kaltstart MIT Netz, aber der Outbox-Slot wirft beim Lesen: die Op wird
      // nicht nachgelegt, und der Server kennt das Rezept nicht.
      final b =
          setup(injizierterCache: OutboxLesefehlerCache(kv, 'user-outbox'));
      await bootUntilIdle(b.store);

      expect(b.store.userRecipes, isEmpty,
          reason: 'Vorbedingung: weder Cache noch Outbox noch Server nennen '
              'das Rezept — die Liste ist leer, das Rezept existiert.');
      expect(b.store.userRecipesAuthoritative, isFalse,
          reason: 'Solange der Outbox-Slot unlesbar ist, fehlen der Liste '
              'moeglicherweise eingereihte Rezepte; aus einem fehlenden '
              'Eintrag darf dann nichts gefolgert werden.');

      final speicher = await _bildspeicher();
      expect(await _abgleichWieDerScreen(b.store, speicher), 0);
      expect(await speicher.resolve(foto), isNotNull,
          reason: 'Das Rezept kommt mit der Reparatur der Outbox zurueck — '
              'mit einer ins Leere zeigenden local:-Referenz, waere das Foto '
              'jetzt gefallen.');
    });

    test(
        'Gegenprobe: lesbarer Outbox-Slot und wirklich keine Rezepte — der '
        'Abgleich raeumt weiterhin auf', () async {
      final verwaist = _fotoAusFrueherSitzung('img_${'f' * 32}');

      final kv = InMemoryKeyValueStore();
      final s = setup(kv: kv);
      await s.cache.writeProfile(
          const UserProfile(weightKg: 80, onboardingCompleted: true));
      await bootUntilIdle(s.store);

      expect(s.store.userRecipes, isEmpty);
      expect(s.store.userRecipesAuthoritative, isTrue,
          reason: '„Der Nutzer hat alle Rezepte geloescht" ist ein gueltiger '
              'Zustand, der aufgeraeumt werden MUSS — ein Waechter, der leere '
              'Listen pauschal schuetzt, waere die falsche Reparatur.');

      final speicher = await _bildspeicher();
      expect(await _abgleichWieDerScreen(s.store, speicher), 1);
      expect(await speicher.resolve(verwaist), isNull,
          reason: 'Sonst blieben 200-400 kB PII pro Foto fuer immer liegen.');
    });
  });
}
