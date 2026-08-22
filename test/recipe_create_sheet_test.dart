import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';

// D5: sheets discard filled-in forms silently.
//
// The "own recipe" sheet is the worst case: eight TextEditingControllers and
// `isDismissible`/`enableDrag` at their `true` defaults. A tap just above the
// sheet — the usual reflex to dismiss the keyboard — discarded everything.
//
// The two dismiss routes differ in the framework and are both tested:
//   * Barrier tap → ModalBarrier.handleDismiss → Navigator.maybePop — asks
//     PopScope.
//   * Drag → BottomSheet._handleDragEnd → onClosing → Navigator.pop — does
//     NOT ask PopScope.
//
// Also field validation: `user_recipes` only constrains `>= 0`, and the tighter
// `logged_meals` bounds apply on logging (FitnessRecipe.toMealResult), so a
// 50,000 kcal recipe could be created and then never used.

/// All input fields of the sheet. A ninth one turns the "sheet has exactly as
/// many fields as this list" test red, which also proves the discard guard
/// covers the new field.
const List<String> alleFeldKeys = <String>[
  'recipe-create-name',
  'recipe-create-portion',
  'recipe-create-kcal',
  'recipe-create-grams',
  'recipe-create-protein',
  'recipe-create-carbs',
  'recipe-create-fat',
  'recipe-create-ingredients',
];

/// Viewport pinning + overflow tolerance, as in edit_meal_sheet_test.dart.
void testWidgetsRobust(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}

class _CreateCapture {
  final List<FitnessRecipe> created = <FitnessRecipe>[];

  /// The hook reports what happened to the recipe; always "delivered" here.
  /// This suite tests the discard guard and field validation, not the sync
  /// feedback (see recipes_save_feedback_test.dart).
  Future<SyncDelivery> add(FitnessRecipe recipe) async {
    created.add(recipe);
    return SyncDelivery.delivered;
  }
}

Future<void> _openSheet(WidgetTester tester, _CreateCapture capture) async {
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
        body: RecipesScreen(
          onAddMeal: (MealAnalysisResult _, MealSlot __) {},
          onCreateRecipe: capture.add,
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
}

/// Types text into a field.
///
/// The `pumpAndSettle` is mandatory: `WidgetTester.enterText` sets focus first
/// and then sends the text to the currently connected text input. Without the
/// frame in between, the second entry hits the previous field's connection and
/// is lost.
Future<void> _tippe(WidgetTester tester, String feldKey, String text) async {
  await tester.enterText(find.byKey(ValueKey(feldKey)), text);
  await tester.pumpAndSettle();
}

/// Current content of a field — more robust than `find.text` for multiline
/// text.
String _inhalt(WidgetTester tester, String feldKey) =>
    tester.widget<TextField>(find.byKey(ValueKey(feldKey))).controller!.text;

/// A tap at the top left hits the barrier, not the sheet.
Future<void> _tapBarrier(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

Future<void> _dragSheetDown(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const ValueKey('recipe-create-sheet')),
    const Offset(0, 600),
  );
  await tester.pumpAndSettle();
}

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const ValueKey('recipe-create-save')));

