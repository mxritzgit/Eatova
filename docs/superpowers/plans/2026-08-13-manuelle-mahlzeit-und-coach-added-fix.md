# Manueller Mahlzeiten-Eintrag + /recipe-„Hinzugefügt"-Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Formular für eigene Nährwerte (pro 100 g + Portion) mit zwei Einstiegen im Add-Meal-Sheet, plus deterministische Coach-Rezept-Slugs, damit die /recipe-Karte „Hinzugefügt" über App-Neustarts hinweg kennt.

**Architecture:** Der manuelle Eintrag produziert ein normales `MealAnalysisResult` (neue Factory `manualEntry`, neue Herkunfts-Codes `manual` in den drei bestehenden Enums) und fließt durch den unveränderten `onAdd`-Pfad — keine DB-Migration. Der Coach-Fix ersetzt die In-Memory-Map `_createdRecipeSlugByMessage` durch den ableitbaren Slug `user_coach_<messageId>`.

**Tech Stack:** Flutter 3.44.0 (Dart), flutter_test, ARB-l10n (de+en), bestehende Token-/Sheet-Muster.

**Spec:** `docs/superpowers/specs/2026-08-13-manuelle-mahlzeit-und-coach-added-fix-design.md`

## Global Constraints

- Branch: `feat/manuelle-mahlzeit-coach-added-fix` (existiert schon; main ist CI-geschützt, NIE direkt pushen).
- Flutter ist NICHT auf PATH: immer `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" <cmd>` (PowerShell).
- Kein hartkodiertes Deutsch/Englisch in neuen UI-Pfaden: jeder nutzersichtbare Text über ARB-Keys in **beiden** Dateien `lib/l10n/app_de.arb` + `lib/l10n/app_en.arb` (`test/l10n/arb_parity_test.dart` erzwingt Parität). Nach ARB-Edits `flutter gen-l10n` laufen lassen und `lib/src/l10n/generated/` mit committen.
- Eingabefelder ohne Fokus-Ringe/InputDecoration-Rahmen — Kapsel-Optik wie `_RecipeSheetField` (recipe_create_sheet.dart:1128–1182): `t.surf`-Container, `Border.all(t.line)`, rot nur bei Fehler.
- Menschen-Eingaben werden bei Ungültigkeit ABGELEHNT (Feld-Fehler + gesperrter Save), nie still geklemmt. Klemmen ist nur Defensiv-Schicht in Modell-Fabriken.
- Code-Kommentare auf Deutsch, im Stil der Nachbarschaft (Begründungen, keine Was-Kommentare).
- Commits: Conventional-Prefix deutsch (`feat(...)`, `fix(...)`, `test(...)`), am Ende jedes Tasks committen. Jeder Commit endet mit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` und
  `Claude-Session: https://claude.ai/code/session_019iTwZBfFGuSoRS1bmnAQzk`
- Vor dem Task-Commit: betroffene Tests laufen grün; am Ende (Task 7) `flutter analyze` + kompletter `flutter test`.

---

### Task 1: Modell-Basis — Herkunfts-Codes `manual` + Factory `MealAnalysisResult.manualEntry`

**Files:**
- Modify: `lib/src/models/meal_analysis_result.dart`
- Modify: `lib/l10n/app_de.arb`, `lib/l10n/app_en.arb` (3 Anzeige-Keys)
- Test: `test/models/meal_analysis_manual_entry_test.dart` (neu)

**Interfaces:**
- Consumes: `clampMealName`, `clampPortionGrams`, `clampKcalPer100G`, `clampMealCaloriesKcal` aus `model_limits.dart` (bereits importiert).
- Produces: `MealAnalysisResult.manualEntry({required String name, required int kcalPer100G, required int grams, int? proteinPer100G, int? carbsPer100G, int? fatPer100G})` → `MealAnalysisResult`; `MealAnalysisResult.macroForGrams(double? per100G, int grams)` → `String` (public, vorher `_macroForGrams`); Enum-Werte `MealResultSource.manual` (code `'manual'`), `MealResultConfidence.manual` (code `'manual'`), `MealResultPortionNote.manual` (code `'manualEntryNote'`).

- [ ] **Step 1: Failing Test schreiben**

Neue Datei `test/models/meal_analysis_manual_entry_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';

// Manueller Eintrag (Spec 2026-08-13): Etikett-Werte pro 100 g plus die
// gegessene Portion — die Factory rechnet die Portionswerte aus und traegt
// die neuen manual-Herkunfts-Codes.
void main() {
  test('manualEntry rechnet die Portion aus den 100-g-Werten', () {
    final r = MealAnalysisResult.manualEntry(
      name: 'Bauern-Mozzarella',
      kcalPer100G: 265,
      grams: 125,
      proteinPer100G: 18,
      carbsPer100G: 2,
      fatPer100G: 22,
    );
    expect(r.mealName, 'Bauern-Mozzarella');
    expect(r.caloriesKcal, 331, reason: '265 × 1,25 = 331,25 → gerundet');
    expect(r.estimatedGrams, 125);
    expect(r.kcalPer100G, 265);
    expect(r.protein, '22,5 g');
    expect(r.carbs, '2,5 g');
    expect(r.fat, '27,5 g');
    expect(r.sourceLabel, 'manual');
    expect(r.confidence, 'manual');
    expect(r.portionNotes, 'manualEntryNote');
    expect(r.explicitZeroKcal, isFalse);
    expect(r.items, isEmpty);
    expect(r.barcode, isNull);
  });

  test('leere Makros bleiben unbekannt statt erfunden', () {
    final r = MealAnalysisResult.manualEntry(
      name: 'Sülze',
      kcalPer100G: 120,
      grams: 100,
    );
    expect(r.protein, '-');
    expect(r.carbs, '-');
    expect(r.fat, '-');
  });

  test('ausdrückliche 0 kcal ist eine Messung (Wasser), kein Sentinel', () {
    final r = MealAnalysisResult.manualEntry(
      name: 'Wasser',
      kcalPer100G: 0,
      grams: 500,
    );
    expect(r.caloriesKcal, 0);
    expect(r.explicitZeroKcal, isTrue);
  });

  test('Defensiv-Klemmen für Werte außerhalb der Formulargrenzen', () {
    // Das Formular lehnt solche Eingaben ab; die Factory klemmt trotzdem,
    // falls je ein anderer Aufrufer entsteht.
    final r = MealAnalysisResult.manualEntry(
      name: '',
      kcalPer100G: 5000,
      grams: 0,
    );
    expect(r.kcalPer100G, 900);
    expect(r.estimatedGrams, 1);
    expect(r.mealName, isNotEmpty);
  });

  test('die neuen Codes lösen über resolve auf (Code UND legacyDe)', () {
    expect(MealResultSource.resolve('manual'), MealResultSource.manual);
    expect(MealResultSource.resolve('Manuell'), MealResultSource.manual);
    expect(MealResultConfidence.resolve('manual'), MealResultConfidence.manual);
    expect(
      MealResultPortionNote.resolve('manualEntryNote'),
      MealResultPortionNote.manual,
    );
  });
}
```

