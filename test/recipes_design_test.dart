// Design-Refactor 2026-08-09 — Rezepte-Paket.
//
// Diese Suite prueft NICHT das Verhalten (dafuer gibt es
// recipes_state_retention_test, diet_preference_test, recipe_create_sheet_test
// und flows/recipes_flow_test), sondern die drei Zusicherungen, die der
// Refactor selbst mitbringt:
//
//   1. Der Tab, die Detail-Ansicht und beide Sheets rendern in BEIDEN
//      Anzeige-Modi exceptionfrei — `AppTokens.of` wirft bewusst, wenn eine
//      Flaeche ohne Theme gebaut wird, und eine hart geschriebene Dunkel-Farbe
//      faellt im Hellmodus nur hier auf.
//   2. Nichts overflowt bei textScaler 2.0. Die alte Optik trug drei feste
//      Hoehen (Karussell 256, Chip-Leiste 38, Suchfeld 48); die uebrigen
//      Rezepte-Suiten schlucken Overflows bewusst (testWidgetsRobust), diese
//      hier sammelt sie ein.
//   3. Das Key-Inventar des Tabs ist vollstaendig — ein verlorener Key faellt
//      in EINEM Test auf statt verstreut ueber vier Suiten.
//
// Bewusst ohne test/widgets/design/design_harness.dart: das Paket soll nicht
// an einer fremden Helferdatei haengen.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

const _remaining = MacroProgress(
  proteinG: 90,
  carbsG: 180,
  fatG: 50,
  kcal: 1600,
);

/// Ein Eigen-Rezept ohne Bild-Asset — der einzige Fall, in dem der
/// [ImagePlaceholder] auftauchen darf.
final _eigenes = FitnessRecipe(
  slug: FitnessRecipe.userRecipeSlug(),
  title: 'Mein Testteller',
  description: 'Eigenes Rezept',
  portion: '1 Portion',
  ingredients: 'Keine Angabe',
  preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
  professionalHint: 'Selbst angelegt.',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 40,
  carbsG: 50,
  fatG: 15,
  estimatedGrams: 300,
  categories: const <String>['Eigene'],
  userCreated: true,
);

/// Der Tab in seiner echten Umgebung: die Home-Schale polstert jeden Tab mit
/// `EdgeInsets.fromLTRB(20, 12, 20, 12)` (eatova_home_page.dart). Ohne diese
/// Polsterung misst der Test eine Breite, die es in der App nicht gibt.
Widget _app(
  Brightness brightness, {
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
}) {
  return MaterialApp(
    theme: buildEatovaTheme(brightness),
    // RecipesScreen ruft seit der i18n-Migration (Paket 2) slot.label(l10n)
    // fuer den Slot-Picker (recipe_slot_picker.dart) — context.l10n.
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
            remainingMacros: _remaining,
            onCreateRecipe: (_) async => SyncDelivery.delivered,
            initialUserRecipes: userRecipes,
          ),
        ),
      ),
    ),
  );
}

void _pinViewport(WidgetTester tester, {double textScale = 1.0}) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Sammelt Overflow-Fehler waehrend [body] und meldet sie gebuendelt.
///
/// `FlutterError.onError` wird VOR dem `expect` zurueckgesetzt — das Binding
/// asserted sonst beim ersten TestFailure, solange der Handler noch haengt.
/// Muster aus test/text_scale_stress_test.dart.
Future<void> _expectNoOverflow(
  String was,
  Future<void> Function() body,
) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      final culprit =
          RegExp(r'\S+:file:///\S+').firstMatch(details.toString())?.group(0);
      overflows.add('${details.summary} (${culprit ?? 'Verursacher unbekannt'})');
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  expect(
    overflows,
    isEmpty,
    reason: '$was overflowt bei doppelter Schrift:\n${overflows.join('\n')}',
  );
}

/// Scrollt die Hauptliste, bis [finder] sichtbar ist.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.dragUntilVisible(
    finder,
    find.byKey(const ValueKey('screen-recipes')),
    const Offset(0, -250),
  );
  await tester.pumpAndSettle();
}

Finder _scrollableIn(Key key) => find
    .descendant(of: find.byKey(key), matching: find.byType(Scrollable))
    .first;

