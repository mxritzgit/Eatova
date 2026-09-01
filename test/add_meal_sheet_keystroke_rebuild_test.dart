// B3 (perf audit 2026-09-01): the add-meal sheet rebuilt its ENTIRE subtree on
// every search keystroke. `_scheduleProductSearch` ran a bare `setState(() {})`
// "so _searchActive flips" — but that getter flips on ONE character in a word,
// so every other key repainted an identical frame (favorites tiles, existing
// meals, slot picker, header, all of it).
//
// These tests measure the SHEET BUILD, not the wording: the slot-picker Padding
// is created by `_AddMealSheetState.build` and by nothing else, so a new widget
// instance behind its key means the whole sheet was rebuilt. The flip itself is
// pinned in both directions — the short-input path resets seven fields and must
// not swallow the switch back to favorites when there was nothing to reset.
//
// A4 (review 2026-09-01): the short circuit is
// `!_renderedSearchActive && !_searchStateDirty`, and its two halves are not
// equal partners. Six of the seven fields `_searchStateDirty` ORs can only be
// written while the results zone is on screen (`_searchProducts` past its
// min-chars branch, `_armSlowHint`, `_cancelProductSearch` — all of them need
// >= _searchMinChars), and every way back below the threshold runs through
// this same reset with `_renderedSearchActive == true`. So for those six the
// FIRST half already decides and dropping them changes nothing observable —
// verified by mutation: with `_searchStateDirty` reduced to the one term
// below, all 127 cases across the 21 suites that mount this sheet stay green.
//
// The one exception is `_productSearchMessage`: the magnifier on a too-short
// field files the min-chars hint WHILE the favorites zone stands, so it is the
// only term that can be true with `_renderedSearchActive == false`. That case
// gets its own test below, as does the revocation of the magnifier unlock —
// the consequence the term would have had if the reset ever stopped clearing
// `_explicitSearchRequested`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
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

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _StubProduktdienst implements ProductLookupService {
  _StubProduktdienst(this.treffer);

  final List<ProductSearchResult> treffer;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      treffer;
}

MealAnalysisResult _mahlzeit(String name) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: 240,
  estimatedGrams: 100,
  kcalPer100G: 240,
  protein: '-',
  carbs: '-',
  fat: '-',
  confidence: 'Datenbank',
  portionNotes: '',
);

final MealAnalysisResult _skyr = _mahlzeit('Skyr');

final List<FavoriteMeal> _einFavorit = <FavoriteMeal>[
  FavoriteMeal(
    id: FavoriteMeal.idFor(_skyr),
    result: _skyr,
    addedAt: DateTime(2026, 8, 20),
    pinned: true,
  ),
];

final List<ProductSearchResult> _einTreffer = <ProductSearchResult>[
  ProductSearchResult(
    code: '4000000000001',
    title: 'Eiweissbrot · Testmarke',
    subtitle: 'Testmarke · 240 kcal / 100 g',
    kcalPer100G: 240,
    result: _mahlzeit('Eiweissbrot'),
  ),
];

Finder _sucheingabe() =>
    find.byKey(const ValueKey('kcal-product-search-input'));

/// Only rendered while `_searchActive` is false — the favorites zone marker.
Finder _manuellZeile() => find.byKey(const ValueKey('manual-entry-button'));

Finder _inlineFavorit() => find.byKey(const ValueKey('favorite-pinned-0'));

/// The sheet's build fingerprint (see the file header).
Widget _rahmen(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('add-meal-slot-select')));

/// Counts sheet builds by widget identity.
class _Neubauten {
  _Neubauten(WidgetTester tester) : _letzter = _rahmen(tester);

  Widget _letzter;
  int anzahl = 0;

  void pruefe(WidgetTester tester) {
    final jetzt = _rahmen(tester);
    if (identical(jetzt, _letzter)) return;
    _letzter = jetzt;
    anzahl++;
  }
}

Future<BuildContext> _pumpe(
  WidgetTester tester,
  ProductLookupService dienst,
) async {
  pinPhoneViewport(tester);
  return pumpLocalizedContext(
    tester,
    AddMealSheet(
      slot: MealSlot.snack,
      analyzer: _StummerAnalyzer(),
      productService: dienst,
      photoInput: _StummeFotoquelle(),
      favorites: _einFavorit,
      onAdd: (_, __) => 'id-1',
      onUpdateMeal: (_, __) {},
      onRemoveFavorite: (_) {},
    ),
    // Motion stays on: with duration 0 the sheet's AnimatedSize re-dirties
    // itself inside its own performLayout.
    reducedMotion: false,
    safeArea: false,
    settle: true,
  );
}

