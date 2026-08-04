# Eatova — Verlauf im Food-Tab per Swipe löschen

**Datum:** 2026-06-02
**Status:** Genehmigt (autonom, im Auftrag des Users freigegeben — User ist AFK,
Goal: „von rechts nach links swipen → Lösch-Symbol → nach Drücken Verlauf direkt
aktualisieren … denke nach wie du das am besten umsetzt").
**Scope:** Swipe-to-delete-Affordanz auf den Verlauf-Zeilen. Keine Backend-/Modell-
Änderung — die Lösch-Logik existiert bereits und aktualisiert sofort.

## Problem

Im Food-Tab kann man einen Verlauf-Eintrag heute nur **indirekt** löschen: Zeile
tippen → Add-Sheet öffnet sich → in der „bereits geloggt"-Liste den X-Button
drücken. Gewünscht: direkt auf der Verlauf-Zeile **von rechts nach links swipen**,
ein **Lösch-Symbol** erscheint, nach **Drücken** verschwindet der Eintrag sofort
und Kalorien/Makros aktualisieren direkt.

## Ist-Analyse (gegen echten Code)

- **Verlauf** = `MealsTodayCard` (`lib/src/widgets/kcal/calories_overview_card.dart`,
  ab Z. 876). Rendert `ListView.builder` → `_HistoryEntry` (ein `InkWell` mit
  `onTap → onMealTap(slot)`). Bekommt aktuell **nur** `meals` + `onMealTap`,
  **keinen** Lösch-Callback.
- **Lösch-Logik existiert + ist sofort:** `_removeLoggedMeal(id)` in
  `shiftfit_home_page.dart` macht synchron `setState` (entfernt aus `loggedMeals`,
  rechnet `dailyConsumedKcal` + `macroProgress` neu) und feuert danach den async
  Supabase-Delete. Sie ist als `onRemoveMeal` schon bis `MealAnalysisScreen`
  verdrahtet, wird dort aber nur ans Add-Sheet weitergereicht — **nicht** an die
  Verlauf-Karte.
- **Kein Swipe-Muster im Repo** (kein `Dismissible`, keine Slide-Lib).

→ Der gesamte „direkt updaten"-Teil ist schon erledigt. Es fehlt nur: `onRemoveMeal`
in die `MealsTodayCard` durchreichen + eine Swipe-Affordanz pro Zeile.

## Entscheidung (selbst getroffen)

**`flutter_slidable` (4.0.3)** mit `endActionPane` + `SlidableAction` („Löschen",
rot, Papierkorb-Icon), ausgelöst durch Rechts-nach-links-Swipe; Tap auf die Aktion
ruft den bestehenden `onRemoveMeal(meal.id)` → sofortiges Update.

Alternativen-Abwägung:

- **A — `flutter_slidable` (gewählt).** Liefert **exakt** das beschriebene Muster:
  Swipe enthüllt eine **antippbare** Lösch-Schaltfläche (iOS-Mail-Stil). Standard-
  Paket für genau diesen UX-Fall, Dart 3.6+/Flutter 3.27+ → mit lokalem SDK
  (3.12/3.44) kompatibel, null-safe, aktiv gepflegt. Kosten: eine reine-Dart-
  Dependency (kein Native-Plugin → kein `pub get`-Symlink-Problem).
- **B — eingebautes `Dismissible` (verworfen).** Null Dependencies, aber semantisch
  **Full-Swipe-zum-Wegwischen** statt „Symbol erscheint, dann drücken". Das
  Lösch-Icon ist nur Hintergrund während der Geste, es gibt **keinen Druck-Schritt**
  — widerspricht der ausdrücklichen Beschreibung („nachdem das gedrückt wurde").
- **C — Eigene Stack/Gesture-Reveal-Lösung (verworfen).** Reproduziert flutter_
  slidable von Hand → mehr Code, mehr Fehlerflächen, kein Gewinn.

## Geplante Änderungen (additiv, test-sicher)

### 1. `pubspec.yaml`
- `flutter_slidable: ^4.0.3` unter `dependencies`.

### 2. `lib/src/widgets/kcal/calories_overview_card.dart` (`MealsTodayCard`)
- Neuer Param `final ValueChanged<String>? onRemoveMeal;`.
- Jede Verlauf-Zeile in `Slidable` (Key `ValueKey(meal.id)` — stabile Identität)
  mit `endActionPane: ActionPane(motion: DrawerMotion(), extentRatio: ~0.28,
  children: [SlidableAction(onPressed: → onRemoveMeal(meal.id), Icon
  delete_outline_rounded, Label „Löschen", rot/weiß)])`. Nur wenn `onRemoveMeal`
  non-null; sonst unveränderte Zeile.
- `_HistoryEntry` behält Key `food-history-entry-$index` (Test-Pin, Drag-Ziel) +
  `onMealTap` bleibt (Tap zum Öffnen koexistiert mit Swipe).
- ListView in `SlidableAutoCloseBehavior` (offene Zeile schließt, wenn eine andere
  geöffnet wird).

### 3. `lib/src/screens/meal_analysis_screen.dart`
- `MealsTodayCard(..., onRemoveMeal: onRemoveMeal)` durchreichen.

### Nicht angefasst
- `_removeLoggedMeal`, `meals_sync`, Modell — Lösch-/Update-Pfad bleibt wie er ist.
- Das Add-Sheet (X-Button-Löschen) bleibt zusätzlich erhalten (zweiter Weg, schadet
  nicht).

## Nicht-Ziele
- Kein „Rückgängig"/Undo-SnackBar (nicht verlangt; YAGNI). Lösch-Bestätigung
  ebenfalls nicht — die Geste ist bewusst (Swipe + Tap).
- Keine Swipe-Aktionen außer Löschen.

## Tests
- **Neu (`test/widget_test.dart`):** Eintrag via Suche hinzufügen (vorhandenes
  Fake-Muster) → Verlauf-Zeile per `drag(Offset(-300,0))` öffnen → „Löschen"-Aktion
  tippen → Zeile weg (`food-history-entry-0` findsNothing) **und** Tages-kcal zurück
  auf `0 kcal`. Beweist Swipe-Reveal **und** sofortiges Update.
- **Bestehende Pins** (Food-Add, Slot-Selector, Rezept) bleiben grün.

## Verifikation
Lokal vor Commit: `flutter pub get` (Dart-VM, slidable ist pure Dart), dann
`flutter analyze` → 0 Issues, `flutter test` → alle grün (SDK
`C:\Users\morit\Desktop\Flutter\flutter`). KEIN blanket `dart format` (siehe
[[reference-flutter-sdk]]). Danach commit + push `main` (Token aus
`Bridgespace\.env`, braucht Contents:write — siehe [[reference-shiftfit-repo]]).