- [ ] **Step 2: Test laufen lassen — er MUSS fehlschlagen**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/models/meal_analysis_manual_entry_test.dart`
Expected: Kompilierfehler „manualEntry isn't defined" / „manual isn't defined".

- [ ] **Step 3: ARB-Anzeige-Keys ergänzen (beide Sprachen)**

In `lib/l10n/app_de.arb`, direkt nach `"foodConfidenceRecipe"`-Block bzw. bei den `foodSource*`/`foodScanNote*`-Nachbarn einfügen:

```json
"foodSourceManual": "Manuell",
"foodConfidenceManual": "Eigene Angabe",
"foodManualEntryNote": "Nährwerte manuell nach Etikett eingetragen (pro 100 g).",
```

In `lib/l10n/app_en.arb` an denselben Stellen:

```json
"foodSourceManual": "Manual",
"foodConfidenceManual": "Own entry",
"foodManualEntryNote": "Nutrition entered manually from the label (per 100 g).",
```

Dann: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" gen-l10n`

- [ ] **Step 4: Enums + Factory implementieren**

In `lib/src/models/meal_analysis_result.dart`:

(a) Code-Konstanten ergänzen:

```dart
abstract final class _MealResultSourceCodes {
  static const String aiEstimate = 'aiEstimate';
  static const String photoAi = 'photoAi';
  static const String openFoodFacts = 'OpenFoodFacts';
  static const String recipe = 'recipe';
  static const String manual = 'manual';
}
```

und in `_MealResultConfidenceCodes` analog `static const String manual = 'manual';`.

(b) `MealResultSource`: neuen Wert ans Ende der Werteliste (vor dem `;`):

```dart
  recipe(_MealResultSourceCodes.recipe, legacyDe: 'Eatova Rezept'),
  // Manueller Eintrag (Spec 2026-08-13). legacyDe ist hier nur ein
  // Resolve-Alias — Alt-Zeilen mit diesem Wert gibt es nicht.
  manual(_MealResultSourceCodes.manual, legacyDe: 'Manuell');
```

und im `label`-switch: `MealResultSource.manual => l10n.foodSourceManual,`.

(c) `MealResultConfidence`: Wert `manual(_MealResultConfidenceCodes.manual, legacyDe: 'Eigene Angabe');` ans Ende, `label`-Case `MealResultConfidence.manual => l10n.foodConfidenceManual,`.

(d) `MealResultPortionNote`: Wert ans Ende:

```dart
  manual(
    'manualEntryNote',
    legacyDe: 'Nährwerte manuell nach Etikett eingetragen (pro 100 g).',
  );
```

und `text`-Case `MealResultPortionNote.manual => l10n.foodManualEntryNote,`.

(e) `_macroForGrams` → public `macroForGrams` umbenennen (drei interne Aufrufer in `fromOpenFoodFacts` mitziehen; Doku-Satz ergänzen, dass die manuelle Factory und das Formular denselben Formatierer nutzen).

(f) Factory hinter `fromOpenFoodFacts` einfügen:

```dart
  /// Baut das Ergebnis eines MANUELL eingetragenen Lebensmittels
  /// (manual_meal_sheet, Spec 2026-08-13): Etikett-Werte pro 100 g plus die
  /// gegessene Portion. Anders als bei den Parser-Fabriken oben sind die
  /// Eingaben formularvalidiert — die Klemmen sind reine Defensiv-Schicht,
  /// keine Reparatur.
  factory MealAnalysisResult.manualEntry({
    required String name,
    required int kcalPer100G,
    required int grams,
    int? proteinPer100G,
    int? carbsPer100G,
    int? fatPer100G,
  }) {
    final zielGramm = clampPortionGrams(grams);
    final dichte = clampKcalPer100G(kcalPer100G);
    final kalorien = clampMealCaloriesKcal(dichte * zielGramm / 100);
    return MealAnalysisResult(
      mealName: clampMealName(name),
      caloriesKcal: kalorien,
      estimatedGrams: zielGramm,
      kcalPer100G: dichte,
      protein: macroForGrams(proteinPer100G?.toDouble(), zielGramm),
      carbs: macroForGrams(carbsPer100G?.toDouble(), zielGramm),
      fat: macroForGrams(fatPer100G?.toDouble(), zielGramm),
      confidence: _MealResultConfidenceCodes.manual,
      portionNotes: 'manualEntryNote',
      sourceLabel: _MealResultSourceCodes.manual,
      // Eine AUSDRÜCKLICH eingetragene 0 (Wasser, Zero) ist eine Messung,
      // kein Unbekannt-Sentinel — nur sie darf die Log-Bremse passieren.
      explicitZeroKcal: kcalPer100G == 0,
    );
  }
```

