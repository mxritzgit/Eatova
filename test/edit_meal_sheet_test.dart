import 'support/food_navigation.dart';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';

import 'support/harness.dart';
import 'support/meal_slot_picker.dart';
import 'support/pinned_clock.dart';

// Edit sheet: tapping a logged meal opens a sheet that changes portion/items,
// slot and day and saves through the outbox-safe store path. Standalone tests
// drive the sheet directly; the integration tests run through the real app
// shell (EatovaApp) and thus MealEditScope + HomeStore.

MealAnalysisResult _result() => const MealAnalysisResult(
      mealName: 'Test-Bowl',
      caloriesKcal: 350,
      estimatedGrams: 350,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

LoggedMeal _loggedMeal() => LoggedMeal(
      id: 'meal-1',
      result: _result(),
      loggedAt: clock.now(),
      // Fixed slot instead of the time-of-day heuristic: deterministic at any
      // test run time.
      forcedSlot: MealSlot.breakfast,
    );

class _EditCapture {
  int updateCalls = 0;
  String? id;
  MealAnalysisResult? result;
  MealSlot? slot;
  DateTime? day;
  final List<String> removed = <String>[];

  LoggedMeal? update(
    String id, {
    MealAnalysisResult? result,
    MealSlot? slot,
    DateTime? day,
  }) {
    updateCalls++;
    this.id = id;
    this.result = result;
    this.slot = slot;
    this.day = day;
    return _loggedMeal().copyWith(
      result: result,
      forcedSlot: slot,
      localDay: day == null ? null : localDayKey(DateUtils.dateOnly(day)),
    );
  }
}

Future<void> _openSheet(
  WidgetTester tester,
  _EditCapture capture, {
  bool withRemove = true,
  double textScale = 1.0,
  Size? surfaceSize,
  LoggedMeal? meal,
}) async {
  await pumpLocalized(
    tester,
    textScale: textScale,
    surfaceSize: surfaceSize,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showEditMealSheet(
            context,
            meal: meal ?? _loggedMeal(),
            onUpdateMeal: capture.update,
            onRemoveMeal: withRemove ? capture.removed.add : null,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Noon on a mid-month Wednesday; tests that pick days pin the clock here.
final DateTime _mittwoch = DateTime(2026, 6, 17, 12);

/// The Today strip's cell for the day [daysAgo] before today (injected clock).
Finder _tagVor(int daysAgo) {
  final today = DateUtils.dateOnly(clock.now());
  return find.byKey(
    ValueKey<String>(
      'today-day-${localDayKey(DateTime(today.year, today.month, today.day - daysAgo))}',
    ),
  );
}

void main() {
  testWidgetsRobust('Slot + Tag aendern ruft den Store einmal korrekt auf', (
    WidgetTester tester,
  ) => withClockAt(_mittwoch, () async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
    expect(find.text('Mahlzeit bearbeiten'), findsOneWidget);
    expect(find.text('Test-Bowl'), findsOneWidget);
    expect(find.text('350\u00a0kcal · 350\u00a0g'), findsOneWidget);

    // Without a change, save is disabled.
    final saveButton = find.byKey(const ValueKey('edit-meal-save-button'));
    expect(tester.widget<PrimaryActionButton>(saveButton).onTap, isNull);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();
    expect(tester.widget<PrimaryActionButton>(saveButton).onTap, isNotNull);

    // Day: yesterday in the 7-day strip.
    await tester.tap(_tagVor(1));
    await tester.pumpAndSettle();

    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(capture.updateCalls, 1);
    expect(capture.id, 'meal-1');
    expect(capture.slot, MealSlot.lunch);
    expect(capture.result, isNull, reason: 'Portion wurde nicht angefasst');
    // B5: calendar arithmetic, not Duration — otherwise the test itself is
    // wrong across the spring DST switch.
    final yesterday = addDays(startOfDay(clock.now()), -1);
    expect(DateUtils.isSameDay(capture.day!, yesterday), isTrue);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsNothing);
  }));

  testWidgetsRobust(
      'Portion ueber den bestehenden Einzelposten-Editor anpassen und speichern',
      (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tap(find.byKey(const ValueKey('edit-meal-adjust-button')));
    await tester.pumpAndSettle();

    // The existing editor from meal_widgets_adjust.dart opens.
    expect(find.text('Bestandteile anpassen'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('analyse-item-weight-input-0')),
      '200',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('analyse-save-weight-button')));
    await tester.pumpAndSettle();

    // Back in the edit sheet: the summary shows the new values.
    expect(find.text('200\u00a0kcal · 200\u00a0g'), findsOneWidget);
    expect(find.text('Angepasst'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit-meal-save-button')));
    await tester.pumpAndSettle();

    expect(capture.updateCalls, 1);
    expect(capture.result, isNotNull);
    expect(capture.result!.estimatedGrams, 200);
    expect(capture.result!.caloriesKcal, 200);
    expect(capture.slot, isNull);
    expect(capture.day, isNull);
  });

  testWidgetsRobust(
      'Namen korrigieren: ein KI-Eintrag ueber „Name aendern", ein manueller '
      'ueber „Werte aendern"', (WidgetTester tester) async {
    Future<void> save() async {
      final button = find.byKey(const ValueKey('edit-meal-save-button'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    final scan = _EditCapture();
    await _openSheet(tester, scan);
    expect(find.byKey(const ValueKey('edit-meal-quick-values')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('edit-meal-rename')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('meal-rename-field'));
    expect(tester.widget<TextField>(field).controller!.text, 'Test-Bowl');
    await tester.enterText(field, 'Lachs-Bowl');
    await tester.tap(find.byKey(const ValueKey('meal-rename-save')));
    await tester.pumpAndSettle();
    expect(find.text('Lachs-Bowl'), findsOneWidget, reason: 'Kopfzeile');
    await save();
    expect(scan.result!.mealName, 'Lachs-Bowl');
    expect(scan.result!.caloriesKcal, 350);

    final manual = _EditCapture();
    await _openSheet(
      tester,
      manual,
      meal: LoggedMeal(
        id: 'meal-2',
        result: MealAnalysisResult.manualEntry(
          name: 'Hfermilch',
          kcalPer100G: 47,
          grams: 250,
          proteinPer100G: 1,
        ),
        loggedAt: clock.now(),
        forcedSlot: MealSlot.breakfast,
      ),
    );
    expect(find.byKey(const ValueKey('edit-meal-rename')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('edit-meal-quick-values')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-name')),
      'Hafermilch',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('manual-meal-save')));
    await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
    await tester.pumpAndSettle();
    await save();
    expect(manual.result!.mealName, 'Hafermilch');
    expect(manual.result!.estimatedGrams, 250);
    expect(manual.result!.protein, '2,5 g', reason: 'Werte bleiben erhalten');
  });

  testWidgetsRobust(
      '„Anderes Datum…" oeffnet den Kalender; der gewaehlte Tag geht als day '
      'an den Store', (WidgetTester tester) => withClockAt(_mittwoch, () async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    final kalender = find.byKey(const ValueKey('edit-day-calendar'));
    await tester.ensureVisible(kalender);
    await tester.pumpAndSettle();
    await tester.tap(kalender);
    await tester.pumpAndSettle();
    // The app's own calendar sheet, titled and confirmed with "Tag wählen".
    final blatt = find.byKey(const ValueKey('food-date-picker'));
    expect(blatt, findsOneWidget);
    expect(
      find.descendant(of: blatt, matching: find.text('Tag wählen')),
      findsNWidgets(2),
    );

    // Page to the previous month and pick the 15th: it exists in every month
    // and always lies in the past.
    await tester.tap(
      find.descendant(
        of: blatt,
        matching: find.byKey(const ValueKey('food-date-month-previous')),
      ),
    );
    await tester.pumpAndSettle();
    // Inside the calendar grid: the sheet's header also shows the chosen
    // day's number, which is 15 on the 15th of a month.
    await tester.tap(
      find.descendant(
        of: find.byType(FoodMonthCalendar),
        matching: find.text('15'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-date-confirm')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('edit-meal-save-button')));
    await tester.pumpAndSettle();

    final today = DateUtils.dateOnly(clock.now());
    expect(capture.updateCalls, 1);
    expect(capture.day, DateTime(today.year, today.month - 1, 15));
    expect(capture.slot, isNull, reason: 'Slot wurde nicht angefasst');
    expect(capture.result, isNull, reason: 'Portion wurde nicht angefasst');
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsNothing);
  }));

  // ─── D5: a filled-in form is no longer discarded silently ───────────────
  //
  // Both dismiss paths of a modal bottom sheet are checked because the
  // framework runs them differently:
  //   * barrier tap -> ModalBarrier.handleDismiss -> Navigator.maybePop
  //     (consults PopScope)
  //   * drag down -> BottomSheet._handleDragEnd -> onClosing -> Navigator.pop
  //     (does NOT consult PopScope)
  // A plain PopScope therefore covers only half.

  testWidgetsRobust(
      'D5: Barriere-Tap bei ungespeicherter Aenderung fragt nach, statt zu '
      'verwerfen', (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();

    // Top left is the barrier, not the sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
    expect(capture.updateCalls, 0);
  });

  testWidgetsRobust(
      'D5: Sheet nach unten ziehen bei ungespeicherter Aenderung fragt nach',
      (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();

    // Drag on the header, above the scroll area, where the BottomSheet's
    // drag-to-dismiss applies.
    await tester.drag(find.text('Mahlzeit bearbeiten'), const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
    expect(capture.updateCalls, 0);
  });

  testWidgetsRobust(
      'D5: „Abbrechen" im Verwerfen-Dialog laesst das Sheet mit der Aenderung '
      'offen', (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
    // The change is still there: save stays enabled.
    expect(
      tester
          .widget<PrimaryActionButton>(
              find.byKey(const ValueKey('edit-meal-save-button')))
          .onTap,
      isNotNull,
    );
  });

  testWidgetsRobust(
      'D5: „Verwerfen" schliesst das Sheet ohne Store-Aufruf',
      (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsNothing);
    expect(capture.updateCalls, 0);
    expect(capture.removed, isEmpty);
  });

  testWidgetsRobust(
      'D5: ein Tap neben den Dialog ist „Abbrechen" — der Dialog wird nicht '
      'vom Sheet-Dismiss verschluckt', (WidgetTester tester) async {
    // The dialog sits on the root navigator above the sheet route, so its own
    // barrier catches the tap.
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
  });

  testWidgetsRobust(
      'D5: ohne Aenderung schliesst der Barriere-Tap sofort — kein Dialog',
      (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsNothing);
  });

  testWidgetsRobust(
      'D5: ohne Aenderung schliesst auch das Ziehen sofort — kein Dialog',
      (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.drag(find.text('Mahlzeit bearbeiten'), const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsNothing);
  });

  testWidgetsRobust(
      'D5: das Schliessen-Kreuz fragt bei ungespeicherter Aenderung ebenfalls',
      (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-meal-sheet-close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
  });

  testWidgetsRobust(
      'D5: Loeschen laeuft ohne Verwerfen-Dialog durch, auch mit Aenderung',
      (WidgetTester tester) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-lunch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-meal-delete-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsNothing);
    expect(capture.removed, ['meal-1']);
    expect(capture.updateCalls, 0, reason: 'delete never saves the change');
  });

  testWidgetsRobust('Ohne Remove-Callback gibt es keinen Loeschen-Button', (
    WidgetTester tester,
  ) async {
    final capture = _EditCapture();
    await _openSheet(tester, capture, withRemove: false);

    expect(find.byKey(const ValueKey('edit-meal-delete-button')), findsNothing);
  });

  // Large text: the source label leaves the figure's line instead of
  // squeezing "350 kcal · 350 g" into a word per line (review DSA-4), and the
  // figure breaks after the "·", never inside "350 kcal" or "350 g" (DSA-11).
  testWidgetsRobust(
      'Summary at 2x: source label under the figure, number and unit together',
      (WidgetTester tester) async {
    await _openSheet(
      tester,
      _EditCapture(),
      textScale: 2,
      surfaceSize: const Size(320, 900),
    );
    final figureFinder = find.byKey(const ValueKey('edit-meal-summary-figure'));
    final figure = tester.getRect(figureFinder);
    final source = tester.getRect(
      find.byKey(const ValueKey('edit-meal-summary-source')),
    );
    expect(source.top, greaterThanOrEqualTo(figure.bottom));
    expect(source.left, closeTo(figure.left, 0.5));

    // A no-break space binds each number to its unit; the line breaker of the
    // real fonts honours it (the test font is too wide to show the break).
    final text = tester
        .renderObject<RenderParagraph>(figureFinder)
        .text
        .toPlainText();
    expect(text, '350 kcal · 350 g');
  });

  // ─── Integration through the real app shell ─────────────────────────────

  testWidgetsRobust(
      'Verlauf: Tap auf Eintrag oeffnet Bearbeiten-Sheet, Slot-Wechsel wird '
      'gespeichert und im Verlauf sichtbar', (WidgetTester tester) async {
    // Pin the device language: without an override EatovaApp resolves via
    // resolveEatovaLocale, and the assertions below check verbatim German ARB
    // texts.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(productService: _FakeProductLookupService()),
    );
    await _addSalamiViaSearch(tester, slotKey: 'slot-select-breakfast');
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    await expandFoodEntries(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('food-history-entry-0')));
    await tester.tap(find.byKey(const ValueKey('food-history-entry-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
    expect(find.text('Mahlzeit bearbeiten'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit-slot-select-snack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-meal-save-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsNothing);
    expect(find.text('Mahlzeit aktualisiert.'), findsOneWidget);
    await expandFoodEntries(tester);
    // The entry now stands in the Snacks card (the redesigned rows carry no
    // slot label; the card is the slot).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('food-slot-card-snack')),
        matching: find.byKey(const ValueKey('food-history-entry-0')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('food-slot-empty-breakfast')),
      findsOneWidget,
    );
  });

  testWidgetsRobust(
      'Tagesliste im Add-Sheet: Verschieben auf gestern raeumt heute und '
      'fuellt gestern', (WidgetTester tester) => withClockAt(_mittwoch, () async {
    // Pin the device language: without an override EatovaApp resolves via
    // resolveEatovaLocale, and the assertions below check verbatim German ARB
    // texts.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(productService: _FakeProductLookupService()),
    );
    await _addSalamiViaSearch(tester, slotKey: 'slot-select-breakfast');
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // Reopen the sheet (the day list is filled on open) and pick the meal slot.
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();
    await chooseMealSlot(tester, 'slot-select-breakfast');
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('analyse-existing-meals')), findsOneWidget);

    // Tap the row -> edit sheet -> day to yesterday -> save.
    final editRow = find.byWidgetPredicate((w) =>
        w is InkWell &&
        (w.key?.toString().contains('analyse-existing-edit-') ?? false));
    expect(editRow, findsOneWidget);
    await tester.tap(editRow);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);

    await tester.tap(_tagVor(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-meal-save-button')));
    await tester.pumpAndSettle();

    // Back in the add sheet: today's day list is empty -> block gone.
    expect(find.byKey(const ValueKey('analyse-existing-meals')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // Today: no history entry left. Yesterday (chip-1; the strip runs
    // descending, index = day offset): entry present.
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
    await selectFoodDayOffset(tester, 1);
    await tester.pumpAndSettle();
    await expandFoodEntries(tester);
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
  }));
}

/// Adds the fake salami pizza to slot [slotKey] via the search flow and leaves
/// the add sheet open.
Future<void> _addSalamiViaSearch(
  WidgetTester tester, {
  required String slotKey,
}) async {
  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('food-search')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('kcal-product-search-input')),
    'Dr Oetker Salami',
  );
  await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
  await tester.pump();
  await tester.pumpAndSettle();
  await chooseMealSlot(tester, slotKey);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
  await tester.pumpAndSettle();
  final addButton = find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
  await tester.ensureVisible(addButton);
  await tester.tap(addButton);
  await tester.pumpAndSettle();
}

class _FakeProductLookupService implements ProductLookupService {
  static final MealAnalysisResult salamiPizza =
      MealAnalysisResult.fromOpenFoodFacts(
    const <String, dynamic>{
      'code': '4001724012345',
      'product_name': 'Die Ofenfrische Salami',
      'brands': 'Dr. Oetker',
      'quantity': '390 g',
      'serving_quantity': 100,
      'nutriments': <String, dynamic>{
        'energy-kcal_100g': 252,
        'proteins_100g': 10,
        'carbohydrates_100g': 31,
        'fat_100g': 9,
      },
    },
    '4001724012345',
  );

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return <ProductSearchResult>[
      ProductSearchResult(
        code: '4001724012345',
        title: 'Die Ofenfrische Salami · Dr. Oetker',
        kcalPer100G: 252,
        result: salamiPizza,
      ),
    ];
  }
}
