// Fix-Lauf 2026-08-27, Paket I (F6-05): Client-Grenzen des Anlege-Sheets.
//
//   * Titel: `maxLength` zählt GRAPHEME, `user_recipes.title` aber
//     `char_length` = Codepunkte (≤ 300). 160 ZWJ-Familien-Emoji sind 160
//     Grapheme, aber 1120 Codepunkte — vorher ein 23514 → Rezept nur lokal.
//   * Portion (200) und Zutaten (4000) haben jetzt einen Eingabe-Deckel.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// 👨‍👩‍👧‍👦 als Codepunkte: 4 Personen + 3 ZWJ = 7 Codepunkte, 1 Graphem.
final String _familie = String.fromCharCodes(const <int>[
  0x1F468,
  0x200D,
  0x1F469,
  0x200D,
  0x1F467,
  0x200D,
  0x1F466,
]);

void _pinViewport(WidgetTester tester) {
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
}

Future<List<FitnessRecipe>> _openSheet(WidgetTester tester) async {
  final created = <FitnessRecipe>[];
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
          onCreateRecipe: (recipe) async {
            created.add(recipe);
            return SyncDelivery.delivered;
          },
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
  return created;
}

Future<void> _tippe(WidgetTester tester, String feldKey, String text) async {
  await tester.enterText(find.byKey(ValueKey(feldKey)), text);
  await tester.pumpAndSettle();
}

String _inhalt(WidgetTester tester, String feldKey) =>
    tester.widget<TextField>(find.byKey(ValueKey(feldKey))).controller!.text;

FilledButton _save(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const ValueKey('recipe-create-save')));

void main() {
  testWidgets('160 ZWJ-Emoji im Titel passen durch maxLength, sind aber '
      'nicht speicherbar (char_length 300)', (tester) async {
    _pinViewport(tester);
    final created = await _openSheet(tester);

    await _tippe(tester, 'recipe-create-name', _familie * 160);
    await _tippe(tester, 'recipe-create-kcal', '520');

    final name = _inhalt(tester, 'recipe-create-name');
    expect(name.runes.length, 160 * 7,
        reason: 'Vorbedingung: das Feld hat alle 160 Grapheme behalten — '
            'maxLength zählt Grapheme, nicht Codepunkte.');
    expect(name.runes.length, greaterThan(300));

    expect(_save(tester).onPressed, isNull);
    expect(find.text('Name ist zu lang – bitte kürzen.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recipe-create-save')),
        warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(created, isEmpty);
  });

  testWidgets('42 ZWJ-Emoji (294 Codepunkte) sind noch erlaubt',
      (tester) async {
    _pinViewport(tester);
    final created = await _openSheet(tester);

    await _tippe(tester, 'recipe-create-name', _familie * 42);
    await _tippe(tester, 'recipe-create-kcal', '520');

    expect(_save(tester).onPressed, isNotNull);
    expect(find.text('Name ist zu lang – bitte kürzen.'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
    await tester.pumpAndSettle();
    expect(created, hasLength(1));
    expect(created.single.title.runes.length, 42 * 7);
  });

  testWidgets('4001 Zeichen Zutaten werden bei 4000 abgeschnitten',
      (tester) async {
    _pinViewport(tester);
    final created = await _openSheet(tester);

    await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');
    await _tippe(tester, 'recipe-create-kcal', '520');
    await _tippe(tester, 'recipe-create-ingredients', 'a' * 4001);

    expect(_inhalt(tester, 'recipe-create-ingredients').length, 4000);
    expect(_save(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
    await tester.pumpAndSettle();
    expect(created.single.ingredients.length, 4000);
  });

  testWidgets('201 Zeichen Portion werden bei 200 abgeschnitten',
      (tester) async {
    _pinViewport(tester);
    await _openSheet(tester);

    await _tippe(tester, 'recipe-create-portion', 'p' * 201);

    expect(_inhalt(tester, 'recipe-create-portion').length, 200);
  });

  testWidgets('der Name-Deckel von 160 Graphemen bleibt', (tester) async {
    _pinViewport(tester);
    await _openSheet(tester);

    await _tippe(tester, 'recipe-create-name', 'n' * 161);

    expect(_inhalt(tester, 'recipe-create-name').length, 160);
  });

  testWidgets('Speichern-Tipp im selben Frame wie eine ungültige Eingabe: '
      '_save prüft selbst noch einmal und gibt nichts heraus', (tester) async {
    _pinViewport(tester);
    final created = await _openSheet(tester);

    await _tippe(tester, 'recipe-create-name', 'Protein-Bowl');
    await _tippe(tester, 'recipe-create-kcal', '520');
    expect(_save(tester).onPressed, isNotNull);

    // Ohne pump: der Button trägt noch das `_save` des letzten Frames.
    await tester.enterText(
      find.byKey(const ValueKey('recipe-create-name')),
      _familie * 160,
    );
    await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
    await tester.pumpAndSettle();

    expect(created, isEmpty,
        reason: '_save verlässt sich nicht auf den Button-Zustand; der '
            'runes-Guard dahinter ist Defense-in-depth für denselben Fall.');
    expect(find.byKey(const ValueKey('recipe-create-sheet')), findsOneWidget);
    expect(find.text('Name ist zu lang – bitte kürzen.'), findsOneWidget);
  });
}
