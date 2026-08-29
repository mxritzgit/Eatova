// Review 2026-08-29, P8-01/-05/-06/-07 — one root, four symptoms: the
// add-meal sheet opened with a COPY of the store's "already added" list and of
// the favorites and only ever wrote INTO that copy. Anything the store did on
// its own never arrived: an undone delete, an undone favorite removal, a
// favorite the store dropped at its recents cap, a recent the store rewrote
// with the logged result.
//
// The sheet now follows the store through `FoodStoreScope`. These tests drive
// a fake store through the REAL opener (showAddMealSheet) and assert what the
// sheet shows — never just what a callback received.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import 'support/harness.dart';

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummerProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

MealAnalysisResult _mahlzeit(String name, {int kcal = 250, int gramm = 100}) {
  return MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: gramm,
    kcalPer100G: kcal * 100 / gramm,
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'Datenbank',
    portionNotes: '',
  );
}

FavoriteMeal _favorit(
  MealAnalysisResult result, {
  bool gepinnt = false,
  int tag = 5,
}) {
  return FavoriteMeal(
    id: FavoriteMeal.idFor(result),
    result: result,
    addedAt: DateTime(2026, 8, tag),
    pinned: gepinnt,
  );
}

/// The store side, reduced to what the sheet may observe: both lists are
/// REASSIGNED on every mutation (like `HomeStore`), so their identity is the
/// change fingerprint the sheet relies on.
class _FakeFoodStore extends ChangeNotifier {
  _FakeFoodStore({
    List<LoggedMeal> meals = const <LoggedMeal>[],
    List<FavoriteMeal> favorites = const <FavoriteMeal>[],
  })  : meals = List<LoggedMeal>.of(meals),
        favorites = List<FavoriteMeal>.of(favorites);

  List<LoggedMeal> meals;
  List<FavoriteMeal> favorites;

  String logMeal(MealAnalysisResult result, MealSlot slot) {
    final entry = LoggedMeal(
      id: 'store-${meals.length + 1}',
      result: result,
      loggedAt: DateTime(2026, 8, 29, 12),
      forcedSlot: slot,
    );
    meals = <LoggedMeal>[entry, ...meals];
    // Like HomeStore._rememberRecent: a fresh entry built from the LOGGED
    // result, moved to the front, pinned state preserved.
    final id = FavoriteMeal.idFor(result);
    final bisher = favorites.where((f) => f.id == id);
    favorites = <FavoriteMeal>[
      FavoriteMeal(
        id: id,
        result: result,
        addedAt: DateTime(2026, 8, 29, 12),
        pinned: bisher.isNotEmpty && bisher.first.pinned,
      ),
      ...favorites.where((f) => f.id != id),
    ];
    notifyListeners();
    return entry.id;
  }

  void removeMeal(String id) {
    meals = meals.where((m) => m.id != id).toList();
    notifyListeners();
  }

  /// What the store's undo snack does (`_restoreLoggedMeal`).
  void restoreMeal(LoggedMeal meal) {
    meals = <LoggedMeal>[meal, ...meals];
    notifyListeners();
  }

  void removeFavorite(String id) {
    favorites = favorites.where((f) => f.id != id).toList();
    notifyListeners();
  }

  /// What the store's undo snack does (`_restoreFavorite`).
  void restoreFavorite(FavoriteMeal favorite) {
    favorites = <FavoriteMeal>[favorite, ...favorites];
    notifyListeners();
  }

  /// Unpinning that the recents cap turns into a DELETE — `toggleFavorite`
  /// with `survived == false` (P8-06).
  void unpinAndDrop(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    favorites = favorites.where((f) => f.id != id).toList();
    notifyListeners();
  }

  /// What the boot load does (`home_store.dart`, `loadedFavorites`): the list
  /// is REPLACED by freshly parsed server rows — same content, new instances.
  void reloadFromServer() {
    favorites = favorites
        .map((f) => FavoriteMeal(
              id: f.id,
              result: _frischGeparst(f.result),
              addedAt: f.addedAt,
              pinned: f.pinned,
            ))
        .toList();
    notifyListeners();
  }

  /// Ein Server-Load, der wirklich etwas anderes bringt: gleicher Eintrag,
  /// neue Zahlen.
  void replaceFavoriteResult(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    favorites = <FavoriteMeal>[
      for (final f in favorites)
        if (f.id == id)
          FavoriteMeal(
            id: f.id,
            result: result,
            addedAt: f.addedAt,
            pinned: f.pinned,
          )
        else
          f,
    ];
    notifyListeners();
  }

