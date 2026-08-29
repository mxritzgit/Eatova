// Audit 2026-08-14: the recipe photo was deleted immediately, before it was
// known whether the deletion would ever be delivered.
//
// The expensive case is a dropped delete: `_restoreDroppedDeletes` brings the
// recipe back so the loss stays visible and repairable — but it came back with
// a dangling `local:` reference, and the bytes existed only on this device.
//
// Both directions are pinned here:
//   (a) delete NOT delivered + recipe restored -> the file still exists AND
//       the tile shows it again;
//   (b) delete delivered -> the file is gone (no PII left behind).

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
import 'package:eatova/src/widgets/design/design.dart';

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
  Future<void> deleteFor(String imageAsset) async {
    if (!RecipeImageStore.isLocalReference(imageAsset)) return;
    final datei = _datei(imageAsset);
    if (datei.existsSync()) datei.deleteSync();
  }

  @override
  Future<void> clear() async {
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

/// Harness for the store slice the screen sees, without the sync shell:
///   * `onDeleteRecipe` reports [ausgang] and removes the recipe from the list;
///   * the restore button hands in a NEW list containing the recipe, exactly as
///     `_restoreDroppedDeletes` does after a finally dropped delete.
class _StoreHarness extends StatefulWidget {
  const _StoreHarness({required this.rezept, required this.ausgang});

  final FitnessRecipe rezept;
  final SyncDelivery ausgang;

  @override
  State<_StoreHarness> createState() => _StoreHarnessState();
}

class _StoreHarnessState extends State<_StoreHarness> {
  late List<FitnessRecipe> _rezepte = <FitnessRecipe>[widget.rezept];

  Future<SyncDelivery> _delete(String slug) async {
    setState(() {
      _rezepte = _rezepte.where((r) => r.slug != slug).toList(growable: false);
    });
    return widget.ausgang;
  }

  void _restore() {
    setState(() => _rezepte = <FitnessRecipe>[widget.rezept]);
  }

  @override
  Widget build(BuildContext context) {
    // `localizedApp` instead of `pumpLocalized`: this MaterialApp is the build
    // output of a StatefulWidget, and the Scaffold carries its own
    // bottomNavigationBar.
    return localizedApp(
      Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: RecipesScreen(
              onAddMeal: (MealAnalysisResult _, MealSlot __) {},
              onDeleteRecipe: _delete,
              initialUserRecipes: _rezepte,
            ),
          ),
        ),
        bottomNavigationBar: TextButton(
          key: const ValueKey('harness-restore'),
          onPressed: _restore,
          child: const Text('Wieder einblenden'),
        ),
      ),
      scaffold: false,
      safeArea: false,
    );
  }
}

/// Harness for the orphan sweep (P3-04). It starts with the list the store
/// holds BEFORE hydration — empty, and no statement whatsoever about what lies
/// on the disk — and delivers the real one on demand, exactly as
/// `StoreSelector` does when `_userRecipes` is assigned for the first time.
class _HydrationHarness extends StatefulWidget {
  const _HydrationHarness({required this.rezepte, this.sofort = false,
      this.persistenz = true});

  /// What hydration (cache or boot load) eventually delivers.
  final List<FitnessRecipe> rezepte;

  /// True = the screen is built when the list is already there.
  final bool sofort;

  /// False = preview/test without sync: the recipe list is session-local and
  /// says nothing about the disk.
  final bool persistenz;

  @override
  State<_HydrationHarness> createState() => _HydrationHarnessState();
}

