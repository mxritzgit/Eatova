// Widget tests for the favorites sheet (feature 2026-08-27): pinned-only
// list by recency, local search, empty states, add with pass-through slot,
// unpin via heart, and the 0-kcal guard.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';

MealAnalysisResult _mahlzeit(
  String name, {
  int kcal = 250,
  int gramm = 100,
  String? marke,
  bool explizitNull = false,
}) {
  return MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: gramm,
    kcalPer100G: gramm == 0 ? 0 : kcal * 100 / gramm,
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'database',
    portionNotes: '',
    brand: marke,
    explicitZeroKcal: explizitNull,
  );
}

FavoriteMeal _favorit(
  MealAnalysisResult result, {
  required DateTime am,
  bool gepinnt = true,
}) {
  return FavoriteMeal(
    id: FavoriteMeal.idFor(result),
    result: result,
    addedAt: am,
    pinned: gepinnt,
  );
}

Widget _app(Widget sheet, {Brightness helligkeit = Brightness.dark}) {
  return MaterialApp(
    theme: buildEatovaTheme(helligkeit),
    locale: const Locale('de'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(body: sheet),
  );
}

void _telefon(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

String _titel(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('favorites-sheet-title')))
        .data!;

Finder _zeile(int index) => find.byKey(ValueKey('favorites-sheet-item-$index'));

Finder _textInZeile(int index, String text) =>
    find.descendant(of: _zeile(index), matching: find.text(text));

/// Lets the just-added check (2 s) and the snack timers expire so no timer
/// is pending at teardown.
Future<void> _timerAblaufen(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 4));