- [ ] **Step 5: Tests laufen lassen — grün**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/models/meal_analysis_manual_entry_test.dart test/models/meal_result_source_test.dart test/l10n/arb_parity_test.dart`
Expected: PASS (auch die bestehenden Source-Resolve-Tests).

- [ ] **Step 6: Commit**

```powershell
git add lib/src/models/meal_analysis_result.dart lib/l10n lib/src/l10n/generated test/models/meal_analysis_manual_entry_test.dart
git commit -m "feat(food): manual-Herkunfts-Codes + MealAnalysisResult.manualEntry"
```

---

### Task 2: Formular-Sheet `manual_meal_sheet.dart`

**Files:**
- Create: `lib/src/widgets/kcal/manual_meal_sheet.dart`
- Modify: `lib/l10n/app_de.arb`, `lib/l10n/app_en.arb` (UI-Keys)
- Test: `test/manual_meal_sheet_test.dart` (neu)

**Interfaces:**
- Consumes: `MealAnalysisResult.manualEntry(...)` aus Task 1; `clampMealCaloriesKcal` aus `model_limits.dart`; bestehende ARB-Keys `recipesGroupWhatIsIt`, `foodAddItemNameLabel`, `foodAddItemCaloriesLabel`, `todayMacroProtein`, `recipesNutritionCarbsLabel`, `todayMacroFat`, `foodAddItemWeightLabel`, `commonSave`, `recipesRangeErrorKcal(min,max)`, `recipesRangeErrorGrams(min,max)`.
- Produces: `showManualMealSheet(BuildContext context, {String? initialName})` → `Future<MealAnalysisResult?>` (null = abgebrochen). Widget-Keys: `manual-meal-sheet`, `manual-meal-name`, `manual-meal-kcal100`, `manual-meal-grams`, `manual-meal-protein`, `manual-meal-carbs`, `manual-meal-fat`, `manual-meal-computed`, `manual-meal-save`.

- [ ] **Step 1: UI-ARB-Keys ergänzen (beide Sprachen)**

`lib/l10n/app_de.arb` (bei den `foodManual*`-Keys aus Task 1):

```json
"foodManualEntryTitle": "Eigene Nährwerte",
"foodManualEntrySubtitle": "Werte vom Etikett pro 100 g — deine Portion rechnet Eatova aus.",
"foodManualEntryTooltip": "Manuell eintragen",
"foodManualEntryCta": "Manuell eintragen",
"foodManualNameHint": "z. B. Bauern-Mozzarella",
"foodManualGroupNutrition": "Nährwerte",
"foodManualPer100GSuffix": "pro 100 g",
"foodManualGroupPortion": "Deine Portion",
"foodManualComputedKcal": "= {kcal} kcal für {grams} g",
"@foodManualComputedKcal": {
  "placeholders": {
    "kcal": { "type": "int" },
    "grams": { "type": "int" }
  }
},
```

`lib/l10n/app_en.arb`:

```json
"foodManualEntryTitle": "Custom nutrition",
"foodManualEntrySubtitle": "Label values per 100 g — Eatova calculates your portion.",
"foodManualEntryTooltip": "Add manually",
"foodManualEntryCta": "Add manually",
"foodManualNameHint": "e.g. farm mozzarella",
"foodManualGroupNutrition": "Nutrition",
"foodManualPer100GSuffix": "per 100 g",
"foodManualGroupPortion": "Your portion",
"foodManualComputedKcal": "= {kcal} kcal for {grams} g",
"@foodManualComputedKcal": {
  "placeholders": {
    "kcal": { "type": "int" },
    "grams": { "type": "int" }
  }
},
```

Dann: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" gen-l10n`

- [ ] **Step 2: Failing Widget-Test schreiben**

Neue Datei `test/manual_meal_sheet_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';

// Manueller Eintrag (Spec 2026-08-13): Formular pro 100 g + Portion.
// Menschen-Eingaben werden ABGELEHNT statt geklemmt: Save sperrt, Feld
// traegt den Bereichs-Fehler.

class _ResultHalter {
  MealAnalysisResult? result;
}

Future<_ResultHalter> _open(
  WidgetTester tester, {
  String? initialName,
}) async {
  final halter = _ResultHalter();
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
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('open-manual'),
              onPressed: () async {
                halter.result = await showManualMealSheet(
                  context,
                  initialName: initialName,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-manual')));
  await tester.pumpAndSettle();
  return halter;
}

FilledButton _saveButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.byKey(const ValueKey('manual-meal-save')),
    );

void main() {
  testWidgets('Save sperrt, bis Name + kcal/100 g + Gramm gültig sind',
      (tester) async {
    await _open(tester);
    expect(_saveButton(tester).onPressed, isNull,
        reason: 'leeres Formular (Gramm ist mit 100 vorbelegt) sperrt');

    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-name')), 'Bauern-Mozzarella');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')), '2000');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull,
        reason: '2000 kcal/100 g ist physikalisch unmöglich');
    expect(find.text('0–900 kcal'), findsOneWidget,
        reason: 'Ablehnen mit Bereichs-Fehler statt stiller Klemmung');

    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')), '265');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('liefert das gerechnete Ergebnis samt Vorschau zurück',
      (tester) async {
    final halter = await _open(tester);
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-name')), 'Bauern-Mozzarella');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')), '265');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-grams')), '125');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-protein')), '18');
    await tester.pump();

    expect(find.byKey(const ValueKey('manual-meal-computed')), findsOneWidget);
    expect(find.text('= 331 kcal für 125 g'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('manual-meal-save')));
    await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
    await tester.pumpAndSettle();

    final r = halter.result;
    expect(r, isNotNull);
    expect(r!.mealName, 'Bauern-Mozzarella');
    expect(r.caloriesKcal, 331);
    expect(r.estimatedGrams, 125);
    expect(r.protein, '22,5 g');
    expect(r.carbs, '-');
    expect(r.sourceLabel, 'manual');
    expect(r.explicitZeroKcal, isFalse);
  });

  testWidgets('0 kcal (Wasser) ist speicherbar und trägt explicitZeroKcal',
      (tester) async {
    final halter = await _open(tester);
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-name')), 'Wasser');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')), '0');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-grams')), '500');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);

    await tester.ensureVisible(find.byKey(const ValueKey('manual-meal-save')));
    await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
    await tester.pumpAndSettle();

    expect(halter.result?.caloriesKcal, 0);
    expect(halter.result?.explicitZeroKcal, isTrue);
  });

  testWidgets('initialName belegt das Namensfeld vor (Such-CTA)',
      (tester) async {
    await _open(tester, initialName: 'Bauernmozzarella');
    final feld = tester.widget<TextField>(
      find.byKey(const ValueKey('manual-meal-name')),
    );
    expect(feld.controller?.text, 'Bauernmozzarella');
  });

  testWidgets('Abbrechen liefert null', (tester) async {
    final halter = await _open(tester);
    // Sheet per Barriere-Tap schließen (oberhalb des Sheets tippen).
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(halter.result, isNull);
  });
}
```