/// One keystroke: `enterText` fires `onChanged` exactly once, like the field.
Future<void> _tippe(
  WidgetTester tester,
  String text,
  _Neubauten zaehler,
) async {
  await tester.enterText(_sucheingabe(), text);
  await tester.pump();
  zaehler.pruefe(tester);
}

void main() {
  testWidgets('Zeichen ohne Zonenwechsel bauen das Sheet nicht neu', (
    tester,
  ) async {
    await _pumpe(tester, _StubProduktdienst(_einTreffer));
    final zaehler = _Neubauten(tester);

    // Unterhalb der Auto-Schwelle steht die Favoritenzone bereits und es gibt
    // keinen Suchzustand zu leeren.
    await _tippe(tester, 'E', zaehler);
    await _tippe(tester, 'Ei', zaehler);
    expect(
      zaehler.anzahl,
      0,
      reason: 'zwei Tastendrücke, die nichts auf dem Schirm ändern',
    );
    expect(_manuellZeile(), findsOneWidget);

    // Das dritte Zeichen kippt die Zone — genau hier gehört der Neubau hin.
    await _tippe(tester, 'Eiw', zaehler);
    expect(zaehler.anzahl, 1, reason: 'Favoriten -> Ergebniszone');
    expect(_manuellZeile(), findsNothing);
    expect(_inlineFavorit(), findsNothing);

    // Jedes weitere Zeichen lässt die Zone stehen.
    await _tippe(tester, 'Eiwe', zaehler);
    await _tippe(tester, 'Eiweis', zaehler);
    await _tippe(tester, 'Eiweiss', zaehler);
    expect(
      zaehler.anzahl,
      1,
      reason: 'drei weitere Zeichen, kein einziger Neubau mehr',
    );

    // Debounce auslösen, damit kein Timer offen bleibt.
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('kcal-product-suggestion-0')),
      findsOneWidget,
      reason: 'die Suche selbst läuft unverändert weiter',
    );
  });

  testWidgets('zurück unter die Schwelle holt die Favoriten zurück', (
    tester,
  ) async {
    await _pumpe(tester, _StubProduktdienst(_einTreffer));
    final zaehler = _Neubauten(tester);

    // Der Debounce hat noch nichts gesetzt: kein Spinner, keine Treffer,
    // keine Meldung — es gibt also nichts zu leeren.
    await _tippe(tester, 'Eiw', zaehler);
    expect(zaehler.anzahl, 1);
    expect(_manuellZeile(), findsNothing);

    await _tippe(tester, 'Ei', zaehler);
    expect(
      zaehler.anzahl,
      2,
      reason:
          'die Rücknahme ist ein echter Zonenwechsel — der Kurzschluss '
          'darf sie nicht verschlucken, nur weil kein Suchzustand anlag',
    );
    expect(_manuellZeile(), findsOneWidget);
    expect(_inlineFavorit(), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('unter die Schwelle räumt eine stehende Suchmeldung weg', (
    tester,
  ) async {
    final l10n = (await _pumpe(
      tester,
      _StubProduktdienst(const <ProductSearchResult>[]),
    )).l10n;
    final zaehler = _Neubauten(tester);

    await _tippe(tester, 'Eiweiss', zaehler);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    expect(find.text(l10n.foodSearchNoResultsHint), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-entry-cta')), findsOneWidget);

    zaehler.pruefe(tester);
    final vorher = zaehler.anzahl;
    await _tippe(tester, 'Ei', zaehler);
    expect(
      zaehler.anzahl,
      vorher + 1,
      reason: 'sieben Felder werden zurückgesetzt, das muss gemalt werden',
    );
    expect(find.text(l10n.foodSearchNoResultsHint), findsNothing);
    expect(_manuellZeile(), findsOneWidget);

    // Zweiter Tastendruck unter der Schwelle: jetzt ist alles schon leer.
    await _tippe(tester, 'E', zaehler);
    expect(
      zaehler.anzahl,
      vorher + 1,
      reason: 'nichts mehr zu leeren, Zone unverändert -> kein Neubau',
    );

    await tester.pumpAndSettle();
  });

  // A4 (Review 2026-09-01): `_searchStateDirty` ODERt sieben Felder, aber nur
  // EINES davon kann wahr sein, WÄHREND die Favoritenzone steht — und nur dann
  // entscheidet der Term überhaupt etwas. Die Lupe auf einem zu kurzen Feld
  // legt `_productSearchMessage` ab, ohne die Zone zu öffnen: der Hinweis ist
  // in diesem Moment unsichtbar und würde beim nächsten Zonenwechsel über
  // einem ganz anderen Begriff auftauchen.
  testWidgets('ein unsichtbar abgelegter Suchhinweis wird trotzdem geräumt', (
    tester,
  ) async {
    final l10n = (await _pumpe(tester, _StubProduktdienst(_einTreffer))).l10n;

    // Lupe auf dem leeren Feld: unter _searchMinChars antwortet die Suche mit
    // dem Mindestzeichen-Hinweis — die Zone bleibt aber die Favoritenzone.
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pump();
    expect(
      _manuellZeile(),
      findsOneWidget,
      reason: 'Zone bleibt bei den Favoriten',
    );
    expect(
      find.text(l10n.foodSearchMinCharsHint),
      findsNothing,
      reason: 'der Hinweis liegt an, gemalt wird er nicht',
    );

    final zaehler = _Neubauten(tester);
    // Zwei Zeichen: die Zone ändert sich nicht, der Kurzschluss darf hier
    // trotzdem nicht greifen — es liegt Suchzustand an, der weg muss.
    await _tippe(tester, 'Ei', zaehler);
    expect(
      zaehler.anzahl,
      1,
      reason: 'der stehende Hinweis ist der Grund für diesen einen Neubau',
    );

    // Der Beweis am Bildschirm: das dritte Zeichen öffnet die Ergebniszone.
    // Wäre der Hinweis liegengeblieben, stünde jetzt "Mindestens 2 Zeichen"
    // über einer Suche mit dreien.
    await _tippe(tester, 'Eiw', zaehler);
    expect(
      find.text(l10n.foodSearchMinCharsHint),
      findsNothing,
      reason: 'kein Hinweis aus einem anderen Begriff in der frischen Zone',
    );

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('kcal-product-suggestion-0')),
      findsOneWidget,
      reason: 'die Suche selbst läuft unverändert weiter',
    );
  });

  // Die Gegenrichtung desselben Kurzschlusses: die Lupe schaltet die
  // Ergebniszone für ein Fragment unter _autoSearchMinChars frei, und genau
  // diese Freischaltung gehört zum ALTEN Begriff. Bleibt sie stehen, zeigt das
  // Sheet bei zwei Zeichen eine leere Ergebniszone statt der Favoriten.
  testWidgets('die Lupen-Freischaltung endet mit dem nächsten Zeichen', (
    tester,
  ) async {
    await _pumpe(tester, _StubProduktdienst(_einTreffer));
    final zaehler = _Neubauten(tester);

    await _tippe(tester, 'Ei', zaehler);
    expect(
      _manuellZeile(),
      findsOneWidget,
      reason: 'zwei Zeichen suchen nicht von allein',
    );

    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('kcal-product-suggestion-0')),
      findsOneWidget,
      reason: 'die Lupe schaltet die Zone auch für zwei Zeichen frei',
    );

    // Zurück unter _searchMinChars.
    await _tippe(tester, 'E', zaehler);
    expect(_manuellZeile(), findsOneWidget);

    // Wieder zwei Zeichen, diesmal ohne Lupe: der Widerruf muss halten.
    await _tippe(tester, 'Ei', zaehler);
    expect(
      _manuellZeile(),
      findsOneWidget,
      reason: 'kein stehengebliebenes Ergebnisfenster',
    );

    // Und er muss einen FREMDEN Neubau überleben: ohne den bliebe eine
    // stehengebliebene Freischaltung nur ungemalt liegen (Zone stumm), bis
    // irgendein anderes setState sie aufdeckt — hier der Slotwechsel.
    await tester.tap(find.byKey(const ValueKey('slot-select-lunch')));
    await tester.pumpAndSettle();
    expect(
      _manuellZeile(),
      findsOneWidget,
      reason: 'auch nach einem fremden Neubau steht die Favoritenzone',
    );
    expect(_inlineFavorit(), findsOneWidget);
  });
}
