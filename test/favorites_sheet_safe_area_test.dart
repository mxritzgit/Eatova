// Safe-area and keyboard geometry of the favorites sheet (feature
// 2026-08-27), after add_meal_sheet_safe_area_test: opened through the REAL
// route (showFavoritesSheet -> showEatovaSheet), so the modal builder's zeroed
// `viewPadding.top` is in play and the cap must come from `View.of` (see
// sheetMaxHeightOf). Overflows are COLLECTED, not swallowed. The bundled
// fonts are loaded: the test fallback font is about twice as wide and would
// wrap the subtitle into a header no real device produces.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/design/sheets.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';

import 'support/harness.dart';

const double _hoehe = 844;
const double _safeAreaOben = 59;
const double _tastatur = 336;

const _sheet = ValueKey('favorites-sheet');
const _titel = ValueKey('favorites-sheet-title');
const _suche = ValueKey('favorites-sheet-search');
const _scroll = ValueKey('favorites-sheet-scroll');

MealAnalysisResult _mahlzeit(int i) => MealAnalysisResult(
      mealName: 'Favorit $i',
      caloriesKcal: 100 + i,
      estimatedGrams: 100,
      kcalPer100G: (100 + i).toDouble(),
      protein: '-',
      carbs: '-',
      fat: '-',
      confidence: 'database',
      portionNotes: '',
    );

/// Enough pinned rows to blow past any cap; only then does the cap decide
/// where the head lands. Distinct dates: index 29 is newest (top), 0 oldest.
final List<FavoriteMeal> _dreissig = List<FavoriteMeal>.generate(
  30,
  (i) => FavoriteMeal(
    id: 'fav-$i',
    addedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
    result: _mahlzeit(i),
    pinned: true,
  ),
);

Future<void> _ladeFonts() async {
  final archivo = FontLoader('Archivo');
  for (final datei in const <String>[
    'assets/fonts/Archivo-Regular.ttf',
    'assets/fonts/Archivo-Medium.ttf',
    'assets/fonts/Archivo-SemiBold.ttf',
    'assets/fonts/Archivo-Bold.ttf',
  ]) {
    archivo.addFont(
      File(datei).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  }
  final bricolage = FontLoader('BricolageGrotesque');
  for (final datei in const <String>[
    'assets/fonts/BricolageGrotesque-Bold.ttf',
    'assets/fonts/BricolageGrotesque-ExtraBold.ttf',
  ]) {
    bricolage.addFont(
      File(datei).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  }
  await Future.wait(<Future<void>>[archivo.load(), bricolage.load()]);
}

/// Opens the sheet through the real route and returns the errors reported.
Future<List<Object>> _oeffneSheet(
  WidgetTester tester, {
  double textScale = 1.0,
}) async {
  final fehler = <Object>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    fehler.add(details.exception);
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  // The harness puts the scaling above the Navigator, so it reaches the route.
  // No SafeArea: the sheet computes its own cap from the device insets.
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showFavoritesSheet(
            context,
            favorites: _dreissig,
            slot: MealSlot.dinner,
            onAdd: (_, __) => 'id-1',
            onUnpin: (_) {},
          ),
          child: const Text('oeffnen'),
        ),
      ),
    ),
    reducedMotion: false,
    textScale: textScale,
    safeArea: false,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('oeffnen'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return fehler;
}

/// Proves the cap really bites: the scroll area still has travel left, so the
/// content is taller than the sheet shows.
void _erwarteGedeckelt(WidgetTester tester) {
  final rest = tester
      .state<ScrollableState>(
        find.descendant(of: find.byKey(_scroll), matching: find.byType(Scrollable)),
      )
      .position
      .maxScrollExtent;
  expect(rest, greaterThan(0),
      reason: 'Der Testinhalt muss den Deckel reissen, sonst misst der Test '
          'nur die Inhaltshoehe und nicht den Deckel.');
}

/// Head row (title, search) sits below the Dynamic Island.
void _erwarteKopfUnterSafeArea(WidgetTester tester) {
  expect(tester.getRect(find.byKey(_titel)).top,
      greaterThanOrEqualTo(_safeAreaOben));
  expect(tester.getRect(find.byKey(_suche)).top,
      greaterThanOrEqualTo(_safeAreaOben));
}