- [ ] **Step 3: Test laufen lassen — er MUSS fehlschlagen**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/manual_meal_sheet_test.dart`
Expected: Kompilierfehler „manual_meal_sheet.dart not found".

- [ ] **Step 4: Sheet implementieren**

Neue Datei `lib/src/widgets/kcal/manual_meal_sheet.dart` (Muster: `recipe_create_sheet.dart` für Felder/Validierung, `add_meal_sheet.dart` für die Modal-Hülle):

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/model_limits.dart';
import '../../theme/app_tokens.dart';

/// Formular für eigene Nährwerte (Spec 2026-08-13): Werte vom Etikett PRO
/// 100 g plus die gegessene Portion — `MealAnalysisResult.manualEntry`
/// rechnet die Portionswerte aus. Für Lebensmittel ohne Datenbank-Eintrag
/// (Hofladen, Wochenmarkt, lose Ware).
///
/// Liefert das fertige Ergebnis zurück oder null (abgebrochen); GELOGGT wird
/// im Aufrufer (Add-Meal-Sheet) — dieselbe Trennung wie beim Analyse-Sheet.
///
/// **Bewusst OHNE Verwerfen-Schutz (D5-Kriterium, s. add_meal_sheet.dart):**
/// hier stehen ein Name und vier Zahlen vom Etikett — in Sekunden erneut
/// eingetippt, anders als die acht Rezeptfelder.
Future<MealAnalysisResult?> showManualMealSheet(
  BuildContext context, {
  String? initialName,
}) {
  return showModalBottomSheet<MealAnalysisResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Wie im Add-Meal-Sheet: der Scrim dunkelt in beiden Anzeige-Modi ab.
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetContext) => ManualMealSheet(initialName: initialName),
  );
}

class ManualMealSheet extends StatefulWidget {
  const ManualMealSheet({super.key, this.initialName});

  /// Vorbelegung aus der Produktsuche („nichts gefunden" → Suchbegriff).
  final String? initialName;

  @override
  State<ManualMealSheet> createState() => _ManualMealSheetState();
}

class _ManualMealSheetState extends State<ManualMealSheet> {
  late final TextEditingController _name;
  late final TextEditingController _kcal100;
  late final TextEditingController _grams;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;

  // kcal/100 g läuft gegen die PLAUSIBILITÄTS-Grenze (reines Fett ~900),
  // nicht gegen die DB-Grenze — mehr ist physikalisch unmöglich. Die 0 ist
  // erlaubt: eine ausdrückliche 0 (Wasser, Zero) ist eine Messung
  // (MealAnalysisResult.explicitZeroKcal), kein fehlender Wert.
  static const int _kcal100Min = 0; // PlausibilityLimits.kcalPer100GMin
  static const int _kcal100Max = 900; // PlausibilityLimits.kcalPer100GMax
  static const int _gramsMin = 1; // PlausibilityLimits.portionGramsMin
  static const int _gramsMax = 10000; // PlausibilityLimits.portionGramsMax
  static const int _macroMin = 0; // LoggedMealLimits.macroGMin
  static const int _macroMax = 1000; // LoggedMealLimits.macroGMax

  @override
  void initState() {
    super.initState();
    _name = _feld(widget.initialName?.trim() ?? '');
    _kcal100 = _feld();
    // 100 g als Startwert: die Etikett-Basis selbst — wer die ganze
    // Referenzmenge isst, muss nichts anfassen.
    _grams = _feld('100');
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
  }

  /// Controller mit Rebuild-Listener — Save-Sperre, Fehlertexte und die
  /// Vorschauzeile hängen live am Feldinhalt (Muster recipe_create_sheet).
  TextEditingController _feld([String start = '']) {
    final controller = TextEditingController(text: start);
    controller.addListener(() => setState(() {}));
    return controller;
  }

  @override
  void dispose() {
    _name.dispose();
    _kcal100.dispose();
    _grams.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    super.dispose();
  }

  /// Fehlertext für ein Ganzzahlfeld oder null. Ein LEERES Feld bekommt
  /// bewusst keinen Fehler („noch nichts eingegeben" ist kein Eingabefehler);
  /// fehlende Pflichtwerte sperren allein über [_isValid].
  String? _bereichsFehler(
    TextEditingController controller, {
    required int min,
    required int max,
    required String Function(int min, int max) bereichstext,
  }) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final wert = int.tryParse(text);
    if (wert == null || wert < min || wert > max) return bereichstext(min, max);
    return null;
  }

  String? get _kcal100Fehler => _bereichsFehler(
        _kcal100,
        min: _kcal100Min,
        max: _kcal100Max,
        bereichstext: context.l10n.recipesRangeErrorKcal,
      );

  String? get _gramsFehler => _bereichsFehler(
        _grams,
        min: _gramsMin,
        max: _gramsMax,
        bereichstext: context.l10n.recipesRangeErrorGrams,
      );

  String? _makroFehler(TextEditingController controller) => _bereichsFehler(
        controller,
        min: _macroMin,
        max: _macroMax,
        bereichstext: context.l10n.recipesRangeErrorGrams,
      );

  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    if (_kcal100.text.trim().isEmpty || _grams.text.trim().isEmpty) {
      return false;
    }
    return _kcal100Fehler == null &&
        _gramsFehler == null &&
        _makroFehler(_protein) == null &&
        _makroFehler(_carbs) == null &&
        _makroFehler(_fat) == null;
  }

  int? _zahlOderNull(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : int.tryParse(text);
  }

  /// Gerechnete Portion für die Vorschauzeile — nur wenn beide Pflichtzahlen
  /// gültig dastehen, sonst null (keine Vorschau aus halben Eingaben).
  int? get _vorschauKcal {
    if (_kcal100Fehler != null || _gramsFehler != null) return null;
    final kcal100 = _zahlOderNull(_kcal100);
    final gramm = _zahlOderNull(_grams);
    if (kcal100 == null || gramm == null) return null;
    return clampMealCaloriesKcal(kcal100 * gramm / 100);
  }

  void _save() {
    if (!_isValid) return;
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(
      MealAnalysisResult.manualEntry(
        name: _name.text,
        kcalPer100G: _zahlOderNull(_kcal100)!,
        grams: _zahlOderNull(_grams)!,
        proteinPer100G: _zahlOderNull(_protein),
        carbsPer100G: _zahlOderNull(_carbs),
        fatPer100G: _zahlOderNull(_fat),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final mediaQuery = MediaQuery.of(context);
    final vorschau = _vorschauKcal;
    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: Container(
        key: const ValueKey('manual-meal-sheet'),
        constraints: BoxConstraints(
          maxHeight: mediaQuery.size.height * 0.92,
        ),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(rSheet)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.line,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.foodManualEntryTitle,
                style: AppType.display(24, color: t.ink, height: 1.15),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.foodManualEntrySubtitle,
                style: AppType.ui(12.5, color: t.ink2, height: 1.4),
              ),
              const SizedBox(height: 12),
              _ManualGroup(
                label: l10n.recipesGroupWhatIsIt,
                child: _ManualField(
                  fieldKey: const ValueKey('manual-meal-name'),
                  controller: _name,
                  label: l10n.foodAddItemNameLabel,
                  hint: l10n.foodManualNameHint,
                  maxChars: LoggedMealLimits.mealNameMaxChars,
                ),
              ),
              const SizedBox(height: 10),
              _ManualGroup(
                label: l10n.foodManualGroupNutrition,
                trailing: l10n.foodManualPer100GSuffix,
                // 2×2 statt 4 Spalten: die Felder tragen längere Kopfzeilen
                // („KALORIEN · KCAL") und bleiben so auch bei großer Schrift
                // einzeilig.
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _ManualField(
                            fieldKey: const ValueKey('manual-meal-kcal100'),
                            controller: _kcal100,
                            label: l10n.foodAddItemCaloriesLabel,
                            unit: 'kcal',
                            numeric: true,
                            dot: t.accent,
                            errorText: _kcal100Fehler,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _ManualField(
                            fieldKey: const ValueKey('manual-meal-protein'),
                            controller: _protein,
                            label: l10n.todayMacroProtein,
                            unit: 'g',
                            numeric: true,
                            dot: t.protein,
                            errorText: _makroFehler(_protein),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _ManualField(
                            fieldKey: const ValueKey('manual-meal-carbs'),
                            controller: _carbs,
                            label: l10n.recipesNutritionCarbsLabel,
                            unit: 'g',
                            numeric: true,
                            dot: t.carbs,
                            errorText: _makroFehler(_carbs),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _ManualField(
                            fieldKey: const ValueKey('manual-meal-fat'),
                            controller: _fat,
                            label: l10n.todayMacroFat,
                            unit: 'g',
                            numeric: true,
                            dot: t.fat,
                            errorText: _makroFehler(_fat),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _ManualGroup(
                label: l10n.foodManualGroupPortion,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ManualField(
                      fieldKey: const ValueKey('manual-meal-grams'),
                      controller: _grams,
                      label: l10n.foodAddItemWeightLabel,
                      unit: 'g',
                      numeric: true,
                      errorText: _gramsFehler,
                    ),
                    if (vorschau != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        key: const ValueKey('manual-meal-computed'),
                        l10n.foodManualComputedKcal(
                          vorschau,
                          _zahlOderNull(_grams)!,
                        ),
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w600,
                          color: t.accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // FilledButton mit onPressed == null als Sperrsignal — dasselbe
              // testbare Muster wie recipe-create-save.
              FilledButton.icon(
                key: const ValueKey('manual-meal-save'),
                onPressed: _isValid ? _save : null,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(
                  l10n.commonSave,
                  style: AppType.ui(14.5, weight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: t.forest,
                  foregroundColor: t.onForest,
                  disabledBackgroundColor: t.surf2,
                  disabledForegroundColor: t.ink2,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gruppen-Kopf (Versalien-Label + gedämpfter Zusatz rechts) — lokale Kopie
/// des `_SheetGroup`-Musters aus recipe_create_sheet.dart; beide Sheets
/// sprechen dieselbe Formular-Sprache.
class _ManualGroup extends StatelessWidget {
  const _ManualGroup({
    required this.label,
    required this.child,
    this.trailing,
  });

  final String label;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: AppType.eyebrow(t.ink2, size: 10),
              ),
            ),
            if (trailing != null)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    trailing!,
                    textAlign: TextAlign.right,
                    style: AppType.ui(
                      11,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// Beschriftetes Eingabefeld — lokale Kopie des `_RecipeSheetField`-Musters
/// (recipe_create_sheet.dart): Versalien-Kopfzeile mit Einheit, Kapsel ohne
/// InputDecoration-Rahmen, rot nur bei Fehler, Semantics-Label für den
/// Screenreader.
class _ManualField extends StatelessWidget {
  const _ManualField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.hint,
    this.unit,
    this.numeric = false,
    this.maxChars,
    this.errorText,
    this.dot,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? unit;
  final bool numeric;
  final int? maxChars;
  final String? errorText;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasError = errorText != null;
    final kopfzeile = unit == null
        ? label.toUpperCase()
        : '${label.toUpperCase()} · ${unit!.toUpperCase()}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          // Feste einzeilige Kopfzeile — s. recipe_create_sheet.dart:
          // ungleich umbrechende Labels ließen die Felder sonst auf
          // verschiedenen Höhen beginnen.
          height: MediaQuery.textScalerOf(context).scale(9.5) * 1.35,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (dot != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    kopfzeile,
                    maxLines: 1,
                    softWrap: false,
                    style: AppType.eyebrow(t.ink2, size: 9.5),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Container(
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: hasError ? t.danger : t.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Semantics(
                  label: label,
                  child: TextField(
                    key: fieldKey,
                    cursorOpacityAnimates: false,
                    controller: controller,
                    maxLength: maxChars,
                    keyboardType:
                        numeric ? TextInputType.number : TextInputType.text,
                    inputFormatters: numeric
                        ? [FilteringTextInputFormatter.digitsOnly]
                        : null,
                    textCapitalization: numeric
                        ? TextCapitalization.none
                        : TextCapitalization.sentences,
                    style: AppType.ui(14, color: t.ink),
                    cursorColor: t.accent,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      hintText: hint,
                      hintStyle: AppType.ui(14, color: t.ink2),
                      counterText: '',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
          ),
        ],
      ],
    );
  }
}
```