/// Faehrt einen Scroller einmal von oben nach unten ab.
///
/// Bewusst ueber die [ScrollPosition] statt per `dragUntilVisible`: bei
/// doppelter Schrift ist der Inhalt mehrere Bildschirmhoehen lang und laeuft
/// gegen dessen 50-Iterationen-Grenze. So wird ausserdem wirklich JEDE Karte
/// einmal gebaut — genau das soll der Overflow-Sammler sehen.
Future<void> _scrollThrough(WidgetTester tester, Key key) async {
  var position = tester.state<ScrollableState>(_scrollableIn(key)).position;
  while (position.pixels < position.maxScrollExtent) {
    position.jumpTo(
      (position.pixels + 700).clamp(0.0, position.maxScrollExtent),
    );
    await tester.pumpAndSettle();
    // Die lazy Liste waechst beim Scrollen — Position neu einlesen.
    position = tester.state<ScrollableState>(_scrollableIn(key)).position;
  }
}

/// Oeffnet den Slot-Picker aus der Detail-Ansicht heraus.
///
/// `ensureVisible` ist hier keine Kosmetik: bei textScaler 2.0 steht der
/// „Hinzufügen"-Knopf rund 1760 px tief, also weit unterhalb des 852 px hohen
/// Viewports. Ein blosses `tap()` traf ihn dort NICHT (nur eine Warnung, kein
/// Fehler) — der Overflow-Fall lief danach gegen ein Sheet, das nie aufging.
Future<void> _openSlotPicker(WidgetTester tester) async {
  final addButton = find.byKey(const ValueKey('recipe-add-button'));
  await tester.ensureVisible(addButton);
  await tester.pumpAndSettle();
  await tester.tap(addButton);
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('recipe-meal-picker-sheet')),
    findsOneWidget,
    reason: 'Vorbedingung: der Slot-Picker muss wirklich offen sein.',
  );
}

