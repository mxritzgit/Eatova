import 'support/recipe_navigation.dart';

// Audit 2026-08-14: the recipe photo was deleted immediately, before it was
// known whether the deletion would ever be delivered. A failed delete or an
// explicit history restore can bring the recipe back, and the bytes exist
// only on this device.
//
// Pinned here:
//   (a) no delete path releases a photo itself, not even a delivered one;
//   (b) only the orphan sweep releases photos, and only against a complete
//       statement: the answered boot load plus the version-history
//       references (P3-04/P3-04b).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

/// A tiny valid JPEG — real bytes, so `Image.file` could actually decode it.
Uint8List _jpeg() {
  final image = img.Image(width: 64, height: 48);
  img.fill(image, color: img.ColorRgb8(200, 80, 40));
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

/// Store double as in recipe_create_photo_test.dart: `testWidgets` runs under
/// FakeAsync, where real file operations never finish. This does the same work
/// synchronously on a real temp directory.
class _TestImageStore extends RecipeImageStore {
  _TestImageStore(this.ordner) : super(baseDirectory: () async => ordner);

  final Directory ordner;

  @override
  bool get baseResolved => true;

  File _datei(String reference) => File(
    '${ordner.path}/'
    '${reference.substring(RecipeImageStore.referencePrefix.length)}',
  );

  @override
  File? resolveSync(String imageAsset) {
    if (!RecipeImageStore.isLocalReference(imageAsset)) return null;
    final datei = _datei(imageAsset);
    return datei.existsSync() ? datei : null;
  }

  @override
  Future<File?> resolve(String imageAsset) async => resolveSync(imageAsset);

  @override
  Future<void> clear({
    String? expectedUserId,
    String? expectedSessionId,
  }) async {
    if (ordner.existsSync()) ordner.deleteSync(recursive: true);
  }

  /// Live sets the screen handed over, one entry per sweep.
  final List<List<String>> abgleiche = <List<String>>[];

  @override
  Future<int> reconcileRecipePhotos(Iterable<String> liveReferences) async {
    abgleiche.add(liveReferences.toList(growable: false));
    return 0;
  }
}

/// Writes a file as if saved in an earlier session, synchronously so the
/// widget test never waits on real IO.
String _legeAb(_TestImageStore store, String name, Uint8List bytes) {
  final reference = '${RecipeImageStore.referencePrefix}$name.jpg';
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

/// Harness for the orphan sweep (P3-04/P3-04b). It models the two store events
/// the screen sees, and keeps them APART:
///
///   * "Hydrieren" = `_hydrateFromCache` assigns the cache slot — a new list
///     identity, but the boot load is still running;
///   * "Boot" = the boot load answered (`userRecipesAuthoritative`), the only
///     moment the list is a complete statement about which recipes exist.
class _HydrationHarness extends StatefulWidget {
  const _HydrationHarness({
    required this.rezepte,
    this.sofort = false,
    this.bootFertig = false,
    this.persistenz = true,
    this.historie = const <String>{},
  });

  /// What hydration and the boot load eventually deliver.
  final List<FitnessRecipe> rezepte;

  /// True = the screen is built when the list is already there.
  final bool sofort;

  /// True = the screen is built when the boot load has already answered (the
  /// lazy tab, opened after the boot).
  final bool bootFertig;

  /// False = preview/test without sync: the recipe list is session-local and
  /// says nothing about the disk.
  final bool persistenz;

  /// Photo references of the version history (`recipePhotoReferences`).
  final Set<String> historie;

  @override
  State<_HydrationHarness> createState() => _HydrationHarnessState();
}

class _HydrationHarnessState extends State<_HydrationHarness> {
  late List<FitnessRecipe> _rezepte = widget.sofort
      ? widget.rezepte
      : const <FitnessRecipe>[];
  late bool _bootFertig = widget.bootFertig;

  /// Der beantwortete Boot-Load ohne Tap — waehrend eines Undo-Fensters deckt
  /// der Snack den Knopf zu, und ein Tap darauf ginge ins Leere.
  void meldeBoot() => setState(() {
    _rezepte = List<FitnessRecipe>.of(widget.rezepte);
    _bootFertig = true;
  });

  @override
  Widget build(BuildContext context) => localizedApp(
    Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: RecipesScreen(
            onAddMeal: (MealAnalysisResult _, MealSlot __) {},
            onDeleteRecipe: widget.persistenz
                ? (_) async => SyncDelivery.delivered
                : null,
            initialUserRecipes: _rezepte,
            userRecipesAuthoritative: _bootFertig,
            recipePhotoReferences: widget.historie,
          ),
        ),
      ),
      bottomNavigationBar: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          TextButton(
            key: const ValueKey('harness-hydrate'),
            // A NEW list each time, like every store mutation.
            onPressed: () => setState(
              () => _rezepte = List<FitnessRecipe>.of(widget.rezepte),
            ),
            child: const Text('Hydrieren'),
          ),
          TextButton(
            key: const ValueKey('harness-boot'),
            onPressed: meldeBoot,
            child: const Text('Boot'),
          ),
        ],
      ),
    ),
    scaffold: false,
    safeArea: false,
  );
}