void main() {
  setUpAll(_ladeFonts);

  testWidgets(
      'mit offener Tastatur bleibt der Kopf unter der Dynamic Island und '
      'das Sheet über der Tastatur', (tester) async {
    pinIphone14Pro(tester, keyboard: true);
    final fehler = await _oeffneSheet(tester);
    expect(fehler, isEmpty);
    _erwarteGedeckelt(tester);

    // The route places the sheet at the earliest 12 pt below the safe area …
    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.top, greaterThanOrEqualTo(_safeAreaOben + kSheetTopGap));

    // … and showEatovaSheet trims the inside to the cap minus the handle pad.
    // (The BottomSheet itself reaches the screen bottom: the keyboard padding
    // sits inside it, so only the content is measured against the keyboard.)
    const deckel = _hoehe - _safeAreaOben - _tastatur - kSheetTopGap;
    final inhalt = tester.getRect(find.byKey(_sheet));
    expect(inhalt.height, lessThanOrEqualTo(deckel - kMinInteractiveDimension));
    expect(
      inhalt.top,
      greaterThanOrEqualTo(
        _safeAreaOben + kSheetTopGap + kMinInteractiveDimension,
      ),
    );
    expect(inhalt.bottom, lessThanOrEqualTo(_hoehe - _tastatur));
    _erwarteKopfUnterSafeArea(tester);
  });

  testWidgets('ohne Tastatur ragt das Sheet ebenfalls nicht in die Safe-Area',
      (tester) async {
    pinIphone14Pro(tester);
    final fehler = await _oeffneSheet(tester);
    expect(fehler, isEmpty);
    _erwarteGedeckelt(tester);

    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.top, greaterThanOrEqualTo(_safeAreaOben + kSheetTopGap));
    expect(
      sheet.height,
      lessThanOrEqualTo(_hoehe - _safeAreaOben - kSheetTopGap),
    );
    expect(
      tester.getRect(find.byKey(_sheet)).height,
      lessThanOrEqualTo(
        _hoehe - _safeAreaOben - kSheetTopGap - kMinInteractiveDimension,
      ),
    );
    _erwarteKopfUnterSafeArea(tester);
  });

  testWidgets(
      'mit Tastatur scrollt die Liste statt zu überlaufen: der älteste '
      'Favorit ist per Scroll erreichbar und liegt über der Tastatur',
      (tester) async {
    pinIphone14Pro(tester, keyboard: true);
    final fehler = await _oeffneSheet(tester);

    // Newest first, so 'Favorit 0' is the last row; below the fold at start.
    final letzter = find.text('Favorit 0');
    expect(letzter, findsOneWidget);
    final inhalt = tester.getRect(find.byKey(_sheet));
    expect(tester.getRect(letzter).top, greaterThan(inhalt.bottom),
        reason: 'ohne Deckel wäre die letzte Zeile schon sichtbar');

    await tester.ensureVisible(letzter);
    await tester.pumpAndSettle();

    final zeile = tester.getRect(letzter);
    expect(zeile.top, greaterThanOrEqualTo(inhalt.top));
    expect(zeile.bottom, lessThanOrEqualTo(inhalt.bottom));
    expect(zeile.bottom, lessThanOrEqualTo(_hoehe - _tastatur));
    expect(fehler, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bei doppelter Systemschrift läuft nichts über', (tester) async {
    pinIphone14Pro(tester);
    final fehler = await _oeffneSheet(tester, textScale: 2.0);
    expect(fehler, isEmpty,
        reason: 'RenderFlex-Ueberlauf bei textScaler 2.0: $fehler');
    _erwarteGedeckelt(tester);
    _erwarteKopfUnterSafeArea(tester);

    // The capsule has a MINIMUM height (46) and grows with the text: the
    // doubled hint must sit inside it, not hang out at the top or bottom.
    final kapsel = tester.getRect(
      find.ancestor(of: find.byKey(_suche), matching: find.byType(AnimatedContainer)).first,
    );
    final hint = tester.getRect(find.text('Favoriten durchsuchen'));
    expect(
      hint.top >= kapsel.top && hint.bottom <= kapsel.bottom,
      isTrue,
      reason: 'favorites_sheet.dart (_SearchField, minHeight: 46): der Hint '
          '$hint ragt bei textScaler 2.0 aus der Kapsel $kapsel',
    );
  });

  testWidgets(
      'bei doppelter Systemschrift UND Tastatur bleibt der Kopf sichtbar und '
      'die Liste behält Scrollweg', (tester) async {
    pinIphone14Pro(tester, keyboard: true);
    final fehler = await _oeffneSheet(tester, textScale: 2.0);
    expect(fehler, isEmpty,
        reason: 'RenderFlex-Ueberlauf bei textScaler 2.0 + Tastatur: $fehler');
    _erwarteGedeckelt(tester);
    _erwarteKopfUnterSafeArea(tester);

    final inhalt = tester.getRect(find.byKey(_sheet));
    expect(inhalt.bottom, lessThanOrEqualTo(_hoehe - _tastatur));
    // The list area did not collapse: the first row is on screen.
    final erste = tester.getRect(find.text('Favorit 29'));
    expect(erste.top, greaterThanOrEqualTo(inhalt.top));
    expect(erste.top, lessThan(inhalt.bottom),
        reason: 'der Kopf frisst bei 2.0 + Tastatur den ganzen Deckel');
  });
}