- [ ] **Step 5: Tests laufen lassen — grün**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/manual_meal_sheet_test.dart test/l10n/arb_parity_test.dart test/l10n/hartkodierung_waechter_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add lib/src/widgets/kcal/manual_meal_sheet.dart lib/l10n lib/src/l10n/generated test/manual_meal_sheet_test.dart
git commit -m "feat(food): Formular-Sheet fuer eigene Naehrwerte (pro 100 g + Portion)"
```

---

### Task 3: Einstieg 1 — Header-Icon im Add-Meal-Sheet + Logging-Pfad

**Files:**
- Modify: `lib/src/widgets/kcal/add_meal_sheet.dart`
- Test: `test/flows/manual_entry_flow_test.dart` (neu)

**Interfaces:**
- Consumes: `showManualMealSheet(context, {initialName})` aus Task 2; bestehendes `_handleAdd(String itemKey, MealAnalysisResult result)` (Zeile ~466, enthält 0-kcal-Bremse + Snack + onAdd); `FavoriteMeal.idFor(result)` (bereits importiert).
- Produces: `_openManualEntry({String? initialName})` in `_AddMealSheetState` (Task 4 ruft sie vom CTA aus); Header-Key `manual-entry-button`.

- [ ] **Step 1: Failing Flow-Test schreiben**

Neue Datei `test/flows/manual_entry_flow_test.dart` (Harness-Muster: `product_search_flow_test.dart`; `expectTagestotalAufHeute` kommt aus `flow_test_helpers.dart`):

```dart
// Manueller Eintrag (Spec 2026-08-13), Einstieg 1: das vierte Header-Icon im
// Add-Meal-Sheet oeffnet das Formular; das Ergebnis loggt ueber denselben
// Pfad wie eine Such-/Favoriten-Zeile in den gewaehlten Slot.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Header-Icon: manueller Eintrag landet im Tagestotal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Slot-Tap oeffnet das Add-Sheet im normalen Modus (Header-Icons an).
    await tester.tap(find.byKey(const ValueKey('food-slot-add-snack')));
    await tester.pumpAndSettle();

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

    // Erfolgs-Snack aus _handleAdd (265 × 1,25 = 331 kcal).
    expect(find.textContaining('331'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    await expectTagestotalAufHeute(tester, '331');
  });

  testWidgetsRobust('Such-Modus zeigt das Header-Icon NICHT', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    // Der Kopf bleibt im Such-Modus schlank (wie Kamera/Galerie/Barcode).
    expect(find.byKey(const ValueKey('manual-entry-button')), findsNothing);
  });
}
```

- [ ] **Step 2: Test laufen lassen — er MUSS fehlschlagen**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/flows/manual_entry_flow_test.dart`
Expected: FAIL — `manual-entry-button` nicht gefunden.