  /// A notify that changes neither list — steps, sync, profile.
  void tick() => notifyListeners();
}

/// Feld für Feld dasselbe Ergebnis, aber eine neue Instanz — was
/// `mealResultFromJson` beim Boot-Load aus der Server-Zeile baut.
MealAnalysisResult _frischGeparst(MealAnalysisResult r) {
  return MealAnalysisResult(
    mealName: r.mealName,
    caloriesKcal: r.caloriesKcal,
    estimatedGrams: r.estimatedGrams,
    kcalPer100G: r.kcalPer100G,
    protein: r.protein,
    carbs: r.carbs,
    fat: r.fat,
    confidence: r.confidence,
    portionNotes: r.portionNotes,
    items: List<MealComponent>.of(r.items),
    isAdjusted: r.isAdjusted,
    sourceLabel: r.sourceLabel,
    barcode: r.barcode,
    brand: r.brand,
    explicitZeroKcal: r.explicitZeroKcal,
  );
}

final Finder _liste = find.byKey(const ValueKey('analyse-existing-meals'));

Finder _zeile(String name) =>
    find.descendant(of: _liste, matching: find.text(name));

Finder _summe(String kcal) => find.descendant(
      of: find.byKey(const ValueKey('analyse-existing-total-kcal')),
      matching: find.text('$kcal kcal'),
      matchRoot: true,
    );

