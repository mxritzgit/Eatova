# Eatova — Snackbar-Toasts kürzen & polieren

**Datum:** 2026-06-02
**Status:** Genehmigt (autonom, im Auftrag des Users — Goal-Modus, „lass dir was
einfallen", AFK).
**Scope:** Frontend-only (Flutter). Kein Backend/Deploy.

## Problem

Snackbars (Mahlzeit hinzugefügt, Favorit entfernt, …) bleiben zu lange sichtbar
und gingen teils „auch nach 30 s nicht weg". Ursache verifiziert: die meisten
`ScaffoldMessenger.showSnackBar(...)`-Aufrufe zeigen ohne vorheriges
`removeCurrentSnackBar()` → Snackbars **stapeln** sich in der Queue (je 4 s
Default). Mehrere schnelle Adds ⇒ 20–30 s Warteschlange.

## Entscheidung

**Ein zentraler Helfer `showAppSnack()`** (`lib/src/widgets/common/app_snack.dart`),
durch den ALLE Snackbars laufen:
- ruft IMMER `removeCurrentSnackBar()` vor `showSnackBar()` → **kein Stapeln** mehr
  (Kern-Fix);
- kurze Default-Dauern: `kSnackShort` 1,6 s (Bestätigung), `kSnackAction` 3,2 s
  (mit Undo-Aktion), `kSnackError` 3,2 s;
- floating (aus dem bestehenden `snackBarTheme`), optionales Leading-Icon mit
  kurzem `easeOutBack`-Scale-Pop (die „kleine Animation");
- optionale `SnackBarAction`.

Alternativen verworfen: nur Dauer kürzen (löst das Stapeln nicht); pro-Call
`removeCurrentSnackBar` einzeln einstreuen (unzuverlässig, leicht vergessen).

## Änderungen

1. **Neu** `app_snack.dart`: `showAppSnack(context, msg, {icon, accent, action,
   duration})` + Dauer-Konstanten + `_SnackIcon` (TweenAnimationBuilder-Pop).
2. **Alle Snackbar-Call-Sites** auf `showAppSnack` umstellen (Nachrichten-Strings
   UNVERÄNDERT, damit die `find.text(...)`-Test-Pins halten):
   - Hinzufügen (`add_meal_sheet._handleAdd`, `meal_analysis_sheet`,
     `recipes_screen._add`): Check-Icon (lime), `kSnackShort`.
   - Löschen/Undo (`shiftfit_home_page._showUndoSnackBar` für Mahlzeit + Favorit):
     Papierkorb-Icon (danger) + „Rückgängig", `kSnackAction`.
   - Fehler (`_reportSyncError`): Error-Icon (danger), `kSnackError`.
   - Übrige (Plan abgehakt, Tagesreset, Profil-Sync, today/profile/day_summary):
     durch den Helfer, für einheitlich kurzes Verhalten.
3. **Favorit-Löschen „nice"**: `add_meal_sheet` umschließt den Favoriten-/Treffer-
   Bereich mit `AnimatedSize` (≈220 ms) → die Liste fällt beim Entfernen sanft
   zusammen statt hart zu springen. Plus der Undo-Toast (Punkt 2).

## Nicht-Ziele
- Kein Custom-Overlay-Toast-System (YAGNI; SnackBar reicht).
- Keine Nachrichten-Text-Änderung (Test-Pins).

## Tests / Verifikation
- Bestehende Snackbar-`find.text`-Pins (Rezept→„590 kcal zu Mittagessen
  hinzugefügt.", Slot-Test) bleiben grün, da `find.text` den Text-Descendant im
  Row weiterhin findet und die Strings unverändert sind.
- Lokal: `flutter analyze` → 0, `flutter test` → alle grün. Danach commit + push.