- [ ] **Step 3: Add-Meal-Sheet verdrahten**

In `lib/src/widgets/kcal/add_meal_sheet.dart`:

(a) Import ergänzen: `import 'manual_meal_sheet.dart';`

(b) In `_AddMealSheetState` (z. B. direkt vor `_handleAdd`):

```dart
  // ─── Manueller Eintrag ────────────────────────────────────────────────

  /// Einstieg fuer eigene Naehrwerte (Spec 2026-08-13). Das Formular baut nur
  /// das Ergebnis; geloggt wird hier ueber [_handleAdd] — inklusive der
  /// 0-kcal-Bremse (eine manuelle 0 traegt explicitZeroKcal und passiert sie)
  /// und des Erfolgs-Snacks. [initialName] kommt vom Such-CTA.
  Future<void> _openManualEntry({String? initialName}) async {
    final result = await showManualMealSheet(context, initialName: initialName);
    if (result == null || !mounted) return;
    _handleAdd('manual:${FavoriteMeal.idFor(result)}', result);
  }
```

(c) `_SheetHeader` um den vierten Eingang erweitern — Konstruktor/Feld:

```dart
  const _SheetHeader({
    required this.slot,
    this.searchMode = false,
    required this.onClose,
    required this.onCamera,
    required this.onGallery,
    required this.onBarcode,
    required this.onManual,
  });
  ...
  final VoidCallback onManual;
```

und im `if (!searchMode) ...[`-Block nach dem Barcode-Button:

```dart
            _HeaderIconButton(
              keyValue: const ValueKey('manual-entry-button'),
              icon: Icons.edit_rounded,
              tooltip: l10n.foodManualEntryTooltip,
              onPressed: onManual,
            ),
```

(d) Aufrufstelle in `build` ergänzen: `onManual: () => _openManualEntry(),` neben `onBarcode: _scanBarcode,`.

- [ ] **Step 4: Tests laufen lassen — grün**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/flows/manual_entry_flow_test.dart test/flows/food_log_flow_test.dart test/food_tab_layout_test.dart`
Expected: PASS (auch die bestehenden Food-Flows — der Header hat ein Icon mehr).

- [ ] **Step 5: Commit**

```powershell
git add lib/src/widgets/kcal/add_meal_sheet.dart test/flows/manual_entry_flow_test.dart
git commit -m "feat(food): viertes Header-Icon oeffnet den manuellen Eintrag"
```

---

### Task 4: Einstieg 2 — „Manuell eintragen"-CTA unter der Leersuche

**Files:**
- Modify: `lib/src/widgets/kcal/add_meal_sheet.dart`
- Modify: `test/flows/flow_test_helpers.dart` (2 neue Fake-Services)
- Test: `test/flows/manual_entry_flow_test.dart` (erweitern)

**Interfaces:**
- Consumes: `_openManualEntry({String? initialName})` aus Task 3; `ProductLookupService` (Interface mit `lookupBarcode`/`searchProducts`, s. bestehende Fakes in flow_test_helpers.dart).
- Produces: CTA-Key `manual-entry-cta`; Fakes `NeverFindsProductLookupService`, `AlwaysFailingProductLookupService` in flow_test_helpers.dart.

- [ ] **Step 1: Failing Tests ergänzen**

In `test/flows/manual_entry_flow_test.dart` anhängen:

```dart
  testWidgetsRobust('Leersuche bietet den manuellen Eintrag mit Vorbelegung an',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      EatovaApp(productService: NeverFindsProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Bauernmozzarella',
    );
    // Debounce (1000 ms) + 2 Leer-Retries (je 600 ms) abwarten.
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    final cta = find.byKey(const ValueKey('manual-entry-cta'));
    expect(cta, findsOneWidget,
        reason: 'endgueltig nichts gefunden -> direkter Weg ins Formular');

    await tester.tap(cta);
    await tester.pumpAndSettle();
    final nameFeld = tester.widget<TextField>(
      find.byKey(const ValueKey('manual-meal-name')),
    );
    expect(nameFeld.controller?.text, 'Bauernmozzarella',
        reason: 'der erfolglose Suchbegriff ist der wahrscheinlichste Name');
  });

  testWidgetsRobust('Netz-Fehler zeigt KEINEN manuellen CTA', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: AlwaysFailingProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Bauernmozzarella',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    // Fehler heisst „Suche kaputt", nicht „gibt es nicht" — kein CTA.
    expect(find.byKey(const ValueKey('manual-entry-cta')), findsNothing);
  });
```

In `test/flows/flow_test_helpers.dart` neben den bestehenden Fakes:

```dart
/// Suche findet NIE etwas — der Weg zum „Manuell eintragen"-CTA
/// (Spec 2026-08-13).
class NeverFindsProductLookupService implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      FakeProductLookupService.salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

/// Suche schlaegt IMMER fehl — der Fehler-Hinweis darf den CTA NICHT zeigen.
class AlwaysFailingProductLookupService implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      FakeProductLookupService.salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    throw Exception('OpenFoodFacts down');
  }
}
```

- [ ] **Step 2: Tests laufen lassen — die zwei neuen MÜSSEN fehlschlagen**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/flows/manual_entry_flow_test.dart`
Expected: FAIL — `manual-entry-cta` nicht gefunden (Leersuche-Test); der Fehler-Test ist trivially grün, das ist okay — er sichert die Abgrenzung ab jetzt.

- [ ] **Step 3: CTA implementieren**

In `lib/src/widgets/kcal/add_meal_sheet.dart`:

(a) Zustandsfeld neben `_productSearchMessage`:

```dart
  /// True NUR nach einer endgueltig leeren (fehlerfreien) Suche — der einzige
  /// Zustand, in dem der „Manuell eintragen"-CTA erscheint. Netz-Fehler und
  /// Min-Zeichen-Hinweis heissen „Suche kaputt/zu kurz", nicht „gibt es
  /// nicht", und bieten den CTA bewusst nicht an (Spec 2026-08-13).
  bool _searchCameUpEmpty = false;
```

