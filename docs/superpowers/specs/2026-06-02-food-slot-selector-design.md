# Eatova — Mahlzeit-Slot im Food-Add-Flow wählbar machen

**Datum:** 2026-06-02
**Status:** Genehmigt (autonom, im Auftrag des Users freigegeben — User ist AFK,
hat delegiert: „treffe die Entscheidungen selbst … Brainstorme und setze das um").
**Scope:** Slot-Auswahl im manuellen Food-Add-Flow. Keine Backend-/Modell-Änderung
(Datenschicht trägt `forcedSlot` bereits), keine Design-Sprache-Änderung.

## Problem

Im Food-Tab kann der User beim manuellen Hinzufügen (Suche, Barcode, KI-Scan,
Schnell hinzufügen) **nicht wählen**, ob die Mahlzeit Frühstück / Mittag / Abend /
Snack ist. Der Slot wird still aus der Uhrzeit geraten (`_heuristicSlot()` in
`meal_analysis_screen.dart`) und dem User nur per Snackbar mitgeteilt. Er soll ihn
selbst festlegen können.

## Ist-Analyse (gegen den echten Code)

Datenpfad eines manuell hinzugefügten Eintrags:

1. `MealAnalysisScreen._FoodAddBlock` → `_openAddSheet(context, _heuristicSlot(),
   searchMode: …)` — der Slot ist ein **Uhrzeit-Rateergebnis**, fix.
2. `showAddMealSheet(slot: …)` → `AddMealSheet.widget.slot` (unveränderlich).
3. Hinzufügen (`_handleAdd`, Foto `_pickAndAnalyze`, Barcode `_scanBarcode`) ruft
   `onAdd(result, widget.slot)`.
4. `onAddMeal` → `_addResultToDailyTotal(result, slot: slot)` →
   `LoggedMeal(forcedSlot: slot)`.
5. `meals_sync.insertLoggedMeal` persistiert `forced_slot`.

Befunde:

- **Die Datenschicht ist fertig.** `LoggedMeal.forcedSlot` (`MealSlot?`) existiert,
  `LoggedMeal.slot` nutzt `forcedSlot` wenn gesetzt, sonst die Uhrzeit-Heuristik.
  `meals_sync` liest/schreibt `forced_slot`. **Kein Modell-/DB-/Sync-Change nötig.**
- **Es gibt schon ein Slot-Picker-Muster.** `recipes_screen.dart` hat
  `_MealSlotPickerSheet` + `_MealSlotButton` (Farben/Icons pro Slot:
  Frühstück=orange/Sonne, Mittag=lime/Tag, Abend=slotDinner/Mond, Snack=cyan/Keks).
  Beim Rezept-Hinzufügen ist der Slot also bereits wählbar — der manuelle Food-Flow
  ist die einzige Inkonsistenz.
- **`AddMealSheet` behandelt den Slot als fixen Input** (`widget.slot`), nicht als
  Zustand. Der `searchMode`-Header zeigt gar keinen Slot („Lebensmittel suchen").
- **Feedback-Memory `feedback-slot-tap-add-sheet`:** Add-Flows laufen über
  **ein** Bottom-Sheet — kein „erst ein Screen zum Wählen, dann ein zweiter zum
  Bestätigen", kein FAB, alles in einem Sheet. Ein separates Picker-Sheet *vor*
  der Suche wäre also falsch.

## Entscheidung (selbst getroffen)

**Inline-Slot-Selector im `AddMealSheet`** statt eines vorgeschalteten Picker-Sheets
— ein kompaktes 4er-Segmented-Control direkt unter der Suchleiste, immer sichtbar.
Der Slot wird damit zu Sheet-Zustand (`_selectedSlot`), Default = der bisher
übergebene Heuristik-Slot (smarter Vorschlag, aber sichtbar änderbar).

Begründung der Alternativen-Abwägung:

- **A — Inline-Segmented-Control im Sheet (gewählt).** Erfüllt das
  „alles in einem Sheet"-Feedback, kein zweites Sheet, smarter Default bleibt
  erhalten, minimaler Eingriff (nur `AddMealSheet` + ein Aufruf-Argument). Spiegelt
  die Slot-Farben/Icons des Rezept-Pickers → konsistent.
- **B — Vorgeschaltetes Picker-Sheet wie bei Rezepten.** Verstößt gegen das
  Ein-Sheet-Feedback („nicht erst wählen, dann bestätigen"), zwei Modals, mehr Taps.
  Verworfen.
- **C — Slot erst nachträglich am Verlaufseintrag ändern.** Löst die Beschwerde
  nicht (User will *beim Hinzufügen* wählen), versteckte Funktion. Verworfen.

## Geplante Änderungen (additiv, test-sicher)

### 1. `lib/src/widgets/kcal/add_meal_sheet.dart`

- `_selectedSlot` als `State`, init `= widget.slot`.
- Neuer privater `_SlotSelector` (4 Segmente, je Icon + Kurzlabel, gewählter Slot
  in Slot-Akzentfarbe; Kurzlabels: „Frühstück / Mittag / Abend / Snack"). Keys
  `slot-select-breakfast|lunch|dinner|snack`, Container-Key `add-meal-slot-select`.
  Platz: feste Zeile zwischen `_SearchBar` und dem scrollbaren `Flexible` →
  immer sichtbar, scrollt nicht weg.
- Alle Slot-Verbraucher im Sheet von `widget.slot` → `_selectedSlot`:
  `_handleAdd` (`onAdd` + Snackbar-Label), `_pickAndAnalyze`/`_scanBarcode`
  (`showMealAnalysisSheet(slot: _selectedSlot)`), `_SheetHeader` (Titel/Icon im
  Nicht-Such-Modus reagiert auf `_selectedSlot`).
- **Existierende-Mahlzeiten-Liste reaktiv:** `widget.existingMeals` enthält künftig
  alle Einträge des angezeigten Tages; das Sheet filtert für die Anzeige nach
  `_selectedSlot`. So zeigt der Kopfbereich immer die Einträge des aktuell
  gewählten Slots — kein Mismatch „Liste zeigt Frühstück, Selector steht auf Mittag".
  Entfernen (`_removeExisting`) arbeitet weiter per `id` auf der vollen Tagesliste.

### 2. `lib/src/screens/meal_analysis_screen.dart`

- `_openAddSheet`: statt `searchMode ? [] : slot-gefiltert` künftig **alle Einträge
  des `selectedDate`** als `existingMeals` übergeben (Sheet filtert selbst nach Slot).
  `_heuristicSlot()` bleibt als Default-Slot der Launcher (smarter Vorschlag).

### Nicht angefasst

- `LoggedMeal`, `meals_sync`, DB-Migrationen, `_addResultToDailyTotal` — Slot fließt
  unverändert als `forcedSlot` durch.
- `recipes_screen._MealSlotPickerSheet` — eigener, schon korrekter Flow.
- Bestehende Test-Pin-Keys (`food-search`, `food-action-*`,
  `kcal-product-search-input`, `favorite-tile-*`, `recipe-meal-picker-*`) bleiben.

## Nicht-Ziele

- Kein 5. Slot „Nacht" (Modell hat 4; Spät-Abend fällt heute in `snack`). Out of
  scope — würde alle slot-gruppierenden Widgets berühren.
- Kein freies Datum/Uhrzeit-Picken pro Mahlzeit (Tag wird über den Date-Strip
  gewählt, das genügt).
- Kein State-Management-Umbau.

## Tests

- **Neu (`test/widget_test.dart`):** Pumpt `AddMealSheet` isoliert mit *einer*
  Favoriten-Mahlzeit (netzfreier Pfad, keine Suche/kein Service-Call), Default-Slot
  `breakfast`. Verifiziert: 4 Slot-Chips vorhanden; Default = breakfast; nach Tap
  auf `slot-select-dinner` + Hinzufügen der Favoriten-Kachel erhält der `onAdd`-
  Callback `MealSlot.dinner` (nicht den Default). Sperrt die Kern-Regel „gewählter
  Slot wird geehrt" netzunabhängig fest.
- **Bestehende Pins** (Food-Tab-Render, Rezept→Mittagessen-Snackbar) bleiben grün.

## Verifikation

Lokal vor Commit: `flutter analyze` → 0 Issues, `flutter test` → alle grün
(SDK `C:\Users\morit\Desktop\Flutter\flutter`). Diffs fokussiert halten — KEIN
blanket `dart format` (siehe [[reference-flutter-sdk]]). Danach commit + push `main`.

## Follow-ups (offen, nicht in diesem Durchlauf)

- Optional: Slot eines bereits geloggten Eintrags nachträglich umhängen (long-press
  im Verlauf). Separates kleines Feature, hier nicht nötig.
