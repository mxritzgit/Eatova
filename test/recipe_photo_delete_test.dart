// Audit 2026-08-14: Das Rezeptfoto fiel SOFORT, bevor feststand, ob die
// Loeschung ueberhaupt zugestellt wird.
//
// Der teure Fall ist der verworfene Delete: die Op landet in der Outbox,
// scheitert dort tage- und dutzendfach und wird endgueltig verworfen — dann
// blendet `_restoreDroppedDeletes` das Rezept BEWUSST wieder ein, damit der
// Verlust sichtbar und reparierbar ist. Zurueck kam es bis zu diesem Fix mit
// einer `local:`-Referenz ins Leere: die Bytes lagen ausschliesslich auf
// diesem Geraet und waren endgueltig weg.
//
// Diese Suite misst beide Richtungen:
//   (a) Loeschung NICHT zugestellt + Rezept wieder eingeblendet -> die Datei
//       liegt noch da UND die Kachel zeigt sie wieder.
//   (b) Loeschung zugestellt -> die Datei ist weg (PII bleibt nicht liegen).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';

/// Ein winziges, gueltiges JPEG — echte Bytes, damit `Image.file` sie wirklich
/// dekodieren koennte.
Uint8List _jpeg() {
  final image = img.Image(width: 64, height: 48);
  img.fill(image, color: img.ColorRgb8(200, 80, 40));
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

/// Ablage-Double wie in recipe_create_photo_test.dart: `testWidgets` laeuft
/// unter FakeAsync, echte Datei-Operationen wuerden dort nie fertig. Das
/// Double macht dieselbe Arbeit SYNCHRON auf einem echten Temp-Ordner — die
/// Dateien und `resolveSync` sind real, nur ohne Event-Loop-Runde.
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
}

/// Legt eine Datei an, als waere sie in einer frueheren Sitzung gespeichert
/// worden — synchron, damit der Widget-Test nicht auf echtes IO wartet.
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

/// Harness fuer den Store-Teil, den der Screen sieht.
///
/// Bildet die zwei Bewegungen nach, auf die es hier ankommt, ohne Sync-Schale:
///   * `onDeleteRecipe` meldet den Ausgang, den [ausgang] vorgibt, und nimmt
///     das Rezept aus der Liste (wie `HomeStore.deleteUserRecipe`).
///   * Der Restore-Knopf reicht eine NEUE Liste mit dem Rezept nach — genau
///     das tut `_restoreDroppedDeletes` nach einem endgueltig verworfenen
///     Delete (`_mutate` -> neue `userRecipes`-Identitaet -> `didUpdateWidget`).
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
    return MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
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
    );
  }
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

/// Erst an den Anfang, dann nach unten suchen: `dragUntilVisible` zieht nur in
/// EINE Richtung und faende eine Kachel oberhalb der aktuellen Position nie.
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

/// Loescht das Rezept ueber die Detail-Ansicht — der einzige Einstieg, den es
/// dafuer gibt.
Future<void> _loescheUeberDetail(WidgetTester tester, String slug) async {
  await tester.tap(await _holeKachelInsBild(tester, slug));
  await tester.pumpAndSettle();
  expect(find.byKey(ValueKey('recipe-detail-$slug')), findsOneWidget);

  await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
  await tester.pumpAndSettle();
  // Den Ausgangs-Toast ablaufen lassen: er liegt sonst ueber der
  // Harness-Schaltflaeche und faengt deren Tap ab.
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
      // queuedOffline heisst: die Op liegt in der Outbox. Ob sie je zugestellt
      // wird, ist genau JETZT offen — und der Weg, auf dem sie verworfen wird,
      // endet in der Wiedereinblendung unten.
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
}