/// Mounts a host under the scope and opens the sheet through the real opener —
/// the live channel lives there, not in [AddMealSheet].
///
/// [mitScope] false is the standalone path (previews, plain widget tests):
/// without a [FoodStoreScope] the sheet never gets re-fed and its own mirror
/// writes are all it has. Only there does `_touchFavorite` decide alone.
Future<void> _oeffneSheet(
  WidgetTester tester,
  _FakeFoodStore store, {
  ValueChanged<MealAnalysisResult>? onToggleFavorite,
  bool mitScope = true,
}) async {
  pinPhoneViewport(tester);
  final host = Builder(
    builder: (context) => TextButton(
      key: const ValueKey('sheet-oeffnen'),
      onPressed: () => showAddMealSheet(
        context,
        slot: MealSlot.snack,
        analyzer: _StummerAnalyzer(),
        productService: _StummerProduktdienst(),
        photoInput: _StummeFotoquelle(),
        favorites: store.favorites,
        existingMeals: store.meals,
        onAdd: store.logMeal,
        onUpdateMeal: (_, __) {},
        onRemoveFavorite: store.removeFavorite,
        onRemoveMeal: store.removeMeal,
        isFavorite: (result) {
          final treffer =
              store.favorites.where((f) => f.id == FavoriteMeal.idFor(result));
          return treffer.isNotEmpty && treffer.first.pinned;
        },
        onToggleFavorite: onToggleFavorite,
      ),
      child: const Text('auf'),
    ),
  );
  await pumpLocalized(
    tester,
    mitScope
        ? FoodStoreScope(
            store: store,
            mealsOfSelectedDay: () => store.meals,
            favorites: () => store.favorites,
            child: host,
          )
        : host,
    reducedMotion: false,
  );
  await tester.tap(find.byKey(const ValueKey('sheet-oeffnen')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);
}

/// Das Gramm-Feld der ersten Recent-Kachel — es traegt keinen eigenen Key und
/// ist das einzige TextField der Kachel.
final Finder _grammFeld = find.descendant(
  of: find.byKey(const ValueKey('favorite-tile-0')),
  matching: find.byType(TextField),
);

/// Klappt die erste Recent-Kachel auf und tippt [gramm] ins Portionsfeld.
Future<void> _tippeGramm(WidgetTester tester, String gramm) async {
  await tester.tap(find.byKey(const ValueKey('favorite-tile-0')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(_grammFeld);
  await tester.enterText(_grammFeld, gramm);
  await tester.pump();
}

/// Legt „Apfel" mit [kcal100] kcal/100 g ueber den manuellen Eintrag an.
Future<void> _logManuell(
  WidgetTester tester, {
  required String name,
  required String kcal100,
}) async {
  await tester.tap(find.byKey(const ValueKey('manual-entry-button')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('manual-meal-name')), name);
  await tester.enterText(
    find.byKey(const ValueKey('manual-meal-kcal100')),
    kcal100,
  );
  await tester.enterText(find.byKey(const ValueKey('manual-meal-grams')), '100');
  await tester.pump();
  final speichern = find.byKey(const ValueKey('manual-meal-save'));
  await tester.ensureVisible(speichern);
  await tester.tap(speichern);
  await tester.pumpAndSettle();
}

/// The X inside a suggestion tile (it carries no key of its own).
Finder _kachelX(String kachel) => find.descendant(
      of: find.byKey(ValueKey(kachel)),
      matching: find.byTooltip('Entfernen'),
    );

void main() {
  testWidgets(
      'P8-01: nach dem Rückgängig des Stores steht die Zeile wieder im Sheet',
      (tester) async {
    final brot = LoggedMeal(
      id: 'm-1',
      result: _mahlzeit('Brot', kcal: 100),
      loggedAt: DateTime(2026, 8, 29, 9),
      forcedSlot: MealSlot.snack,
    );
    final store = _FakeFoodStore(meals: <LoggedMeal>[brot]);
    await _oeffneSheet(tester, store);

    expect(_zeile('Brot'), findsOneWidget);
    expect(_summe('100'), findsOneWidget);

    final entfernen = find.byKey(const ValueKey('analyse-existing-remove-m-1'));
    await tester.ensureVisible(entfernen);
    await tester.tap(entfernen);
    await tester.pumpAndSettle();
    expect(_liste, findsNothing, reason: 'die einzige Zeile ist weg');

    // Exactly what the store's undo snack does.
    store.restoreMeal(brot);
    await tester.pumpAndSettle();

    expect(
      _zeile('Brot'),
      findsOneWidget,
      reason: 'das Rückgängig erreicht den Spiegel des Sheets nicht',
    );
    expect(
      _summe('100'),
      findsOneWidget,
      reason: 'die Slot-Summe bleibt dauerhaft zu niedrig',
    );
  });

  testWidgets(
      'P8-05: nach dem Rückgängig steht der Favorit wieder in der Liste',
      (tester) async {
    final apfel = _favorit(_mahlzeit('Apfel'));
    final store = _FakeFoodStore(favorites: <FavoriteMeal>[apfel]);
    await _oeffneSheet(tester, store);

    expect(find.text('Apfel'), findsOneWidget);

    final x = _kachelX('favorite-tile-0');
    await tester.ensureVisible(x);
    await tester.tap(x);
    await tester.pumpAndSettle();
    expect(find.text('Apfel'), findsNothing);

    store.restoreFavorite(apfel);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('favorite-tile-0')),
      findsOneWidget,
      reason: 'das Rückgängig erreicht die Favoritenliste des Sheets nicht',
    );
    expect(find.text('Apfel'), findsOneWidget);
  });

  testWidgets(
      'P8-06: entpinnen, das der Store löscht, entfernt die Kachel auch hier',
      (tester) async {
    final skyr = _mahlzeit('Skyr');
    final store = _FakeFoodStore(
      favorites: <FavoriteMeal>[_favorit(skyr, gepinnt: true, tag: 20)],
    );
    await _oeffneSheet(tester, store, onToggleFavorite: (result) {
      // The store's cap turns this unpin into a favoriteDelete.
      store.unpinAndDrop(result);
    });

    expect(find.byKey(const ValueKey('favorite-pinned-0')), findsOneWidget);

    final herz = find.byKey(const ValueKey('favorite-pinned-0-fav'));
    await tester.ensureVisible(herz);
    await tester.tap(herz);
    await tester.pumpAndSettle();

    expect(
      find.text('Skyr'),
      findsNothing,
      reason: 'der Eintrag ist im Store weg, das Sheet zeigt ihn weiter',
    );
    expect(find.byKey(const ValueKey('favorite-tile-0')), findsNothing);
  });

  testWidgets(
      'P8-07: der Store schreibt den Recent neu — die Kachel zeigt das Neue',
      (tester) async {
    // 250 kcal auf 100 g; derselbe Name wird gleich mit 500 kcal geloggt.
    final store = _FakeFoodStore(
      favorites: <FavoriteMeal>[_favorit(_mahlzeit('Apfel', kcal: 250))],
    );
    await _oeffneSheet(tester, store);
    expect(find.text('250 kcal / 100 g'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('manual-entry-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-name')),
      'Apfel',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-kcal100')),
      '500',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-grams')),
      '100',
    );
    await tester.pump();
    final speichern = find.byKey(const ValueKey('manual-meal-save'));
    await tester.ensureVisible(speichern);
    await tester.tap(speichern);
    await tester.pumpAndSettle();

    expect(
      find.text('500 kcal / 100 g'),
      findsOneWidget,
      reason: 'die Kachel hängt am alten result, der Store hat ein neues',
    );
    expect(find.text('250 kcal / 100 g'), findsNothing);
  });

  testWidgets(
      'P8-07: einen vom Store NEU angelegten Recent zeigt das Sheet ebenfalls',
      (tester) async {
    final store = _FakeFoodStore();
    await _oeffneSheet(tester, store);
    expect(find.byKey(const ValueKey('favorite-tile-0')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('manual-entry-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-name')),
      'Bauern-Mozzarella',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-kcal100')),
      '265',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-grams')),
      '100',
    );
    await tester.pump();
    final speichern = find.byKey(const ValueKey('manual-meal-save'));
    await tester.ensureVisible(speichern);
    await tester.tap(speichern);
    await tester.pumpAndSettle();

    final kachel = find.byKey(const ValueKey('favorite-tile-0'));
    await tester.ensureVisible(kachel);
    expect(
      find.descendant(of: kachel, matching: find.text('Bauern-Mozzarella')),
      findsOneWidget,
      reason: '_touchFavorite lässt unbekannte Einträge liegen; der Store legt '
          'den Recent an und das Sheet muss ihn übernehmen',
    );
  });

  testWidgets(
      'ein Store-Tick ohne Listenänderung wirft die eingetippten Gramm nicht weg',
      (tester) async {
    final store = _FakeFoodStore(
      favorites: <FavoriteMeal>[_favorit(_mahlzeit('Apfel'))],
    );
    await _oeffneSheet(tester, store);
    await _tippeGramm(tester, '175');

    // Steps, sync, profile — a notify that touches neither list.
    store.tick();
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(_grammFeld).controller!.text,
      '175',
      reason: 'der identical-Reset in MealSuggestionItem feuert unnötig',
    );
  });

  // P8-07b (1): der committete P8-07-Test lief MIT Scope, und dort schreibt der
  // Reseed die Kachel im selben Frame neu. Er blieb deshalb auch gegen die alte
  // `copyWith(addedAt:)`-Fassung von `_touchFavorite` gruen. Ohne Scope
  // entscheidet `_touchFavorite` allein.
  testWidgets(
      'P8-07b: ohne Scope schreibt _touchFavorite den Recent selbst neu',
      (tester) async {
    final store = _FakeFoodStore(
      favorites: <FavoriteMeal>[_favorit(_mahlzeit('Apfel', kcal: 250))],
    );
    await _oeffneSheet(tester, store, mitScope: false);
    expect(find.text('250 kcal / 100 g'), findsOneWidget);

    await _logManuell(tester, name: 'Apfel', kcal100: '500');

    expect(
      find.text('500 kcal / 100 g'),
      findsOneWidget,
      reason: 'copyWith(addedAt:) verschiebt nur den Zeitstempel und laesst '
          'das alte result stehen — ohne Scope raeumt das niemand auf',
    );
    expect(find.text('250 kcal / 100 g'), findsNothing);
  });

  // P8-07b (2): der Boot-Load ersetzt die Favoritenliste durch frisch geparste
  // Server-Zeilen — gleicher Inhalt, neue Instanzen. Vor dem Welle-1-Fix war
  // das offene Sheet immun, weil es nie zuhoerte.
  testWidgets(
      'P8-07b: ein Boot-Load mit gleichem Inhalt laesst die Eingabe stehen',
      (tester) async {
    final store = _FakeFoodStore(
      favorites: <FavoriteMeal>[_favorit(_mahlzeit('Apfel'))],
    );
    await _oeffneSheet(tester, store);
    await _tippeGramm(tester, '175');

    store.reloadFromServer();
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(_grammFeld).controller!.text,
      '175',
      reason: 'gleicher Inhalt in neuen Objekten darf die Eingabe nicht '
          'zurueckwerfen',
    );
  });

  testWidgets(
      'P8-07b: ein wirklich geänderter Favorit setzt die Eingabe sehr wohl '
      'zurück', (tester) async {
    final store = _FakeFoodStore(
      favorites: <FavoriteMeal>[_favorit(_mahlzeit('Apfel', kcal: 250))],
    );
    await _oeffneSheet(tester, store);
    await _tippeGramm(tester, '175');

    // Gleicher Eintrag, andere Zahlen — der identical-Reset muss greifen.
    store.replaceFavoriteResult(_mahlzeit('Apfel', kcal: 500));
    await tester.pumpAndSettle();

    expect(find.text('500 kcal / 100 g'), findsOneWidget);
    expect(
      tester.widget<TextField>(_grammFeld).controller!.text,
      '100',
      reason: 'eine echt geaenderte Portion soll die Eingabe zuruecksetzen',
    );
  });
}
