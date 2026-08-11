import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';

// „Mache, dass man ein Bild einfügen kann als Rezept."
//
// Der Weg: In-App-Auswahl (Kamera/Galerie) ueber die BESTEHENDE
// `MealPhotoInput`-Pipeline (die scrubt EXIF), Ablage lokal ueber
// [RecipeImageStore], Referenz `local:<name>.jpg` im vorhandenen Feld
// `imageAsset` (der Name kommt seit Finding 5 zufaellig aus dem Store, nicht
// mehr aus dem Slug). Kein Supabase-Bucket, keine zweite Pipeline.
//
// Diese Suite deckt die vier Punkte ab, an denen so etwas schiefgeht:
//   * Das Bild landet ueberhaupt am Rezept und ueberlebt den Neustart.
//   * Die Anzeige nimmt es in Karussell, Liste und Detail — und faellt bei
//     fehlender Datei auf den Platzhalter zurueck (zweites Geraet).
//   * Loeschen nimmt die Bytes mit.
//   * Das Sheet bleibt in beiden Modi und bei doppelter Schrift heil und hat
//     weiterhin GENAU acht Textfelder (der D5-Verwerfen-Schutz zaehlt sie).

/// Ein winziges, gueltiges JPEG — echte Bytes, damit `Image.memory`/
/// `Image.file` sie wirklich dekodieren koennen.
Uint8List _jpeg({int r = 200, int g = 80, int b = 40}) {
  final image = img.Image(width: 64, height: 48);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

/// Fotoquelle im Test: liefert immer dieselben Bytes und merkt sich, aus
/// welcher Quelle gefragt wurde.
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

/// Ablage-Double fuer den Widget-Test.
///
/// `testWidgets` laeuft unter FakeAsync: eine echte Datei-Operation (und erst
/// recht der `compute()`-Isolate im Scrubber) wuerde dort NIE fertig — der
/// erste Anlauf dieser Suite lief in den 10-Minuten-Timeout. Das Double macht
/// dieselbe Arbeit SYNCHRON auf einem echten Temp-Ordner: die Referenzen, die
/// Dateien und `resolveSync` sind real, nur ohne Isolate und ohne
/// Event-Loop-Runde. Die echte Ablage inklusive EXIF-Scrub prueft
/// test/services/recipe_image_store_test.dart.
class _TestImageStore extends RecipeImageStore {
  _TestImageStore(this.ordner) : super(baseDirectory: () async => ordner);

  final Directory ordner;

  /// Was das Sheet abgelegt hat — Referenz und Bytes.
  final Map<String, Uint8List> abgelegt = <String, Uint8List>{};

  /// Laufende Nummer statt Random.secure: der Widget-Test braucht nur
  /// Eindeutigkeit, die echte Zufaelligkeit prueft
  /// test/services/recipe_image_store_test.dart.
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

/// Legt eine Datei an, als waere sie in einer frueheren Sitzung gespeichert
/// worden — synchron, damit der Widget-Test nicht auf echtes IO wartet.
/// Der Name ist hier frei waehlbar; die Anzeige haengt nur an der Referenz.
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

void _pinViewport(WidgetTester tester, {double textScale = 1.0}) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Widget _app(
  Brightness brightness, {
  MealPhotoInput? photoInput,
  _CreateCapture? capture,
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
}) {
  return MaterialApp(
    theme: buildEatovaTheme(brightness),
    locale: const Locale('de'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: RecipesScreen(
            onAddMeal: (MealAnalysisResult _, MealSlot __) {},
            onCreateRecipe: capture?.add,
            photoInput: photoInput,
            initialUserRecipes: userRecipes,
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
}

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pumpAndSettle();
}

/// Sammelt Overflow-Fehler waehrend [body] (Muster aus recipes_design_test).
Future<void> _expectNoOverflow(String was, Future<void> Function() body) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      overflows.add('${details.summary}');
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  expect(overflows, isEmpty, reason: '$was overflowt:\n${overflows.join('\n')}');
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
      _pinViewport(tester);
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
      _pinViewport(tester);
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
      _pinViewport(tester);
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
      _pinViewport(tester);
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
      // Unberuehrt: das Sheet laesst sich weiterhin ohne Dialog schliessen.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsNothing);
    });

    testWidgets('ein gewaehltes Foto zaehlt als „ausgefuellt" (D5)',
        (tester) async {
      _pinViewport(tester);
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
      _pinViewport(tester);
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
      // Seit Finding 5 vergibt der Store den Namen (zufaellig) — das Rezept
      // traegt exakt die Referenz, die save() zurueckgab, nichts Abgeleitetes.
      expect(RecipeImageStore.isLocalReference(rezept.imageAsset), isTrue);
      expect(_store.abgelegt.keys, <String>[rezept.imageAsset]);
      expect(_store.resolveSync(rezept.imageAsset), isNotNull);
    });

    testWidgets('ohne Foto bleibt imageAsset leer (Abwaertskompatibilitaet)',
        (tester) async {
      _pinViewport(tester);
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
      // Und die Zeile bleibt wire-kompatibel: ein Rezept ohne Bild schreibt
      // weiterhin '' in image_asset und liest sich unveraendert zurueck.
      final zeile = capture.created.single.toRow();
      expect(zeile['image_asset'], '');
      expect(FitnessRecipe.fromRow(zeile).imageAsset, '');
    });

    testWidgets('eine alte Zeile ganz OHNE image_asset liest sich weiterhin',
        (tester) async {
      // Kein Widget noetig — steht hier, weil es dieselbe Zusicherung ist wie
      // oben: das Wire-Format bekommt KEIN neues Feld, der Marker lebt im
      // vorhandenen `image_asset`.
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

      _pinViewport(tester);
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
      // Referenz vorhanden (kommt ueber die Serverzeile), Datei nicht.
      final rezept = _eigenes(
        slug: 'user_fremd',
        imageAsset: '${RecipeImageStore.referencePrefix}user_fremd.jpg',
      );

      _pinViewport(tester);
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

      _pinViewport(tester);
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

    _pinViewport(tester);
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

    expect(_store.resolveSync(referenz), isNull,
        reason: 'Ein geloeschtes Rezept darf sein Foto nicht auf der Platte '
            'zuruecklassen.');
  });

  group('Das Sheet bleibt heil', () {
    testWidgets('es hat weiterhin genau acht Textfelder', (tester) async {
      _pinViewport(tester);
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

    for (final brightness in Brightness.values) {
      final modus = brightness == Brightness.light ? 'hell' : 'dunkel';
      testWidgets('mit Foto rendert es im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(
          _app(brightness, photoInput: _FakeFotoquelle(bytes: _jpeg())),
        );
        await tester.pumpAndSettle();
        await _openSheet(tester);
        await tester
            .tap(find.byKey(const ValueKey('recipe-create-photo-camera')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('recipe-create-photo-preview')),
            findsOneWidget);
      });
    }

    testWidgets('mit Foto overflowt es bei doppelter Schrift nicht',
        (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Das Anlege-Sheet mit Foto', () async {
        await tester.pumpWidget(
          _app(Brightness.dark, photoInput: _FakeFotoquelle(bytes: _jpeg())),
        );
        await tester.pumpAndSettle();
        await _openSheet(tester);
        await tester
            .tap(find.byKey(const ValueKey('recipe-create-photo-camera')));
        await tester.pumpAndSettle();
      });
    });

    testWidgets('bei normaler Schrift kommt es ohne Scrollen aus',
        (tester) async {
      // Das ist keine Kosmetik-Pruefung, sondern eine Funktionspruefung.
      // Sobald der Inhalt den 92-%-Deckel reisst, wird das Sheet scrollbar —
      // und dann passieren ZWEI Dinge: der Speichern-Knopf rutscht unter den
      // Bildschirmrand (Taps gehen ins Leere), und der Verwerfen-Schutz
      // verliert seinen Zug-Weg, weil ein Scroller die Gestenarena gegen den
      // `_DiscardDragGuard` gewinnt. Beides ist beim Umbau EINMAL passiert
      // (gemessene 889 px Inhalt); dieser Test ist die Bremse dagegen.
      _pinViewport(tester);
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
              'auf 852 px Bildschirm (Deckel 92 % = 783,84 px).');
      // 1179/3 x 2556/3 = 393 x 852 logische Pixel. Der Test-Font ist der
      // schlimmste Fall (jede Glyphe ein volles Geviert) — auf dem Geraet
      // faellt das Sheet mit Archivo deutlich kuerzer aus.
      expect(hoehe, lessThan(852 * 0.92));
      // Untergrenze als Plausibilitaets-Anker: waere hier ploetzlich ein
      // Bruchteil, haette das Sheet seinen Inhalt verloren.
      expect(hoehe, greaterThan(300));
    });
  });
  group('Die vier Naehrwert-Felder stehen auf einer Linie', () {
    // Nutzer-Befund 2026-08-10: „bei Rezepte Hinzufuegen ist KH und Fett
    // weiter oben als die anderen 2 kleinen Boxen Kcal und Protein."
    //
    // Ursache: Die Versalien-Kopfzeile war ein frei umbrechender Text. In
    // einer ~81-px-Spalte braucht „KALORIEN · KCAL" zwei Zeilen, „KH · G"
    // eine — und weil die Spalten oben buendig stehen, begannen die
    // Eingabefelder auf verschiedenen Hoehen.
    //
    // Der Test misst die FELDER, nicht die Kopfzeilen: die Kopfzeile darf
    // ruhig unterschiedlich breit sein, die Boxen darunter nicht springen.
    for (final skalierung in <double>[1.0, 1.3, 2.0]) {
      testWidgets('bei Systemschrift ${skalierung}x', (tester) async {
        _pinViewport(tester, textScale: skalierung);
        await tester.pumpWidget(
          _app(Brightness.dark, photoInput: _FakeFotoquelle()),
        );
        await tester.pumpAndSettle();
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

        // Das Raster bricht ab 1,25-facher Schrift von vier auf zwei
        // Spalten um (_FieldGrid). Welche Felder eine Zeile bilden, haengt
        // also von der Schriftgroesse ab — der Test rechnet das nach, statt
        // eine Anordnung zu raten.
        final paare = skalierung <= 1.25
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
      });
    }
  });


}