void main() {
  group('D5 — Verwerfen-Schutz', () {
    testWidgetsRobust(
        'Barriere-Tap bei ausgefuelltem Formular fragt nach, statt zu verwerfen',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');

      await _tapBarrier(tester);

      expect(
          find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
      expect(capture.created, isEmpty);
    });

    testWidgetsRobust(
        'Sheet nach unten ziehen bei ausgefuelltem Formular fragt nach',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');

      await _dragSheetDown(tester);

      expect(
          find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
      expect(capture.created, isEmpty);
    });

    testWidgetsRobust(
        '„Weiter bearbeiten" laesst das Sheet mitsamt Eingaben offen',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');
      await _tippe(tester, 'recipe-create-ingredients', '200 g Skyr\n50 g Haferflocken');
      await tester.pumpAndSettle();

      await _tapBarrier(tester);
      await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
      // The entries are still there.
      expect(_inhalt(tester, 'recipe-create-name'), 'Protein-Bowl');
      expect(
        _inhalt(tester, 'recipe-create-ingredients'),
        '200 g Skyr\n50 g Haferflocken',
      );
    });

    testWidgetsRobust('„Verwerfen" schliesst das Sheet ohne Rezept anzulegen',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');

      await _tapBarrier(tester);
      await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsNothing);
      expect(capture.created, isEmpty);
    });

    testWidgetsRobust(
        'ein Tap neben den Dialog ist „Abbrechen" — das Sheet bleibt offen',
        (tester) async {
      // Also proves the dialog sits ABOVE the sheet route: its own barrier
      // swallows the tap, the sheet below never sees it.
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');

      await _tapBarrier(tester);
      expect(
          find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);

      await _tapBarrier(tester);
      expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
      expect(_inhalt(tester, 'recipe-create-name'), 'Protein-Bowl');
    });

    testWidgetsRobust(
        'unberuehrtes Sheet: Barriere-Tap schliesst sofort, ohne Dialog',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tapBarrier(tester);

      expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsNothing);
    });

    testWidgetsRobust(
        'unberuehrtes Sheet: Ziehen schliesst sofort, ohne Dialog',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _dragSheetDown(tester);

      expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsNothing);
    });

    testWidgetsRobust(
        'auf den Ausgangswert zurueckgesetzt gilt wieder als unberuehrt',
        (tester) async {
      // _dirty compares against the initial state, not "was ever typed in".
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-portion', '2 Teller');
      await _tippe(tester, 'recipe-create-portion', '1 Portion');

      await _tapBarrier(tester);

      expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsNothing);
    });

    testWidgetsRobust('Speichern laeuft ohne Verwerfen-Dialog durch',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');
      await _tippe(tester, 'recipe-create-kcal', '520');
      await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
      expect(find.byKey(const ValueKey('recipe-create-sheet')), findsNothing);
      expect(capture.created, hasLength(1));
      expect(capture.created.single.title, 'Protein-Bowl');
      expect(capture.created.single.caloriesKcal, 520);
    });

    testWidgetsRobust(
        'das Sheet hat genau so viele Felder wie alleFeldKeys — ein neuntes '
        'Feld macht diesen Test rot', (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('recipe-create-sheet')),
          matching: find.byType(TextField),
        ),
        findsNWidgets(alleFeldKeys.length),
      );
      for (final key in alleFeldKeys) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$key fehlt');
      }
    });

    // Every single field must suffice on its own — the property a hand-kept
    // field list in the sheet loses sooner or later.
    for (final key in alleFeldKeys) {
      testWidgetsRobust('eine Aenderung nur in $key loest den Dialog aus',
          (tester) async {
        final capture = _CreateCapture();
        await _openSheet(tester, capture);

        // '7' is valid for every field and differs from the initial value —
        // including the digitsOnly fields.
        await _tippe(tester, key, '7');
        await tester.pumpAndSettle();

        await _tapBarrier(tester);

        expect(find.byKey(const ValueKey('discard-changes-dialog')),
            findsOneWidget,
            reason: '$key wird von _dirty nicht erfasst');
        expect(
            find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
      });
    }
  });

  group('Feldvalidierung — die logged_meals-Grenzen gelten schon beim Anlegen',
      () {
    /// Fills name + kcal (the required fields) with valid values.
    Future<void> fuelleGueltig(WidgetTester tester) async {
      await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');
      await _tippe(tester, 'recipe-create-kcal', '520');
      await tester.pumpAndSettle();
    }

    testWidgetsRobust('gueltige Eingaben schalten Speichern frei',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);
      expect(_saveButton(tester).onPressed, isNull);

      await fuelleGueltig(tester);
      expect(_saveButton(tester).onPressed, isNotNull);
    });

    // Bounds and error texts derive from LoggedMealLimits. The sheet mirrors
    // them as local constants because it is a `part` without its own imports;
    // if the two drift apart, something here turns red.
    const kcalMax = LoggedMealLimits.caloriesKcalMax;
    const gramsMax = LoggedMealLimits.estimatedGMax;
    final macroMax = LoggedMealLimits.macroGMax.toInt();

    testWidgetsRobust(
        'ueber $kcalMax kcal wird abgelehnt statt geklemmt — sonst laesst sich '
        'das Rezept anlegen, aber nie loggen', (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);
      await fuelleGueltig(tester);

      await _tippe(tester, 'recipe-create-kcal', '50000');
      await tester.pumpAndSettle();

      expect(isValidMealCaloriesKcal(50000), isFalse);
      expect(_saveButton(tester).onPressed, isNull);
      expect(find.text('1–$kcalMax kcal'), findsOneWidget);
      expect(capture.created, isEmpty);
    });

    testWidgetsRobust('genau $kcalMax kcal ist noch erlaubt (Grenze inklusiv)',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);
      await fuelleGueltig(tester);

      await _tippe(tester, 'recipe-create-kcal', '$kcalMax');
      await tester.pumpAndSettle();
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(find.text('1–$kcalMax kcal'), findsNothing);

      // Exactly one above flips it.
      await _tippe(tester, 'recipe-create-kcal', '${kcalMax + 1}');
      await tester.pumpAndSettle();
      expect(_saveButton(tester).onPressed, isNull);
    });

    testWidgetsRobust('0 Gramm wird abgelehnt (Division in adjustedToGrams)',
        (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);
      await fuelleGueltig(tester);

      await _tippe(tester, 'recipe-create-grams', '0');
      await tester.pumpAndSettle();

      expect(isPlausiblePortionGrams(0), isFalse);
      expect(_saveButton(tester).onPressed, isNull);
      expect(find.text('1–$gramsMax g'), findsOneWidget);
    });

    testWidgetsRobust('ueber $gramsMax g wird abgelehnt', (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);
      await fuelleGueltig(tester);

      await _tippe(tester, 'recipe-create-grams', '${gramsMax + 1}');
      await tester.pumpAndSettle();

      expect(_saveButton(tester).onPressed, isNull);
      expect(find.text('1–$gramsMax g'), findsOneWidget);
    });

    testWidgetsRobust('ueber $macroMax g Makro wird abgelehnt', (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);
      await fuelleGueltig(tester);

      for (final key in const <String>[
        'recipe-create-protein',
        'recipe-create-carbs',
        'recipe-create-fat',
      ]) {
        await _tippe(tester, key, '${macroMax + 1}');
        await tester.pumpAndSettle();
        expect(_saveButton(tester).onPressed, isNull, reason: key);
        expect(find.text('0–$macroMax g'), findsOneWidget, reason: key);

        // Empty means "not stated" and is allowed.
        await _tippe(tester, key, '');
        await tester.pumpAndSettle();
        expect(_saveButton(tester).onPressed, isNotNull, reason: key);
      }
    });

    testWidgetsRobust('ein zu langer Name wird gekuerzt, nicht abgelehnt',
        (tester) async {
      // Texts are truncated, numbers are rejected.
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-name', 'A' * 400);
      await _tippe(tester, 'recipe-create-kcal', '520');
      await tester.pumpAndSettle();

      expect(_saveButton(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
      await tester.pumpAndSettle();

      expect(capture.created, hasLength(1));
      expect(
        charLength(capture.created.single.title),
        LoggedMealLimits.mealNameMaxChars,
      );
    });

    testWidgetsRobust(
        'was sich anlegen laesst, laesst sich auch loggen — toMealResult '
        'haelt jede logged_meals-Grenze ein', (tester) async {
      final capture = _CreateCapture();
      await _openSheet(tester, capture);

      await _tippe(tester, 'recipe-create-name', 'Grenzwert-Teller');
      await _tippe(tester, 'recipe-create-kcal', '${LoggedMealLimits.caloriesKcalMax}');
      await _tippe(tester, 'recipe-create-grams', '${LoggedMealLimits.estimatedGMax}');
      for (final key in const <String>[
        'recipe-create-protein',
        'recipe-create-carbs',
        'recipe-create-fat',
      ]) {
        await _tippe(tester, key, '${LoggedMealLimits.macroGMax.toInt()}');
      }
      await tester.pumpAndSettle();
      expect(_saveButton(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
      await tester.pumpAndSettle();

      final rezept = capture.created.single;
      final meal = rezept.toMealResult();
      expect(isValidMealName(meal.mealName), isTrue);
      expect(isValidMealCaloriesKcal(meal.caloriesKcal), isTrue);
      expect(isValidMealEstimatedG(meal.estimatedGrams), isTrue);
      expect(isPlausiblePortionGrams(meal.estimatedGrams), isTrue);
      expect(isValidMealMacroG(rezept.proteinG), isTrue);
      expect(isValidMealMacroG(rezept.carbsG), isTrue);
      expect(isValidMealMacroG(rezept.fatG), isTrue);
    });
  });
}