(b) Das Feld an JEDER Stelle pflegen, die `_productSearchMessage` setzt:
- `_scheduleProductSearch`, Reset-Zweig (`query.length < 2`): `_searchCameUpEmpty = false;`
- `_searchProducts`, Min-Zeichen-Zweig: `_searchCameUpEmpty = false;`
- `_searchProducts`, Cache-Treffer: `_searchCameUpEmpty = cached.isEmpty;`
- `_searchProducts`, Leersuche-Cache-Zweig: `_searchCameUpEmpty = true;`
- `_searchProducts`, Erfolgs-`setState`: `_searchCameUpEmpty = suggestions.isEmpty;`
- `_searchProducts`, `catch`-`setState`: `_searchCameUpEmpty = false;`

(c) In `_buildSearchResults` den Hinweis-Zweig erweitern:

```dart
    if (_productSuggestions.isEmpty && _productSearchMessage != null) {
      return Column(
        children: [
          _HintBlock(text: _productSearchMessage!),
          if (_searchCameUpEmpty)
            // Der Hofladen-Moment: endgueltig nichts gefunden -> direkt ins
            // Formular, mit dem Suchbegriff als Namens-Vorbelegung.
            TextButton.icon(
              key: const ValueKey('manual-entry-cta'),
              onPressed: () => _openManualEntry(
                initialName: _searchController.text.trim(),
              ),
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: Text(context.l10n.foodManualEntryCta),
            ),
        ],
      );
    }
```

- [ ] **Step 4: Tests laufen lassen — grün**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/flows/manual_entry_flow_test.dart test/flows/product_search_flow_test.dart`
Expected: PASS (auch die bestehenden Such-Flows — Retry-/Fehlerlogik unangetastet).

- [ ] **Step 5: Commit**

```powershell
git add lib/src/widgets/kcal/add_meal_sheet.dart test/flows/flow_test_helpers.dart test/flows/manual_entry_flow_test.dart
git commit -m "feat(food): Manuell-eintragen-CTA unter der endgueltig leeren Produktsuche"
```

---

### Task 5: Coach-Fix Basis — `coachProposalSlug` + expliziter Slug in `toFitnessRecipe`

**Files:**
- Modify: `lib/src/models/fitness_recipe.dart` (neuer statischer Helfer)
- Modify: `lib/src/models/coach_recipe_proposal.dart` (Pflicht-Parameter `slug`)
- Test: `test/models/coach_recipe_proposal_test.dart` (anpassen + erweitern)

**Interfaces:**
- Consumes: bestehendes `FitnessRecipe.userRecipeSlug()` (bleibt für das manuelle Rezept-Formular unverändert).
- Produces: `FitnessRecipe.coachProposalSlug(String messageId)` → `'user_coach_<messageId>'`; geänderte Signatur `CoachRecipeProposal.toFitnessRecipe({required String imageAsset, required String slug})` (Task 6 übergibt den Karten-Slug).

- [ ] **Step 1: Failing Test schreiben**

In `test/models/coach_recipe_proposal_test.dart` einen Test ergänzen (bestehende `toFitnessRecipe`-Aufrufe im File kompilieren nach der Signatur-Änderung nicht mehr — bei jedem `slug: FitnessRecipe.coachProposalSlug('test-msg')` ergänzen und die dortige Slug-Erwartung auf `'user_coach_test-msg'` umstellen; Import `package:eatova/src/models/fitness_recipe.dart` hinzufügen, falls nicht da):

```dart
  test('toFitnessRecipe uebernimmt den deterministischen Karten-Slug', () {
    // Spec 2026-08-13: der Slug kommt vom Aufrufer (Message-Id der Karte),
    // damit „Hinzugefuegt" nach Neustart eine reine Ableitung bleibt.
    expect(FitnessRecipe.coachProposalSlug('srv-msg-1'), 'user_coach_srv-msg-1');
  });
```

- [ ] **Step 2: Test laufen lassen — er MUSS fehlschlagen**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/models/coach_recipe_proposal_test.dart`
Expected: Kompilierfehler „coachProposalSlug isn't defined".

- [ ] **Step 3: Implementieren**

`lib/src/models/fitness_recipe.dart`, direkt unter `userRecipeSlug()`:

```dart
  /// Slug für ein aus einer /recipe-Karte übernommenes Rezept —
  /// DETERMINISTISCH aus der Chat-Message-Id (Spec 2026-08-13). Damit ist
  /// „Hinzugefügt" auf der Karte eine reine Ableitung aus den Live-Slugs:
  /// sie übersteht den Neustart, synct aufs Zweitgerät, und ein Doppel-Tap
  /// läuft in den Upsert-Konflikt (user_id, slug) statt in ein Duplikat.
  static String coachProposalSlug(String messageId) =>
      'user_coach_$messageId';
```

`lib/src/models/coach_recipe_proposal.dart` — Signatur ändern:

```dart
  /// Baut das Eigen-Rezept nach denselben Regeln wie das manuelle Formular
  /// (recipe_create_sheet.dart:_save) — nur der Slug kommt vom AUFRUFER:
  /// für Karten-Vorschläge ist er deterministisch aus der Message-Id
  /// (FitnessRecipe.coachProposalSlug), NICHT gewürfelt — sonst wäre
  /// „Hinzugefügt" nach dem Neustart nicht mehr herleitbar (Spec 2026-08-13).
  FitnessRecipe toFitnessRecipe({
    required String imageAsset,
    required String slug,
  }) {
    return FitnessRecipe(
      slug: slug,
      ...
```

(übriger Rumpf unverändert; `FitnessRecipe.userRecipeSlug()`-Aufruf entfällt hier).