class _HydrationHarnessState extends State<_HydrationHarness> {
  late List<FitnessRecipe> _rezepte =
      widget.sofort ? widget.rezepte : const <FitnessRecipe>[];

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
              ),
            ),
          ),
          bottomNavigationBar: TextButton(
            key: const ValueKey('harness-hydrate'),
            // A NEW list each time, like every store mutation.
            onPressed: () => setState(
                () => _rezepte = List<FitnessRecipe>.of(widget.rezepte)),
            child: const Text('Hydrieren'),
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
  // Let the outcome toast expire, or it covers the harness button and
  // swallows its tap.
  await tester.pump(const Duration(seconds: 4));
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

  testWidgets(
      'verworfene Loeschung: die Datei bleibt liegen und das wieder '
      'eingeblendete Rezept zeigt sie', (tester) async {
    final referenz = _legeAb(_store, 'user_verworfen', _jpeg());
    final rezept = _eigenes(slug: 'user_verworfen', imageAsset: referenz);

    _pinViewport(tester);
    await tester.pumpWidget(
      // queuedOffline: the op sits in the outbox and delivery is still open;
      // the drop path ends in the restore below.
      _StoreHarness(rezept: rezept, ausgang: SyncDelivery.queuedOffline),
    );
    await tester.pumpAndSettle();

    final kachel = await _holeKachelInsBild(tester, 'user_verworfen');
    expect(
      find.descendant(of: kachel, matching: find.byType(Image)),
      findsOneWidget,
      reason: 'Vorbedingung: die Kachel zeigt anfangs das eigene Foto.',
    );

    await _loescheUeberDetail(tester, 'user_verworfen');
    expect(find.byKey(const ValueKey('recipe-tile-user_verworfen')),
        findsNothing,
        reason: 'Vorbedingung: lokal ist das Rezept weg.');

    expect(_store.resolveSync(referenz), isNotNull,
        reason: 'Solange die Loeschung nur in der Warteschlange liegt, darf '
            'das Foto nicht fallen — es liegt ausschliesslich hier.');

    await tester.tap(find.byKey(const ValueKey('harness-restore')));
    await tester.pumpAndSettle();

    final zurueck = await _holeKachelInsBild(tester, 'user_verworfen');
    expect(
      find.descendant(of: zurueck, matching: find.byType(Image)),
      findsOneWidget,
      reason: 'Das wieder eingeblendete Rezept muss sein Bild wieder zeigen.',
    );
    expect(
      find.descendant(of: zurueck, matching: find.byType(ImagePlaceholder)),
      findsNothing,
      reason: 'Ein Platzhalter hiesse: die Referenz zeigt ins Leere.',
    );
  });

  testWidgets('zugestellte Loeschung nimmt die Bytes mit', (tester) async {
    final referenz = _legeAb(_store, 'user_weg', _jpeg());
    final rezept = _eigenes(slug: 'user_weg', imageAsset: referenz);

    _pinViewport(tester);
    await tester.pumpWidget(
      _StoreHarness(rezept: rezept, ausgang: SyncDelivery.delivered),
    );
    await tester.pumpAndSettle();

    expect(_store.resolveSync(referenz), isNotNull,
        reason: 'Vorbedingung: die Datei muss vorher da sein.');

    await _loescheUeberDetail(tester, 'user_weg');

    expect(_store.resolveSync(referenz), isNull,
        reason: 'Ein zugestellt geloeschtes Rezept darf sein Foto nicht auf '
            'der Platte zuruecklassen — es ist PII.');
  });

  // Review 2026-08-29, P3-04: `deleteFor` is the ONLY release, and only for a
  // delete this device makes AND the server acknowledges at once. A delete on
  // device B never reaches this device, an offline delete is deliberately not
  // followed up, and an abandoned coach adoption leaves its bytes lying. The
  // screen is the only place that knows the real recipe list, so it drives the
  // comparison — a blind cap would delete photos whose recipe still exists.
  group('P3-04: Abgleich gegen die tatsaechlich vorhandenen Rezepte', () {
    testWidgets('vor der Hydration wird nichts abgeglichen', (tester) async {
      final referenz = _legeAb(_store, 'user_a', _jpeg());
      _pinViewport(tester);

      await tester.pumpWidget(_HydrationHarness(
        rezepte: <FitnessRecipe>[
          _eigenes(slug: 'user_a', imageAsset: referenz),
        ],
      ));
      await tester.pumpAndSettle();

      expect(_store.abgleiche, isEmpty,
          reason: 'Die leere Liste vor dem Cache-/Server-Load ist keine '
              'Aussage ueber die Platte — ein Abgleich darauf loeschte jedes '
              'Foto des Nutzers.');
    });

    testWidgets('die erste gelieferte Liste startet genau einen Abgleich',
        (tester) async {
      final referenz = _legeAb(_store, 'user_a', _jpeg());
      _pinViewport(tester);

      await tester.pumpWidget(_HydrationHarness(
        rezepte: <FitnessRecipe>[
          _eigenes(slug: 'user_a', imageAsset: referenz),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('harness-hydrate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('harness-hydrate')));
      await tester.pumpAndSettle();

      expect(_store.abgleiche, hasLength(1),
          reason: 'Ein Verzeichnis-Scan pro Sitzung reicht; jede weitere '
              'Store-Meldung waere reine Last.');
      expect(_store.abgleiche.single, contains(referenz));
    });

    testWidgets('eine beim Aufbau schon vorhandene Liste wird abgeglichen',
        (tester) async {
      final referenz = _legeAb(_store, 'user_a', _jpeg());
      _pinViewport(tester);

      await tester.pumpWidget(_HydrationHarness(
        sofort: true,
        rezepte: <FitnessRecipe>[
          _eigenes(slug: 'user_a', imageAsset: referenz),
        ],
      ));
      await tester.pumpAndSettle();

      expect(_store.abgleiche.single, contains(referenz),
          reason: 'Der Tab wird auch nach abgeschlossener Hydration erst '
              'aufgebaut — dann kommt die Liste ueber initState.');
    });

    testWidgets('ohne echte Persistenz wird nie abgeglichen', (tester) async {
      final referenz = _legeAb(_store, 'user_a', _jpeg());
      _pinViewport(tester);

      await tester.pumpWidget(_HydrationHarness(
        persistenz: false,
        rezepte: <FitnessRecipe>[
          _eigenes(slug: 'user_a', imageAsset: referenz),
        ],
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('harness-hydrate')));
      await tester.pumpAndSettle();

      expect(_store.abgleiche, isEmpty,
          reason: 'Vorschau und Tests halten ihre Rezepte nur in der Sitzung; '
              'diese Liste darf nichts von der Platte nehmen.');
    });

  });
}
