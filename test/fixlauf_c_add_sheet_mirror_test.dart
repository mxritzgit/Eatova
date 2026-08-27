// Fix run for review 2026-08-27, F3-01: every add path of the add-meal sheet
// (inline favorite, favorites sheet, manual entry) must mirror the new row
// into the sheet's "already added" list and its slot total right away — the
// sheet keeps a local copy and does not rebuild from the store.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

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

MealAnalysisResult _mahlzeit(String name, {int kcal = 250}) {
  return MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: 100,
    kcalPer100G: kcal.toDouble(),
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'Datenbank',
    portionNotes: '',
  );
}

FavoriteMeal _favorit(String name, {bool gepinnt = false}) {
  final result = _mahlzeit(name);
  return FavoriteMeal(
    id: FavoriteMeal.idFor(result),
    result: result,
    addedAt: DateTime(2026, 8, 5),
    pinned: gepinnt,
  );
}

/// Fake store side of the edit sheet: keeps the row on its ARCHIVE day
/// (2026-08-20) like the real store does, so a mirror row logged "today"
/// would be dropped by the sheet's day comparison.
class _EditCapture {
  String? id;
  MealSlot? slot;

  LoggedMeal? update(
    String id, {
    MealAnalysisResult? result,
    MealSlot? slot,
    DateTime? day,
  }) {
    this.id = id;
    this.slot = slot;
    return LoggedMeal(
      id: id,
      result: result ?? _mahlzeit('Apfel'),
      loggedAt: DateTime(2026, 8, 20, 12),
      forcedSlot: slot ?? MealSlot.snack,
      localDay: '2026-08-20',
    );
  }
}

Future<void> _pumpe(
  WidgetTester tester, {
  List<FavoriteMeal> favoriten = const <FavoriteMeal>[],
  List<LoggedMeal> vorhanden = const <LoggedMeal>[],
  DateTime? foodDate,
  _EditCapture? capture,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  var nextId = 1;
  await tester.pumpWidget(
    MaterialApp(
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
        body: AddMealSheet(
          slot: MealSlot.snack,
          analyzer: _StummerAnalyzer(),
          productService: _StummerProduktdienst(),
          photoInput: _StummeFotoquelle(),
          favorites: favoriten,
          existingMeals: vorhanden,
          foodDate: foodDate,
          onAdd: (_, __) => 'id-${nextId++}',
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
          onRemoveMeal: (_) {},
          onUpdateMealDetails: capture?.update,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final Finder _liste = find.byKey(const ValueKey('analyse-existing-meals'));

Finder _zeile(String name) =>
    find.descendant(of: _liste, matching: find.text(name));

Finder _summe(String kcal) => find.descendant(
      of: find.byKey(const ValueKey('analyse-existing-total-kcal')),
      matching: find.text('$kcal kcal'),
      matchRoot: true,
    );

Future<void> _fuegeHinzu(WidgetTester tester, String kachel, String knopf) async {
  await tester.tap(find.byKey(ValueKey(kachel)));
  await tester.pumpAndSettle();
  final add = find.byKey(ValueKey(knopf));
  await tester.ensureVisible(add);
  await tester.tap(add);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'Favorit hinzufügen: „Bereits hinzugefügt" zeigt die neue Zeile und die '
      'Slot-Summe steigt sofort', (tester) async {
    await _pumpe(
      tester,
      favoriten: [_favorit('Apfel')],
      vorhanden: [
        LoggedMeal(
          id: 'm-1',
          result: _mahlzeit('Brot', kcal: 100),
          loggedAt: DateTime.now(),
          forcedSlot: MealSlot.snack,
        ),
      ],
    );
    expect(_zeile('Brot'), findsOneWidget);
    expect(_summe('100'), findsOneWidget);
    expect(_zeile('Apfel'), findsNothing);

    await _fuegeHinzu(tester, 'favorite-tile-0', 'favorite-tile-add-0');

    expect(_zeile('Apfel'), findsOneWidget);
    expect(_zeile('Brot'), findsOneWidget);
    expect(_summe('350'), findsOneWidget);
  });

  testWidgets('ohne Vorhandenes erscheint die Liste mit der ersten Zeile',
      (tester) async {
    await _pumpe(tester, favoriten: [_favorit('Apfel')]);
    expect(_liste, findsNothing);

    await _fuegeHinzu(tester, 'favorite-tile-0', 'favorite-tile-add-0');

    expect(_liste, findsOneWidget);
    expect(_zeile('Apfel'), findsOneWidget);
    expect(_summe('250'), findsOneWidget);
  });

  testWidgets('Favoriten-Sheet: dort Hinzugefügtes landet ebenfalls in der Liste',
      (tester) async {
    await _pumpe(tester, favoriten: [_favorit('Skyr', gepinnt: true)]);

    final alle = find.byKey(const ValueKey('add-meal-favorites-all'));
    await tester.ensureVisible(alle);
    await tester.tap(alle);
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('favorites-sheet'));
    expect(sheet, findsOneWidget);

    await _fuegeHinzu(tester, 'favorites-sheet-item-0', 'favorites-sheet-add-0');
    Navigator.of(tester.element(sheet)).pop();
    await tester.pumpAndSettle();

    expect(_zeile('Skyr'), findsOneWidget);
    expect(_summe('250'), findsOneWidget);
  });

  testWidgets('manueller Eintrag spiegelt sich in Liste und Summe',
      (tester) async {
    await _pumpe(tester, favoriten: [_favorit('Apfel')]);

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
      '125',
    );
    await tester.pump();
    final save = find.byKey(const ValueKey('manual-meal-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(_zeile('Bauern-Mozzarella'), findsOneWidget);
    expect(_summe('331'), findsOneWidget);
  });

  testWidgets(
      'Archivtag: die gespiegelte Zeile trägt den Tag des Sheets und '
      'überlebt eine Slot-Änderung im Bearbeiten-Sheet', (tester) async {
    final capture = _EditCapture();
    await _pumpe(
      tester,
      favoriten: [_favorit('Apfel')],
      foodDate: DateTime(2026, 8, 20),
      capture: capture,
    );

    await _fuegeHinzu(tester, 'favorite-tile-0', 'favorite-tile-add-0');
    expect(_zeile('Apfel'), findsOneWidget);

    // Edit the mirrored row: only the slot changes, the day stays 2026-08-20.
    await tester.tap(find.byKey(const ValueKey('analyse-existing-edit-id-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('edit-meal-save-button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(capture.id, 'id-1');
    expect(capture.slot, MealSlot.lunch);

    // The row moved to lunch instead of vanishing from the sheet.
    await tester.tap(find.byKey(const ValueKey('slot-select-lunch')));
    await tester.pumpAndSettle();
    expect(_zeile('Apfel'), findsOneWidget);
    expect(localDayKey(DateTime(2026, 8, 20)), '2026-08-20');
  });
}