/// Oeffnet die Detail-Ansicht des Haehnchen-Rezepts.
Future<void> _openDetail(WidgetTester tester) async {
  final tile = find.byKey(
    const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
  );
  await _scrollTo(tester, tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  group('Beide Anzeige-Modi', () {
    for (final brightness in Brightness.values) {
      final modus = brightness == Brightness.light ? 'hell' : 'dunkel';

      testWidgets('Rezepte-Tab rendert im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
        expect(find.text('Rezepte'), findsOneWidget);
        expect(find.text('Empfehlungen'), findsOneWidget);
      });

      testWidgets('Detail-Ansicht rendert im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();
        await _openDetail(tester);

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(
            const ValueKey('recipe-detail-hahnchen_mit_reis_and_brokkoli'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('recipe-add-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('recipe-add-button')), findsOneWidget);
        expect(find.byKey(const ValueKey('recipe-detail-back')), findsOneWidget);
      });

      testWidgets('Slot-Picker rendert im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();
        await _openDetail(tester);
        await _openSlotPicker(tester);

        expect(tester.takeException(), isNull);
        for (final slot in MealSlot.values) {
          expect(
            find.byKey(ValueKey('recipe-meal-picker-${slot.name}')),
            findsOneWidget,
            reason: '${slot.name} fehlt im Picker',
          );
        }
        expect(
          find.byKey(const ValueKey('recipe-meal-picker-cancel')),
          findsOneWidget,
        );
        expect(find.text('Wann eintragen?'), findsOneWidget);
      });

      // Der einzige Ort im Paket, an dem Text NICHT auf einer Token-Flaeche
      // liegt: die Bildkachel des Karussells. Ihr Scrim ist in beiden Modi
      // dunkel (das Foto ist dasselbe) — `t.ink` waere dort im Hellmodus
      // schwarz auf schwarz. Ein „no exception"-Test sieht das nicht.
      testWidgets('Text auf dem Foto bleibt im $modus-Modus hell',
          (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();

        final overlay = find
            .ancestor(
              of: find.text('EMPFOHLEN').first,
              matching: find.byType(Column),
            )
            .first;
        final texte = tester
            .widgetList<Text>(
              find.descendant(of: overlay, matching: find.byType(Text)),
            )
            .toList();

        // Der Titel traegt die Display-Familie, die Kennzahlen-Zeile 11 pt —
        // das Badge (dunkel auf Lime, korrekt so) faellt durch beide Raster.
        final aufDemFoto = texte.where(
          (w) =>
              w.style?.fontFamily == AppType.displayFamily ||
              w.style?.fontSize == 11,
        );
        expect(
          aufDemFoto.length,
          greaterThanOrEqualTo(2),
          reason: 'Titel und Kennzahlen der Bildkachel wurden nicht gefunden.',
        );
        for (final w in aufDemFoto) {
          expect(
            w.style!.color!.computeLuminance(),
            greaterThan(0.5),
            reason: '„${w.data}" steht auf dem dunklen Foto-Scrim und braucht '
                'helle Schrift.',
          );
        }
      });

      testWidgets('Anlege-Sheet rendert im $modus-Modus', (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('recipe-create-sheet')),
          findsOneWidget,
        );
        expect(find.text('Eigenes Rezept'), findsWidgets);
      });
    }
  });

  group('Textskalierung 2.0', () {
    testWidgets('Rezepte-Tab overflowt nicht', (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Der Rezepte-Tab', () async {
        await tester.pumpWidget(_app(Brightness.dark));
        await tester.pumpAndSettle();
        // Bis ans Listenende — die Ziel-Sektion liegt hinter der Hauptliste.
        await _scrollThrough(tester, const ValueKey('screen-recipes'));
        expect(
          find.byKey(const ValueKey('recipe-goal-matches')),
          findsOneWidget,
          reason: 'Vorbedingung: die Ziel-Sektion muss erreicht worden sein.',
        );
      });
    });

    testWidgets('Detail-Ansicht overflowt nicht', (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Die Rezept-Detailansicht', () async {
        await tester.pumpWidget(_app(Brightness.light));
        await tester.pumpAndSettle();
        await _openDetail(tester);
        // Einmal bis ans Ende: die vier Info-Sektionen (Portion, Zutaten,
        // Zubereitung, Profi-Hinweis) liegen bei doppelter Schrift mehrere
        // Bildschirmhoehen tief. Ein einzelner -600er Zug erreichte sie nicht.
        await _scrollThrough(tester, const ValueKey('recipe-detail-scroll'));
        expect(
          find.text('Profi-Hinweis'),
          findsOneWidget,
          reason: 'Vorbedingung: das Listenende muss erreicht worden sein.',
        );
      });
    });

    testWidgets('Slot-Picker overflowt nicht', (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Der Slot-Picker', () async {
        await tester.pumpWidget(_app(Brightness.dark));
        await tester.pumpAndSettle();
        await _openDetail(tester);
        await _openSlotPicker(tester);
      });
    });

    testWidgets('Anlege-Sheet overflowt nicht', (tester) async {
      _pinViewport(tester, textScale: 2.0);
      await _expectNoOverflow('Das Anlege-Sheet', () async {
        await tester.pumpWidget(_app(Brightness.dark));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
        await tester.pumpAndSettle();
      });
    });
  });

  testWidgets('Key-Inventar des Rezepte-Tabs ist vollstaendig', (tester) async {
    _pinViewport(tester);
    await tester.pumpWidget(_app(Brightness.dark));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipes-search-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-create-button')), findsOneWidget);

    // Das Suchfeld traegt den Key DIREKT auf dem TextField — fremde Suiten
    // casten darauf (test/home_page_tabs_test.dart).
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('recipes-search-input')))
          .controller,
      isNotNull,
    );

    // Das Loesch-X erscheint nur bei gefuelltem Feld.
    expect(find.byKey(const ValueKey('recipes-search-clear')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('recipes-search-input')),
      'reis',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipes-search-clear')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recipes-search-clear')));
    await tester.pumpAndSettle();

    // Die Chip-Leiste ist lazy: hintere Chips existieren erst, wenn sie in den
    // Cache-Bereich gescrollt sind. Deshalb einmal durchfahren und einsammeln.
    final strip = find
        .ancestor(
          of: find.byKey(const ValueKey('recipe-filter-Alle')),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(strip).position;
    final gesehen = <String>{};
    for (var offset = 0.0;; offset += 120) {
      for (final filter in recipeFilters) {
        if (find.byKey(ValueKey('recipe-filter-$filter')).evaluate().isNotEmpty) {
          gesehen.add(filter);
        }
      }
      if (offset > position.maxScrollExtent) break;
      position.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
      await tester.pumpAndSettle();
    }
    expect(gesehen, containsAll(recipeFilters));

    await _scrollTo(tester, find.byKey(const ValueKey('recipe-goal-matches')));
    expect(find.byKey(const ValueKey('recipe-goal-matches')), findsOneWidget);
  });

  // Diese drei Meldungen liefen frueher ueber `showAppSnack(accent: …)` und
  // erreichten `context.t` nie (der Ausdruck ist kurzschliessend). Seit der
  // Migration auf `tone:` ist der Token-Zugriff scharf — ein Toast ohne Theme
  // wuerde jetzt werfen. test/flows/recipes_flow_test.dart pinnt den ersten
  // Satz ebenfalls, laeuft aber ueber `EatovaApp`; hier haengt er an nichts
  // Fremdem.
  group('Toasts', () {
    testWidgets('Eintragen meldet „590 kcal zu Mittagessen hinzugefügt."',
        (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.light));
      await tester.pumpAndSettle();
      await _openDetail(tester);
      await _openSlotPicker(tester);

      await tester.tap(find.byKey(const ValueKey('recipe-meal-picker-lunch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('590 kcal zu Mittagessen hinzugefügt.'), findsOneWidget);
    });

    testWidgets('Loeschen eines Eigen-Rezepts meldet den Titel',
        (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.dark, userRecipes: [_eigenes]));
      await tester.pumpAndSettle();

      final tile = find.byKey(ValueKey('recipe-tile-${_eigenes.slug}'));
      await _scrollTo(tester, tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('„${_eigenes.title}" gelöscht.'), findsOneWidget);
      expect(find.byKey(ValueKey('recipe-tile-${_eigenes.slug}')), findsNothing);
    });

    testWidgets('Speichern eines neuen Rezepts meldet den Titel',
        (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.light));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recipe-create-name')),
        'Protein-Bowl',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recipe-create-kcal')),
        '520',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('„Protein-Bowl" gespeichert.'), findsOneWidget);
    });
  });

  // Die Feldbeschriftung wanderte beim Umbau von `InputDecoration.labelText`
  // auf eine Versalien-Zeile UEBER dem Feld. Optisch ist das die neue Sprache
  // — fuer den Screenreader war das Feld danach unbeschriftet („Textfeld,
  // leer"), gemessen mit getSemantics().label == ''. Dieser Test haelt den
  // wiederhergestellten Bezug fest.
  testWidgets('Jedes Feld des Anlege-Sheets sagt sich mit Namen an',
      (tester) async {
    final semantics = tester.ensureSemantics();
    _pinViewport(tester);
    await tester.pumpWidget(_app(Brightness.dark));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
    await tester.pumpAndSettle();

    const felder = <String, String>{
      'recipe-create-name': 'Name',
      'recipe-create-portion': 'Portion',
      'recipe-create-kcal': 'Kalorien',
      'recipe-create-grams': 'Gewicht',
      'recipe-create-protein': 'Protein',
      'recipe-create-carbs': 'KH',
      'recipe-create-fat': 'Fett',
      'recipe-create-ingredients': 'Zutaten',
    };
    felder.forEach((key, label) {
      expect(
        tester.getSemantics(find.byKey(ValueKey(key))).label,
        contains(label),
        reason: '„$key" sagt sich dem Screenreader nicht als „$label" an',
      );
    });

    semantics.dispose();
  });

  // Vor dem Feinschliff zeigte die Kennzahlen-Zeile nur `kcal`, Protein und das
  // Portionsgewicht — KH und Fett standen bis dahin auf JEDER Karte (frueher
  // `_MacroRow`) und waren nach dem Umbau nur noch im Detail zu finden. Dieser
  // Test haelt das komplette Makro-Trio auf der Listenkachel fest.
  testWidgets('Die Listenkachel zeigt kcal und alle drei Makros',
      (tester) async {
    _pinViewport(tester);
    await tester.pumpWidget(_app(Brightness.light));
    await tester.pumpAndSettle();

    final tile = find.byKey(
      const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
    );
    await _scrollTo(tester, tile);

    for (final kennzahl in <String>['590 kcal', '55g P', '62g KH', '12g F']) {
      expect(
        find.descendant(of: tile, matching: find.text(kennzahl)),
        findsOneWidget,
        reason: '„$kennzahl" fehlt auf der Rezept-Kachel',
      );
    }
  });

  group('Echte Bilder bleiben, der Platzhalter ist der Ausnahmefall', () {
    testWidgets('Bestandsrezepte zeigen keinen Platzhalter', (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.dark));
      await tester.pumpAndSettle();

      expect(
        find.byType(ImagePlaceholder),
        findsNothing,
        reason: 'Alle 30 Bestandsrezepte haben ein echtes Asset — der '
            'Platzhalter des Entwurfs darf sie nicht ersetzen.',
      );
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('ein Eigen-Rezept ohne Bild bekommt den Platzhalter',
        (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(Brightness.dark, userRecipes: [_eigenes]));
      await tester.pumpAndSettle();

      expect(find.byType(ImagePlaceholder), findsWidgets);
    });
  });
}
