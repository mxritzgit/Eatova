import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

// Photos on user recipes: in-app pick (camera/gallery) through the EXISTING
// `MealPhotoInput` pipeline (which scrubs EXIF), stored locally via
// [RecipeImageStore], referenced as `local:<name>.jpg` in the existing
// `imageAsset` field (the name comes randomly from the store, not the slug).
// No Supabase bucket, no second pipeline.
//
// This suite covers the four ways it goes wrong:
//   * The image reaches the recipe and survives a restart.
//   * Carousel, list and detail show it, falling back to the placeholder when
//     the file is missing (second device).
//   * Deleting takes the bytes with it.
//   * The sheet stays intact in both modes and at double text scale, and still
//     has EXACTLY eight text fields (the D5 discard guard counts them).

/// A tiny, valid JPEG — real bytes, so `Image.memory`/`Image.file` can decode.
Uint8List _jpeg({int r = 200, int g = 80, int b = 40}) {
  final image = img.Image(width: 64, height: 48);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

/// Test photo source: always returns the same bytes and records which source
/// was asked for.
class _FakeFotoquelle implements MealPhotoInput {
  _FakeFotoquelle({this.bytes});

  final Uint8List? bytes;
  final List<ImageSource> gefragt = <ImageSource>[];

  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async {
    gefragt.add(source);
    if (bytes == null) return null;
    return MealPhotoSelection(
      request: MealAnalysisRequest(imageId: 'test', imageBytes: bytes),
      previewBytes: bytes,
    );
  }
}

class _CreateCapture {
  final List<FitnessRecipe> created = <FitnessRecipe>[];

  Future<SyncDelivery> add(FitnessRecipe recipe) async {
    created.add(recipe);
    return SyncDelivery.delivered;
  }
}

/// Store double for the widget test.
///
/// `testWidgets` runs under FakeAsync, where real file IO — let alone the
/// scrubber's `compute()` isolate — would never finish. This double does the
/// same work SYNCHRONOUSLY on a real temp directory: references, files and
/// `resolveSync` are real, just without an isolate or an event-loop turn. The
/// real store including the EXIF scrub is covered by
/// test/services/recipe_image_store_test.dart.
class _TestImageStore extends RecipeImageStore {
  _TestImageStore(this.ordner) : super(baseDirectory: () async => ordner);

  final Directory ordner;

  /// What the sheet stored — reference and bytes.
  final Map<String, Uint8List> abgelegt = <String, Uint8List>{};

  /// A counter instead of Random.secure: this test only needs uniqueness; real
  /// randomness is covered by test/services/recipe_image_store_test.dart.
  int _laufnummer = 0;

  @override
  bool get baseResolved => true;

  File _datei(String reference) => File(
        '${ordner.path}/'
        '${reference.substring(RecipeImageStore.referencePrefix.length)}',
      );

  @override
  Future<String?> save({required Uint8List bytes}) async {
    final reference =
        '${RecipeImageStore.referencePrefix}test_${_laufnummer++}.jpg';
    if (!ordner.existsSync()) ordner.createSync(recursive: true);
    _datei(reference).writeAsBytesSync(bytes);
    abgelegt[reference] = bytes;
    return reference;
  }

  @override
  File? resolveSync(String imageAsset) {
    if (!RecipeImageStore.isLocalReference(imageAsset)) return null;
    final datei = _datei(imageAsset);
    return datei.existsSync() ? datei : null;
  }

  @override
  Future<File?> resolve(String imageAsset) async => resolveSync(imageAsset);

  @override
  Future<void> deleteFor(String imageAsset) async {
    if (!RecipeImageStore.isLocalReference(imageAsset)) return;
    final datei = _datei(imageAsset);
    if (datei.existsSync()) datei.deleteSync();
  }

  @override
  Future<void> clear() async {
    if (ordner.existsSync()) ordner.deleteSync(recursive: true);
  }
}

/// Writes a file as if stored in an earlier session — synchronous, so the
/// widget test never waits on real IO. The name is free here; display depends
/// only on the reference.
String _legeAb(_TestImageStore store, String slug, Uint8List bytes) {
  final reference = '${RecipeImageStore.referencePrefix}$slug.jpg';
  if (!store.ordner.existsSync()) store.ordner.createSync(recursive: true);
  store._datei(reference).writeAsBytesSync(bytes);
  return reference;
}

FitnessRecipe _eigenes({required String slug, required String imageAsset}) =>
    FitnessRecipe(
      slug: slug,
      title: 'Mein Testteller',
      description: 'Eigenes Rezept',
      portion: '1 Portion',
      ingredients: 'Keine Angabe',
      preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
      professionalHint: 'Selbst angelegt.',
      imageAsset: imageAsset,
      caloriesKcal: 520,
      proteinG: 40,
      carbsG: 50,
      fatG: 15,
      estimatedGrams: 300,
      categories: const <String>['Eigene'],
      userCreated: true,
    );

late Directory _temp;
late _TestImageStore _store;

/// The home shell pads every tab with `EdgeInsets.fromLTRB(20, 12, 20, 12)`.
const EdgeInsets _schalenrand = EdgeInsets.fromLTRB(20, 12, 20, 12);

Widget _tab({
  MealPhotoInput? photoInput,
  _CreateCapture? capture,
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
}) =>
    RecipesScreen(
      onAddMeal: (MealAnalysisResult _, MealSlot __) {},
      onCreateRecipe: capture?.add,
      photoInput: photoInput,
      initialUserRecipes: userRecipes,
    );

Widget _app(
  Brightness brightness, {
  MealPhotoInput? photoInput,
  _CreateCapture? capture,
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
}) =>
    localizedApp(
      _tab(
        photoInput: photoInput,
        capture: capture,
        userRecipes: userRecipes,
      ),
      brightness: brightness,
      padding: _schalenrand,
    );

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
}

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    _temp = await Directory.systemTemp.createTemp('eatova_recipe_photo_test');
    _store = _TestImageStore(Directory('${_temp.path}/recipe_images'));
    RecipeImageStore.instance = _store;
  });

  tearDown(() async {
    RecipeImageStore.resetInstance();
    if (_temp.existsSync()) await _temp.delete(recursive: true);
  });

  group('Foto aufnehmen oder waehlen', () {
    testWidgets('Kamera-Knopf holt das Foto und zeigt die Vorschau',
        (tester) async {
      pinPhoneViewport(tester);
      final quelle = _FakeFotoquelle(bytes: _jpeg());
      await tester.pumpWidget(_app(Brightness.dark, photoInput: quelle));
      await tester.pumpAndSettle();
      await _openSheet(tester);

      expect(find.byKey(const ValueKey('recipe-create-photo-preview')),
          findsNothing);

      await tester.tap(find.byKey(const ValueKey('recipe-create-photo-camera')));
      await tester.pumpAndSettle();

      expect(quelle.gefragt, <ImageSource>[ImageSource.camera]);
      expect(find.byKey(const ValueKey('recipe-create-photo-preview')),
          findsOneWidget);
    });

    testWidgets('Galerie-Knopf fragt die Galerie', (tester) async {
      pinPhoneViewport(tester);
      final quelle = _FakeFotoquelle(bytes: _jpeg());
      await tester.pumpWidget(_app(Brightness.light, photoInput: quelle));
      await tester.pumpAndSettle();
      await _openSheet(tester);

      await tester
          .tap(find.byKey(const ValueKey('recipe-create-photo-gallery')));
      await tester.pumpAndSettle();

      expect(quelle.gefragt, <ImageSource>[ImageSource.gallery]);
      expect(find.byKey(const ValueKey('recipe-create-photo-preview')),
          findsOneWidget);
    });

    testWidgets('Entfernen nimmt die Vorschau wieder weg', (tester) async {
      pinPhoneViewport(tester);
      await tester.pumpWidget(
        _app(Brightness.dark, photoInput: _FakeFotoquelle(bytes: _jpeg())),
      );
      await tester.pumpAndSettle();
      await _openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('recipe-create-photo-camera')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recipe-create-photo-remove')),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('recipe-create-photo-remove')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('recipe-create-photo-preview')),
          findsNothing);
      expect(find.byKey(const ValueKey('recipe-create-photo-remove')),
          findsNothing);
    });

    testWidgets('ein abgebrochener Griff zur Kamera aendert nichts',
        (tester) async {
      pinPhoneViewport(tester);
      await tester.pumpWidget(
        _app(Brightness.dark, photoInput: _FakeFotoquelle()),
      );
      await tester.pumpAndSettle();
      await _openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('recipe-create-photo-camera')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('recipe-create-photo-preview')),
          findsNothing);
      // Untouched: the sheet still closes without a dialog.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsNothing);
    });

    testWidgets('ein gewaehltes Foto zaehlt als „ausgefuellt" (D5)',
        (tester) async {
      pinPhoneViewport(tester);
      await tester.pumpWidget(
        _app(Brightness.dark, photoInput: _FakeFotoquelle(bytes: _jpeg())),
      );
      await tester.pumpAndSettle();
      await _openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('recipe-create-photo-camera')));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('discard-changes-dialog')),
          findsOneWidget);
    });
  });

  group('Das Bild haengt am Rezept und ueberlebt', () {
    testWidgets('Speichern legt die Bytes ab und setzt die local:-Referenz',
        (tester) async {
      pinPhoneViewport(tester);
      final capture = _CreateCapture();
      await tester.pumpWidget(
        _app(
          Brightness.dark,
          photoInput: _FakeFotoquelle(bytes: _jpeg()),
          capture: capture,
        ),
      );
      await tester.pumpAndSettle();
      await _openSheet(tester);

      await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');
      await _tippe(tester, 'recipe-create-kcal', '520');
      await tester.tap(find.byKey(const ValueKey('recipe-create-photo-camera')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
      await tester.pumpAndSettle();

      expect(capture.created, hasLength(1));
      final rezept = capture.created.single;
      // The store assigns the (random) name, so the recipe carries exactly the
      // reference save() returned, nothing derived.
      expect(RecipeImageStore.isLocalReference(rezept.imageAsset), isTrue);
      expect(_store.abgelegt.keys, <String>[rezept.imageAsset]);
      expect(_store.resolveSync(rezept.imageAsset), isNotNull);
    });

    testWidgets('ohne Foto bleibt imageAsset leer (Abwaertskompatibilitaet)',
        (tester) async {
      pinPhoneViewport(tester);
      final capture = _CreateCapture();
      await tester.pumpWidget(
        _app(Brightness.dark, photoInput: _FakeFotoquelle(), capture: capture),
      );
      await tester.pumpAndSettle();
      await _openSheet(tester);

      await _tippe(tester, 'recipe-create-name', 'Ohne Bild');
      await _tippe(tester, 'recipe-create-kcal', '300');
      await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
      await tester.pumpAndSettle();

      expect(capture.created.single.imageAsset, '');
      // The row stays wire-compatible: a recipe without an image still writes
      // '' to image_asset and reads back unchanged.
      final zeile = capture.created.single.toRow();
      expect(zeile['image_asset'], '');
      expect(FitnessRecipe.fromRow(zeile).imageAsset, '');
    });

    testWidgets('eine alte Zeile ganz OHNE image_asset liest sich weiterhin',
        (tester) async {
      // No widget needed — same assurance as above: the wire format gets NO new
      // field, the marker lives in the existing `image_asset`.
      final alt = FitnessRecipe.fromRow(<String, dynamic>{
        'slug': 'user_alt',
        'title': 'Alt',
        'calories_kcal': 300,
      });
      expect(alt.imageAsset, '');
      expect(RecipeImageStore.isLocalReference(alt.imageAsset), isFalse);
    });
  });

  group('Anzeige — Karte, Liste, Detail', () {
    testWidgets('ein Rezept mit vorhandener Datei zeigt das Bild statt des '
        'Platzhalters', (tester) async {
      final referenz = _legeAb(_store, 'user_mit_bild', _jpeg());
      final rezept = _eigenes(slug: 'user_mit_bild', imageAsset: referenz);

      pinPhoneViewport(tester);
      await tester.pumpWidget(_app(Brightness.dark, userRecipes: [rezept]));
      await tester.pumpAndSettle();

      final kachel =
          find.byKey(const ValueKey('recipe-tile-user_mit_bild'));
      await tester.dragUntilVisible(
        kachel,
        find.byKey(const ValueKey('screen-recipes')),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: kachel, matching: find.byType(Image)),
        findsOneWidget,
        reason: 'Die Listenzeile muss die lokale Datei zeigen.',
      );
      expect(
        find.descendant(of: kachel, matching: find.byType(ImagePlaceholder)),
        findsNothing,
      );
    });

    testWidgets('ein zweites Geraet ohne die Bytes bekommt den Platzhalter',
        (tester) async {
      // Reference present (comes from the server row), file not.
      final rezept = _eigenes(
        slug: 'user_fremd',
        imageAsset: '${RecipeImageStore.referencePrefix}user_fremd.jpg',
      );

      pinPhoneViewport(tester);
      await tester.pumpWidget(_app(Brightness.light, userRecipes: [rezept]));
      await tester.pumpAndSettle();

      final kachel = find.byKey(const ValueKey('recipe-tile-user_fremd'));
      await tester.dragUntilVisible(
        kachel,
        find.byKey(const ValueKey('screen-recipes')),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: kachel, matching: find.byType(ImagePlaceholder)),
        findsOneWidget,
        reason: 'Kein graues Kaputt-Icon, kein toter Pfad — der Platzhalter.',
      );
    });

    testWidgets('die Detail-Ansicht zeigt das lokale Bild', (tester) async {
      final referenz = _legeAb(_store, 'user_detail', _jpeg());
      final rezept = _eigenes(slug: 'user_detail', imageAsset: referenz);

      pinPhoneViewport(tester);
      await tester.pumpWidget(_app(Brightness.dark, userRecipes: [rezept]));
      await tester.pumpAndSettle();

      final kachel = find.byKey(const ValueKey('recipe-tile-user_detail'));
      await tester.dragUntilVisible(
        kachel,
        find.byKey(const ValueKey('screen-recipes')),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      await tester.tap(kachel);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('recipe-detail-user_detail')),
          findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      expect(find.byType(ImagePlaceholder), findsNothing);
    });
  });

  testWidgets('Loeschen des Rezepts nimmt die Bytes mit', (tester) async {
    final referenz = _legeAb(_store, 'user_weg', _jpeg());
    final rezept = _eigenes(slug: 'user_weg', imageAsset: referenz);

    pinPhoneViewport(tester);
    await tester.pumpWidget(_app(Brightness.dark, userRecipes: [rezept]));
    await tester.pumpAndSettle();

    final kachel = find.byKey(const ValueKey('recipe-tile-user_weg'));
    await tester.dragUntilVisible(
      kachel,
      find.byKey(const ValueKey('screen-recipes')),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    await tester.tap(kachel);
    await tester.pumpAndSettle();

    expect(_store.resolveSync(referenz), isNotNull,
        reason: 'Vorbedingung: die Datei muss vorher da sein.');

    await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
    await tester.pumpAndSettle();

    // F6-03: inside the undo window nothing is committed yet, so the bytes
    // must still be there — the recipe could come back.
    expect(_store.resolveSync(referenz), isNotNull,
        reason: 'Solange „Rueckgaengig" moeglich ist, bleibt das Foto.');
    await tester.pump(kRecipeUndoWindow + const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(_store.resolveSync(referenz), isNull,
        reason: 'Ein geloeschtes Rezept darf sein Foto nicht auf der Platte '
            'zuruecklassen.');
  });

  group('Das Sheet bleibt heil', () {
    testWidgets('es hat weiterhin genau acht Textfelder', (tester) async {
      pinPhoneViewport(tester);
      await tester.pumpWidget(
        _app(Brightness.dark, photoInput: _FakeFotoquelle(bytes: _jpeg())),
      );
      await tester.pumpAndSettle();
      await _openSheet(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('recipe-create-sheet')),
          matching: find.byType(TextField),
        ),
        findsNWidgets(8),
      );
    });

    // Mode loop plus the separate 2.0 case, folded into one matrix: both
    // modes x normal and double system font, so hell@2.0 is covered too.
    renderMatrix(
      'Das Anlege-Sheet mit Foto rendert overflow-frei',
      (tester, c) async {
        pinPhoneViewport(tester);
        await c.pump(
          tester,
          _tab(photoInput: _FakeFotoquelle(bytes: _jpeg())),
          padding: _schalenrand,
          settle: true,
        );
        await _openSheet(tester);
        await tester
            .tap(find.byKey(const ValueKey('recipe-create-photo-camera')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('recipe-create-photo-preview')),
            findsOneWidget);
      },
      textScales: const <double>[1.0, 2.0],
    );

    testWidgets('bei normaler Schrift kommt es ohne Scrollen aus',
        (tester) async {
      // Not cosmetics but function: once the content exceeds `sheetMaxHeight`
      // (screen minus safe area minus keyboard minus 12 px; 840 px in this
      // viewport) the sheet becomes scrollable, and then the save button slides
      // off screen and the discard guard loses its drag, because a scroller
      // wins the gesture arena against `_DiscardDragGuard`.
      pinPhoneViewport(tester);
      await tester.pumpWidget(
        _app(Brightness.dark, photoInput: _FakeFotoquelle(bytes: _jpeg())),
      );
      await tester.pumpAndSettle();
      await _openSheet(tester);

      final hoehe = tester
          .getSize(find.byKey(const ValueKey('recipe-create-sheet')))
          .height;
      final rest = tester
          .state<ScrollableState>(find
              .descendant(
                of: find.byKey(const ValueKey('recipe-create-sheet')),
                matching: find.byType(Scrollable),
              )
              .first)
          .position
          .maxScrollExtent;
      debugPrint('Sheet-Hoehe bei normaler Schrift: $hoehe px '
          '(Rest-Scrollweg: $rest px)');
      expect(rest, 0.0,
          reason: 'Das Sheet scrollt — gemessener Inhalt: ${hoehe + rest} px '
              'auf 852 px Bildschirm (Deckel sheetMaxHeight = 840 px).');
      // 1179/3 x 2556/3 = 393 x 852 logical pixels. The test font is the worst
      // case (every glyph a full em); on device with Archivo the sheet is
      // shorter.
      //
      // The 92 % bound (783.84 px) is deliberately tighter than the safe-area
      // cap: an iPhone 14 Pro leaves only 773 px free, so content needing
      // 784 px here would already scroll there.
      expect(hoehe, lessThan(852 * 0.92));
      // Lower bound as a sanity anchor: a fraction here would mean the sheet
      // lost its content.
      expect(hoehe, greaterThan(300));
    });
  });
  group('Die vier Naehrwert-Felder stehen auf einer Linie', () {
    // The all-caps headers used to wrap freely: in an ~81 px column a two-word
    // label needs two lines and a short one needs one, so the input fields
    // below started at different heights.
    //
    // This measures the FIELDS, not the headers: headers may differ in height,
    // the boxes below must not jump.
    renderMatrix(
      'Die vier Naehrwert-Felder beginnen buendig',
      (tester, c) async {
        pinPhoneViewport(tester);
        await c.pump(
          tester,
          _tab(photoInput: _FakeFotoquelle()),
          padding: _schalenrand,
          settle: true,
        );
        await _openSheet(tester);

        double obenVon(String key) {
          final feld = find.byKey(ValueKey(key));
          expect(feld, findsOneWidget, reason: key);
          return tester.getRect(feld).top;
        }

        final kanten = <String, double>{
          for (final k in const <String>[
            'recipe-create-kcal',
            'recipe-create-protein',
            'recipe-create-carbs',
            'recipe-create-fat',
          ])
            k: obenVon(k),
        };

        // The grid drops from four to two columns above 1.25x text scale
        // (_FieldGrid), so which fields share a row depends on the scale —
        // computed here rather than guessed.
        final paare = c.textScale <= 1.25
            ? <List<String>>[
                <String>[
                  'recipe-create-kcal',
                  'recipe-create-protein',
                  'recipe-create-carbs',
                  'recipe-create-fat',
                ],
              ]
            : <List<String>>[
                <String>['recipe-create-kcal', 'recipe-create-protein'],
                <String>['recipe-create-carbs', 'recipe-create-fat'],
              ];

        for (final zeile in paare) {
          final tops = zeile.map((k) => kanten[k]!).toSet();
          expect(tops.length, 1,
              reason: 'Felder derselben Zeile (${zeile.join(", ")}) muessen '
                  'buendig beginnen, gemessen: $tops');
        }
      },
      textScales: const <double>[1.0, 1.3, 2.0],
    );
  });


}