void main() {
  final haferdrink = _mahlzeit('Haferdrink', marke: 'Alpro');
  final skyr = _mahlzeit('Skyr', kcal: 90, gramm: 150);
  final apfel = _mahlzeit('Apfel', kcal: 52);

  testWidgets('zeigt nur gepinnte Favoriten, neueste zuerst, Zähler im Titel',
      (tester) async {
    _telefon(tester);
    await tester.pumpWidget(_app(FavoritesSheet(
      favorites: [
        _favorit(apfel, am: DateTime(2026, 8, 1)),
        _favorit(_mahlzeit('Pizza'), am: DateTime(2026, 8, 26), gepinnt: false),
        _favorit(haferdrink, am: DateTime(2026, 8, 20)),
        _favorit(skyr, am: DateTime(2026, 8, 10)),
      ],
      slot: MealSlot.snack,
      onAdd: (_, __) => 'id',
      onUnpin: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('favorites-sheet')), findsOneWidget);
    expect(_titel(tester), 'Favoriten (3)');
    expect(_textInZeile(0, 'Haferdrink'), findsOneWidget);
    expect(_textInZeile(1, 'Skyr'), findsOneWidget);
    expect(_textInZeile(2, 'Apfel'), findsOneWidget);
    expect(_zeile(3), findsNothing);
    expect(find.text('Pizza'), findsNothing,
        reason: 'Auto-Recents gehören nicht ins Favoriten-Sheet');
    expect(find.byKey(const ValueKey('favorites-sheet-search')), findsOneWidget);
  });

  testWidgets('Suchfeld filtert lokal nach Name und Marke, sonst Kein-Treffer',
      (tester) async {
    _telefon(tester);
    await tester.pumpWidget(_app(FavoritesSheet(
      favorites: [
        _favorit(haferdrink, am: DateTime(2026, 8, 20)),
        _favorit(skyr, am: DateTime(2026, 8, 10)),
      ],
      slot: MealSlot.snack,
      onAdd: (_, __) => 'id',
      onUnpin: (_) {},
    )));
    await tester.pumpAndSettle();

    final suche = find.byKey(const ValueKey('favorites-sheet-search'));
    await tester.enterText(suche, 'alpro');
    await tester.pumpAndSettle();
    expect(_textInZeile(0, 'Haferdrink'), findsOneWidget);
    expect(find.text('Skyr'), findsNothing);
    expect(_titel(tester), 'Favoriten (2)',
        reason: 'der Zähler zählt gepinnte, nicht Treffer');

    await tester.enterText(suche, 'xyz');
    await tester.pumpAndSettle();
    expect(_zeile(0), findsNothing);
    expect(find.byKey(const ValueKey('favorites-sheet-no-match')),
        findsOneWidget);
    expect(find.text('Kein Favorit passt zu deiner Suche.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('favorites-sheet-search-clear')));
    await tester.pumpAndSettle();
    expect(_zeile(1), findsOneWidget);
    expect(find.byKey(const ValueKey('favorites-sheet-no-match')), findsNothing);
  });

  testWidgets('ohne gepinnte Favoriten erscheint der Leer-Hinweis',
      (tester) async {
    _telefon(tester);
    await tester.pumpWidget(_app(FavoritesSheet(
      favorites: [
        _favorit(_mahlzeit('Pizza'), am: DateTime(2026, 8, 26), gepinnt: false),
      ],
      slot: MealSlot.lunch,
      onAdd: (_, __) => 'id',
      onUnpin: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(_titel(tester), 'Favoriten (0)');
    expect(find.byKey(const ValueKey('favorites-sheet-empty')), findsOneWidget);
    expect(find.textContaining('Noch keine Favoriten'), findsOneWidget);
    expect(_zeile(0), findsNothing);
    expect(find.byKey(const ValueKey('favorites-sheet-search')), findsNothing,
        reason: 'ohne Einträge gibt es nichts zu filtern');
  });

  testWidgets(
      'Antippen klappt auf, Hinzufügen ruft onAdd mit Result und Slot, '
      'Zeile zeigt justAdded', (tester) async {
    _telefon(tester);
    final geloggt = <(MealAnalysisResult, MealSlot)>[];
    await tester.pumpWidget(_app(FavoritesSheet(
      favorites: [
        _favorit(haferdrink, am: DateTime(2026, 8, 20)),
        _favorit(skyr, am: DateTime(2026, 8, 10)),
      ],
      slot: MealSlot.dinner,
      onAdd: (result, slot) {
        geloggt.add((result, slot));
        return 'meal-1';
      },
      onUnpin: (_) {},
    )));
    await tester.pumpAndSettle();

    final hinzufuegen = find.byKey(const ValueKey('favorites-sheet-add-1'));
    expect(hinzufuegen, findsNothing, reason: 'zugeklappt kein Button');

    await tester.tap(_zeile(1));
    await tester.pumpAndSettle();
    expect(hinzufuegen, findsOneWidget);

    await tester.ensureVisible(hinzufuegen);
    await tester.tap(hinzufuegen);
    await tester.pump();

    expect(geloggt, hasLength(1));
    expect(geloggt.single.$1.mealName, 'Skyr');
    expect(geloggt.single.$1.caloriesKcal, 90);
    expect(geloggt.single.$2, MealSlot.dinner,
        reason: 'der Slot des Add-Sheets wird durchgereicht');
    expect(
      find.descendant(
        of: _zeile(1),
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    expect(hinzufuegen, findsNothing, reason: 'nach dem Loggen zugeklappt');
    expect(find.textContaining('hinzugefügt'), findsOneWidget);

    await _timerAblaufen(tester);
    expect(
      find.descendant(
        of: _zeile(1),
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsNothing,
      reason: 'der Haken verblasst wieder',
    );
  });

  testWidgets('Herz ruft onUnpin, Zeile verschwindet, Zähler sinkt',
      (tester) async {
    _telefon(tester);
    final entpinnt = <MealAnalysisResult>[];
    await tester.pumpWidget(_app(FavoritesSheet(
      favorites: [
        _favorit(haferdrink, am: DateTime(2026, 8, 20)),
        _favorit(skyr, am: DateTime(2026, 8, 10)),
      ],
      slot: MealSlot.snack,
      onAdd: (_, __) => 'id',
      onUnpin: entpinnt.add,
    )));
    await tester.pumpAndSettle();
    expect(_titel(tester), 'Favoriten (2)');

    await tester.tap(find.byKey(const ValueKey('favorites-sheet-fav-0')));
    await tester.pump();

    expect(entpinnt, hasLength(1));
    expect(entpinnt.single.mealName, 'Haferdrink');
    expect(find.text('Favorit entfernt'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    expect(_titel(tester), 'Favoriten (1)');
    expect(find.text('Haferdrink'), findsNothing);
    expect(_textInZeile(0, 'Skyr'), findsOneWidget);
    expect(_zeile(1), findsNothing);

    // The toast lives INSIDE the sheet (F3-02) in a strip the host reserves
    // below the content — the last row's heart stays tappable meanwhile.
    expect(find.text('Favorit entfernt'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-fav-0')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_titel(tester), 'Favoriten (0)');
    expect(find.byKey(const ValueKey('favorites-sheet-empty')), findsOneWidget);

    await _timerAblaufen(tester);
  });

  testWidgets('0-kcal-Zeile ohne explicitZeroKcal ruft onAdd nicht auf',
      (tester) async {
    _telefon(tester);
    final geloggt = <MealAnalysisResult>[];
    await tester.pumpWidget(_app(FavoritesSheet(
      favorites: [
        _favorit(_mahlzeit('Proteinriegel', kcal: 0, gramm: 60),
            am: DateTime(2026, 8, 1)),
      ],
      slot: MealSlot.snack,
      onAdd: (result, _) {
        geloggt.add(result);
        return 'id';
      },
      onUnpin: (_) {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(_zeile(0));
    await tester.pumpAndSettle();
    final hinzufuegen = find.byKey(const ValueKey('favorites-sheet-add-0'));
    await tester.ensureVisible(hinzufuegen);
    await tester.tap(hinzufuegen);
    await tester.pump();

    expect(geloggt, isEmpty, reason: '0 kcal dürfen nicht geloggt werden');
    expect(find.textContaining('Kalorienangabe'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);

    await _timerAblaufen(tester);
  });

  testWidgets('gemessene 0 kcal (explicitZeroKcal) lassen sich loggen',
      (tester) async {
    _telefon(tester);
    final geloggt = <MealAnalysisResult>[];
    await tester.pumpWidget(_app(FavoritesSheet(
      favorites: [
        _favorit(_mahlzeit('Wasser', kcal: 0, gramm: 250, explizitNull: true),
            am: DateTime(2026, 8, 1)),
      ],
      slot: MealSlot.snack,
      onAdd: (result, _) {
        geloggt.add(result);
        return 'id';
      },
      onUnpin: (_) {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(_zeile(0));
    await tester.pumpAndSettle();
    final hinzufuegen = find.byKey(const ValueKey('favorites-sheet-add-0'));
    await tester.ensureVisible(hinzufuegen);
    await tester.tap(hinzufuegen);
    await tester.pump();

    expect(geloggt, hasLength(1));
    expect(find.textContaining('Kalorienangabe'), findsNothing);

    await _timerAblaufen(tester);
  });

  testWidgets('rendert im Hell-Modus ohne Fehler', (tester) async {
    _telefon(tester);
    await tester.pumpWidget(_app(
      FavoritesSheet(
        favorites: [_favorit(haferdrink, am: DateTime(2026, 8, 20))],
        slot: MealSlot.breakfast,
        onAdd: (_, __) => 'id',
        onUnpin: (_) {},
      ),
      helligkeit: Brightness.light,
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_textInZeile(0, 'Haferdrink'), findsOneWidget);
  });
}