late Directory _temp;
late _TestImageStore _store;

void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ScrollPosition _listPosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byKey(const ValueKey('screen-recipes')),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position;
}

/// Jump to the top first: `dragUntilVisible` drags in one direction only and
/// would never find a tile above the current position.
Future<Finder> _holeKachelInsBild(WidgetTester tester, String slug) async {
  await selectRecipeSection(tester, 'own');
  _listPosition(tester).jumpTo(0);
  await tester.pumpAndSettle();
  final kachel = find.byKey(ValueKey('recipe-tile-$slug'));
  await tester.dragUntilVisible(
    kachel,
    find.byKey(const ValueKey('screen-recipes')),
    const Offset(0, -250),
  );
  await tester.pumpAndSettle();
  return kachel;
}

/// Deletes the recipe through the detail view, the only entry point for it.
Future<void> _loescheUeberDetail(WidgetTester tester, String slug) async {
  await tester.tap(await _holeKachelInsBild(tester, slug));
  await tester.pumpAndSettle();
  expect(find.byKey(ValueKey('recipe-detail-$slug')), findsOneWidget);

  await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    _temp = await Directory.systemTemp.createTemp('eatova_recipe_delete_test');
    _store = _TestImageStore(Directory('${_temp.path}/recipe_images'));
    RecipeImageStore.instance = _store;
  });

  tearDown(() async {
    RecipeImageStore.resetInstance();
    if (_temp.existsSync()) await _temp.delete(recursive: true);
  });

  testWidgets('eine zugestellte Loeschung laesst das Foto liegen — weder im '
      'Undo-Fenster noch nach dem Commit', (tester) async {
    final referenz = _legeAb(_store, 'user_weg', _jpeg());
    _pinViewport(tester);
    await tester.pumpWidget(
      _HydrationHarness(
        sofort: true,
        bootFertig: true,
        rezepte: <FitnessRecipe>[
          _eigenes(slug: 'user_weg', imageAsset: referenz),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await _loescheUeberDetail(tester, 'user_weg');
    expect(
      _store.resolveSync(referenz),
      isNotNull,
      reason: 'Solange „Rueckgaengig" moeglich ist, bleibt das Foto.',
    );
    // The undo window passes: the delete is committed and delivered.
    await tester.pump(kRecipeUndoWindow + const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(
      _store.resolveSync(referenz),
      isNotNull,
      reason:
          'Die Versionshistorie haelt das Rezept wiederherstellbar; nur der '
          'Abgleich gegen den vollstaendigen Bestand darf das Foto nehmen.',
    );
  });

  // Review 2026-08-29, P3-04: no delete path releases a photo itself. A
  // delete on device B never reaches this device, and an abandoned coach
  // adoption leaves its bytes lying. The screen is the only place that knows
  // the real recipe list, so it drives the comparison — a blind cap would
  // delete photos whose recipe still exists.
  group('P3-04: Abgleich gegen die tatsaechlich vorhandenen Rezepte', () {
    testWidgets('der beantwortete Boot-Load startet genau einen Abgleich — die '
        'Hydration davor keinen', (tester) async {
      final referenz = _legeAb(_store, 'user_a', _jpeg());
      _pinViewport(tester);

      await tester.pumpWidget(
        _HydrationHarness(
          rezepte: <FitnessRecipe>[
            _eigenes(slug: 'user_a', imageAsset: referenz),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(_store.abgleiche, isEmpty, reason: 'vor jeder Hydration');

      await tester.tap(find.byKey(const ValueKey('harness-hydrate')));
      await tester.pumpAndSettle();
      expect(
        _store.abgleiche,
        isEmpty,
        reason:
            'Der Cache-Slot ist eine Anzeige-Quelle, keine vollstaendige '
            'Aussage: der Boot-Load laeuft noch.',
      );

      await tester.tap(find.byKey(const ValueKey('harness-boot')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('harness-boot')));
      await tester.pumpAndSettle();

      expect(
        _store.abgleiche,
        hasLength(1),
        reason:
            'Ein Verzeichnis-Scan pro Sitzung reicht; jede weitere '
            'Store-Meldung waere reine Last.',
      );
      expect(_store.abgleiche.single, contains(referenz));
    });

    testWidgets('eine beim Aufbau schon fertige Liste wird abgeglichen', (
      tester,
    ) async {
      final referenz = _legeAb(_store, 'user_a', _jpeg());
      _pinViewport(tester);

      await tester.pumpWidget(
        _HydrationHarness(
          sofort: true,
          bootFertig: true,
          rezepte: <FitnessRecipe>[
            _eigenes(slug: 'user_a', imageAsset: referenz),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _store.abgleiche.single,
        contains(referenz),
        reason:
            'Der Tab wird auch nach abgeschlossenem Boot erst aufgebaut '
            '(IndexedStack) — dann kommt die Liste ueber initState und ein '
            'didUpdateWidget folgt nie.',
      );
    });

    testWidgets('ein Foto, das nur noch die Versionshistorie nennt, bleibt im '
        'Behalte-Satz', (tester) async {
      // After a delivered delete the recipe is gone from the list, but its
      // version can be restored; only the history snapshot names the photo.
      final referenz = _legeAb(_store, 'user_geloescht', _jpeg());
      _pinViewport(tester);

      await tester.pumpWidget(
        _HydrationHarness(
          sofort: true,
          bootFertig: true,
          rezepte: const <FitnessRecipe>[],
          historie: {referenz},
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _store.abgleiche.single,
        contains(referenz),
        reason:
            'Ohne die Historien-Referenzen fiele das Foto, und eine '
            'Wiederherstellung kaeme mit toter local:-Referenz zurueck.',
      );
    });

    testWidgets('ohne echte Persistenz wird nie abgeglichen', (tester) async {
      final referenz = _legeAb(_store, 'user_a', _jpeg());
      _pinViewport(tester);

      await tester.pumpWidget(
        _HydrationHarness(
          persistenz: false,
          rezepte: <FitnessRecipe>[
            _eigenes(slug: 'user_a', imageAsset: referenz),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('harness-boot')));
      await tester.pumpAndSettle();

      expect(
        _store.abgleiche,
        isEmpty,
        reason:
            'Vorschau und Tests halten ihre Rezepte nur in der Sitzung; '
            'diese Liste darf nichts von der Platte nehmen.',
      );
    });

    // P3-04b, der Datenverlustpfad des Pruefers. `_cacheUserRecipes` ist um
    // 400 ms entprellt: wird die App in diesem Fenster getoetet, NACHDEM der
    // Upsert live durchging (also ohne ueberlebende Outbox-Op), liegt beim
    // naechsten Start ein veraltet-leerer Rezepte-Slot da. Die Hydration weist
    // ihn zu — eine frische Listen-Identitaet, von einer echten Antwort nicht
    // zu unterscheiden. Wer daran den Abgleich festmacht, loescht jede
    // img_*-Datei, waehrend der Boot-Load die zugehoerigen Rezepte gerade erst
    // holt; die Fotos liegen ausschliesslich auf diesem Geraet.
    //
    // Die beiden Faelle beschreiben zusammen die Regel: leer ist erlaubt,
    // unfertig nicht.
    testWidgets(
      'veraltet-leerer Cache-Slot waehrend des Bootens: kein Abgleich',
      (tester) async {
        final referenz = _legeAb(_store, 'user_verwaist', _jpeg());
        _pinViewport(tester);

        // Der Store liefert die leere Liste — der Boot-Load laeuft noch.
        await tester.pumpWidget(
          const _HydrationHarness(rezepte: <FitnessRecipe>[]),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('harness-hydrate')));
        await tester.pumpAndSettle();

        expect(
          _store.abgleiche,
          isEmpty,
          reason:
              'Ein Abgleich gegen die leere Liste haette hier jedes Foto '
              'geloescht — der Boot-Load bringt das Rezept Sekunden spaeter '
              'mit einer ins Leere zeigenden local:-Referenz zurueck.',
        );
        expect(
          _store.resolveSync(referenz),
          isNotNull,
          reason: 'Und die Bytes liegen nur hier: kein Server hat eine Kopie.',
        );
      },
    );

    testWidgets(
      'alle Rezepte geloescht: nach beantwortetem Boot-Load wird trotzdem '
      'eingesammelt',
      (tester) async {
        _legeAb(_store, 'user_verwaist', _jpeg());
        _pinViewport(tester);

        await tester.pumpWidget(
          const _HydrationHarness(rezepte: <FitnessRecipe>[]),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('harness-boot')));
        await tester.pumpAndSettle();

        // Die Loeschung selbst prueft test/services/recipe_image_store_test.dart;
        // hier zaehlt, dass der Abgleich mit LEEREM Behalte-Satz laeuft.
        expect(
          _store.abgleiche,
          hasLength(1),
          reason:
              'Eine leere Liste ist ein gueltiger Zustand — hat der Nutzer '
              'alle Rezepte geloescht, muss das Aufraeumen laufen. Ein '
              'isNotEmpty-Waechter waere die falsche Reparatur.',
        );
        expect(
          _store.abgleiche.single,
          isEmpty,
          reason: 'Kein Rezept mehr = kein Foto behalten.',
        );
      },
    );

    testWidgets(
      'ein Rezept IM Undo-Fenster zaehlt beim Abgleich als vorhanden',
      (tester) async {
        // Der Sweep uebergibt `_userRecipes`, nicht `_visibleUserRecipes`. Der
        // Unterschied sind genau die Rezepte in ihrem Undo-Fenster: lokal schon
        // unsichtbar, aber noch nicht persistiert. Faendet der Abgleich sie
        // nicht in der Behalte-Liste, fielen ihre Bytes SOFORT — und ein Tap auf
        // „Rueckgaengig" brachte ein Rezept mit toter local:-Referenz zurueck.
        final referenz = _legeAb(_store, 'user_a', _jpeg());
        _pinViewport(tester);

        await tester.pumpWidget(
          _HydrationHarness(
            sofort: true,
            rezepte: <FitnessRecipe>[
              _eigenes(slug: 'user_a', imageAsset: referenz),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          _store.abgleiche,
          isEmpty,
          reason: 'Vorbedingung: der Boot-Load hat noch nicht geantwortet.',
        );

        // Loeschen, aber die Frist NICHT ablaufen lassen.
        await _loescheUeberDetail(tester, 'user_a');
        expect(
          find.text('Rückgängig'),
          findsOneWidget,
          reason: 'Vorbedingung: das Undo-Fenster laeuft noch.',
        );
        expect(
          find.byKey(const ValueKey('recipe-tile-user_a')),
          findsNothing,
          reason: 'Vorbedingung: lokal ist das Rezept schon ausgeblendet.',
        );

        // Der Boot-Load antwortet jetzt — direkt am State, weil der Snack den
        // Knopf verdeckt.
        tester
            .state<_HydrationHarnessState>(find.byType(_HydrationHarness))
            .meldeBoot();
        await tester.pumpAndSettle();

        expect(_store.abgleiche, hasLength(1));
        expect(
          _store.abgleiche.single,
          contains(referenz),
          reason:
              'Solange „Rueckgaengig" moeglich ist, braucht das Rezept '
              'seine Bytes — sie liegen ausschliesslich auf diesem Geraet.',
        );

        // Frist auslaufen lassen, sonst haengt am Testende ein Timer.
        await tester.pump(kRecipeUndoWindow + const Duration(seconds: 1));
        await tester.pumpAndSettle();
      },
    );
  });
}