- [ ] **Step 4: Tests laufen lassen — grün**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/models/coach_recipe_proposal_test.dart test/models/fitness_recipe_strict_test.dart`
Expected: PASS. Hinweis: `coach_chat_screen.dart` kompiliert jetzt NICHT mehr (fehlender `slug`-Parameter) — das ist der erwartete Zwischenstand, Task 6 schließt ihn. Deshalb hier nur die Modell-Tests laufen lassen, nicht die ganze Suite.

- [ ] **Step 5: Commit**

```powershell
git add lib/src/models/fitness_recipe.dart lib/src/models/coach_recipe_proposal.dart test/models/coach_recipe_proposal_test.dart
git commit -m "fix(coach): deterministischer Rezept-Slug user_coach_<messageId> (Modell-Basis)"
```

---

### Task 6: Coach-Fix Screen — „Hinzugefügt" als reine Ableitung

**Files:**
- Modify: `lib/src/screens/coach/coach_chat_screen.dart`
- Test: `test/coach_recipe_flow_test.dart` (Regression + Anpassung)

**Interfaces:**
- Consumes: `FitnessRecipe.coachProposalSlug(messageId)` und `toFitnessRecipe(imageAsset:, slug:)` aus Task 5; bestehendes `CoachChatScreen.userRecipeSlugs` (Live-Sicht der Schale).
- Produces: `_isRecipeAdded(ChatMessage message)` ohne Map-Zustand — Verhalten, an dem `coach_message_list.dart` unverändert hängt.

- [ ] **Step 1: Failing Regressionstest schreiben**

In `test/coach_recipe_flow_test.dart` ergänzen (Harness `_pumpCoach`/`_proposal` existiert dort):

```dart
  testWidgets(
      'Neustart: Verlaufs-Karte kennt „Hinzugefügt", solange das Rezept existiert',
      (tester) async {
    // DER Bug der Spec 2026-08-13: Karte aus dem Verlauf + Rezept existiert
    // noch -> frueher fragte die Karte erneut. Der Slug ist jetzt aus der
    // Message-Id ableitbar, die In-Memory-Map ist weg.
    final svc = _RecipeCoach.create()
      ..history = <ChatMessage>[
        ChatMessage(
          id: 'srv-msg-1',
          role: ChatRole.assistant,
          content: 'Rezeptvorschlag: Huehnchenauflauf.',
          createdAt: DateTime(2026, 8, 12, 18),
          recipeProposal: _proposal(),
        ),
      ];
    final slugs = <String>{FitnessRecipe.coachProposalSlug('srv-msg-1')};
    await _pumpCoach(
      tester,
      service: svc,
      created: <FitnessRecipe>[],
      userRecipeSlugs: slugs,
    );

    expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
    expect(find.text('Hinzugefügt'), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsNothing,
        reason: 'das Rezept existiert noch — kein zweites Angebot');

    // Loeschen im Rezepte-Tab reaktiviert den Button (Live-Sicht).
    slugs.clear();
    await _pumpCoach(
      tester,
      service: svc,
      created: <FitnessRecipe>[],
      userRecipeSlugs: slugs,
    );
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsOneWidget);
    expect(find.text('Hinzugefügt'), findsNothing);
  });
```

Zusätzlich im bestehenden Test „Bestaetigen speichert einmal…" die Slug-Erwartung schärfen:

```dart
    expect(recipe.slug, startsWith('user_coach_'),
        reason: 'deterministischer Karten-Slug statt user_<ms> (Spec 2026-08-13)');
```

(ersetzt dort `expect(recipe.slug, startsWith('user_'));`).

- [ ] **Step 2: Test laufen lassen — er MUSS fehlschlagen**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/coach_recipe_flow_test.dart`
Expected: FAIL — aktuell kompiliert `coach_chat_screen.dart` nicht (Task-5-Signatur) bzw. nach mechanischem Fix zeigt die Verlaufs-Karte den aktiven Button statt „Hinzugefügt".

- [ ] **Step 3: Screen umbauen**

In `lib/src/screens/coach/coach_chat_screen.dart`:

(a) Das Feld `_createdRecipeSlugByMessage` (Zeile ~127–132) samt Doku-Kommentar ERSATZLOS löschen.

(b) `_isRecipeAdded` ersetzen:

```dart
  /// „Hinzugefügt" ist eine reine ABLEITUNG: der Karten-Slug ist
  /// deterministisch aus der Message-Id (FitnessRecipe.coachProposalSlug),
  /// die Live-Slugs kommen aus der Schale. Kein eigener Zustand — damit
  /// übersteht der Status App-Neustarts und Zweitgeräte, und Löschen im
  /// Rezepte-Tab reaktiviert den Button von selbst (Spec 2026-08-13).
  bool _isRecipeAdded(ChatMessage message) {
    if (message.recipeProposal == null) return false;
    return widget.userRecipeSlugs
        .contains(FitnessRecipe.coachProposalSlug(message.id));
  }
```

(c) In `_addProposalToRecipes` den Rezept-Bau und das `setState` anpassen:

```dart
    final recipe = proposal.toFitnessRecipe(
      imageAsset: imageAsset,
      slug: FitnessRecipe.coachProposalSlug(message.id),
    );
```

und aus dem `setState` nach dem `onCreate`-Await die Map-Zeile entfernen:

```dart
    setState(() {
      _addingRecipe = false;
    });
```

(d) Sicherstellen, dass `fitness_recipe.dart` importiert ist (für den `onCreateRecipe`-Typ ist es das bereits — sonst `import '../../models/fitness_recipe.dart';` ergänzen).

- [ ] **Step 4: Tests laufen lassen — grün**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/coach_recipe_flow_test.dart test/coach_state_retention_test.dart test/coach_design_test.dart`
Expected: PASS — inklusive des bestehenden „Löschen reaktiviert"-Tests (der jetzt über die Ableitung läuft statt über die Map).

- [ ] **Step 5: Commit**

```powershell
git add lib/src/screens/coach/coach_chat_screen.dart test/coach_recipe_flow_test.dart
git commit -m "fix(coach): Hinzugefuegt-Status ueberlebt den Neustart (Slug-Ableitung statt Map)"
```

---

### Task 7: Endabnahme — Analyze + volle Suite

**Files:**
- Keine neuen; nur Verifikation und ggf. Kleinst-Fixes aus analyze.

- [ ] **Step 1: Statische Analyse**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" analyze`
Expected: `No issues found!` — jede Meldung wird BEHOBEN, nicht unterdrückt (CI-Gate: analyze ist Pflicht-Check).

- [ ] **Step 2: Komplette Test-Suite**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test`
Expected: alle Tests PASS. Besonders im Blick: `test/l10n/arb_parity_test.dart`, `test/l10n/hartkodierung_waechter_test.dart`, `test/flows/*`, `test/coach_*`.

- [ ] **Step 3: Ggf. Rest-Commit**

Nur falls Step 1/2 Fixes nötig machten:

```powershell
git add -A -- lib test
git commit -m "fix(review): analyze-/Suite-Nachzuegler zum manuellen Eintrag"
```

---

## Self-Review (erledigt beim Schreiben)

- **Spec-Abdeckung:** Eingabeformat pro 100 g + Portion (Task 1/2), Ablehnen statt Klemmen (Task 2), explizite 0 kcal (Task 1/2), zwei Einstiege inkl. Vorbelegung und Fehler-Abgrenzung (Task 3/4), Recents/Pin ohne neuen Code (läuft über `_handleAdd` → `onAdd` → `_rememberRecent`, Flow-Test prüft das Tagestotal), i18n de+en (Task 1/2), deterministischer Coach-Slug + Ableitung + Regressionstest Neustart/Löschen (Task 5/6), Grenzfall Alt-Karten dokumentiert (kein Code nötig).
- **Typen konsistent:** `manualEntry`-Signatur (Task 1) == Aufruf im Sheet (Task 2); `showManualMealSheet` (Task 2) == Aufrufe (Task 3/4); `coachProposalSlug`/`toFitnessRecipe(slug:)` (Task 5) == Screen/Tests (Task 6).
- **Keine Platzhalter:** alle Code-Blöcke vollständig; keine „TBD"/„später".
