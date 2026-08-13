# Manueller Mahlzeiten-Eintrag + /recipe-„Hinzugefügt"-Fix — Design

Stand: 2026-08-13 · Status: vom Nutzer freigegeben

## Ziel

Zwei Punkte aus Nutzer-Feedback:

1. **Manueller Eintrag:** Barcode, KI-Scan und OFF-Suche decken Produkte mit
   Datenbank-Eintrag ab — der Mozzarella vom Bauern mit eigenem Etikett hat
   keinen Weg ins Tagebuch. Es braucht ein Formular für eigene Nährwerte.
2. **Bugfix:** Die /recipe-Vorschlagskarte im Coach vergisst nach App-Neustart
   ihren „Hinzugefügt"-Zustand und bietet das Rezept erneut an, obwohl es noch
   im Rezepte-Tab existiert.

## Entscheidungen (mit Nutzer geklärt, 2026-08-13)

* **Eingabeformat:** pro 100 g (wie auf dem Etikett) + gegessene Portion in
  Gramm — die App rechnet die Portionswerte aus.
* **Wiederverwendung:** über das bestehende Recents/Favoriten-System
  (`_rememberRecent` beim Loggen, Pin im Add-Sheet). KEIN eigener Katalog,
  keine neue Tabelle.
* **Einstiege:** viertes Header-Icon (Stift) im Add-Meal-Sheet neben
  Kamera/Galerie/Barcode, PLUS „Manuell eintragen"-CTA unter dem
  „nichts gefunden"-Hinweis der Produktsuche (übernimmt den Suchbegriff als
  Namens-Vorbelegung).
* **Bugfix-Ansatz:** deterministischer Rezept-Slug `user_coach_<messageId>`
  statt Zufalls-Slug; der „Hinzugefügt"-Zustand wird damit eine reine
  Ableitung aus den Live-Slugs. Verworfen: Map lokal persistieren (bliebe
  gerätelokal), `source_message_id`-Spalte (Migration für einen
  Anzeige-Check überdimensioniert).

## Teil 1: Manueller Eintrag

### Neues Sheet `lib/src/widgets/kcal/manual_meal_sheet.dart`

Formular-Sheet im Stil von `recipe_create_sheet` (rahmenlose
Soft-Kapsel-Inputs, Fokus = Flächen-Aufhellung; Design-Feedback-Regel).
`showManualMealSheet(context, {initialName})` liefert ein
`MealAnalysisResult?` zurück; der Aufrufer (Add-Meal-Sheet) loggt es über den
bestehenden `onAdd`-Pfad in den aktuell gewählten Slot.

**Felder:**

| Feld | Pflicht | Regel |
| --- | --- | --- |
| Name | ja | nicht leer, `clampMealName`-Grenze |
| kcal pro 100 g | ja | 0..900 (`isPlausibleKcalPer100G`; 0 erlaubt, s. u.) |
| Portion (g) | ja | 1..10000, Default 100 |
| Protein / Kohlenhydrate / Fett pro 100 g | nein | je 0..1000 g, leer = unbekannt („-") |

Unter den Feldern live die errechnete Portion („= 438 kcal"). Der
Speichern-Button ist erst aktiv, wenn alle Pflichtfelder gültig sind —
**Ablehnen statt Klemmen**: ungültige Menschen-Eingaben werden nie still
korrigiert (Regel aus dem Rezept-Formular; Klemmen ist nur für KI-Antworten
richtig).

### Ergebnis-Konstruktion

Ein normales `MealAnalysisResult`, kein neuer Persistenz-Pfad:

* `mealName` = Name; `kcalPer100G` = Eingabe; `estimatedGrams` = Portion;
  `caloriesKcal` = `round(kcal100 × g / 100)` (geklemmt).
* Makros: pro Portion umgerechnet und wie `_macroForGrams` formatiert;
  leere Felder → `-` (Makro unbekannt, nichts Erfundenes in den Tagesringen).
* `explicitZeroKcal = true` genau dann, wenn der Nutzer 0 kcal/100 g
  eingetragen hat — eine bewusste 0 (Wasser, Zero) ist eine Messung, die
  Log-Bremse (`_handleAdd`/B7) lässt sie durch. Für Alt-Sentinels ändert sich
  nichts.
* `items` leer, `barcode`/`brand` null, `isAdjusted` false.

### Neue Herkunfts-Codes (Enum-Muster aus dem Scan/Coach-PR)

* `MealResultSource.manual` — Persistenz-Code `manual`, Anzeige de „Manuell" /
  en „Manual".
* `MealResultConfidence.manual` — Code `manual`, Anzeige de „Eigene Angabe" /
  en „Own entry".
* Vierter `MealResultPortionNote`-Marker (Code `manualEntryNote`) für die
  Hinweiszeile („Nährwerte manuell nach Etikett eingetragen …" / en-Pendant).
* Alle drei mit `legacyDe` = deutschem Anzeigetext (reine Resolve-Aliase, es
  gibt keine Alt-Zeilen). `sourceLabel` ≤ 80 Zeichen hält — **keine
  DB-Migration**.

### Einstiege im Add-Meal-Sheet (`add_meal_sheet.dart`)

1. **Header:** viertes `_HeaderIconButton` (Stift, `ValueKey`
   `manual-entry-button`) neben Kamera/Galerie/Barcode; nur im normalen
   Add-Modus (im `searchMode` bleibt der Kopf wie bisher schlank).
2. **Such-CTA:** unter dem „nichts gefunden"-Hinweis (`_HintBlock` im
   No-Results-Fall, NICHT bei Fehlern/Min-Zeichen-Hinweis) ein Button
   „Manuell eintragen", der das Formular mit dem Suchbegriff als Name öffnet.

Nach dem Speichern läuft der bestehende Weg: `onAdd(result, _selectedSlot)`
→ Logging + Outbox/Sync + Erfolgs-Snack + `_rememberRecent` (Recents/Pin —
damit ist der Bauern-Mozzarella beim nächsten Mal sofort wieder da).

### i18n

Neue ARB-Keys (de+en): Sheet-Titel, Feld-Labels/Hints, Validierungsfehler,
Tooltip Header-Icon, Such-CTA, Quellen-/Confidence-/Notiz-Texte. Kein
hartkodiertes Deutsch in neuen UI-Pfaden (Wächter-Test bleibt grün).

## Teil 2: /recipe-Karte — „Hinzugefügt" übersteht den Neustart

### Ursache

`coach_chat_screen.dart:132` hält `_createdRecipeSlugByMessage` als
In-Memory-Map; das gespeicherte Rezept bekommt einen Zufalls-Slug
(`FitnessRecipe.userRecipeSlug()` = `user_<ms>`). Die Reload-Karte (PR #36)
rekonstruiert das Proposal aus `chat_messages.recipe`, aber die Verbindung
Message → Slug ist nach dem Neustart weg — `_isRecipeAdded` läuft ins Leere
und die Karte bietet erneut „Hinzufügen" an.

### Fix

* Neuer Helfer `FitnessRecipe.coachProposalSlug(String messageId)` →
  `user_coach_<messageId>`; `CoachRecipeProposal.toFitnessRecipe` erhält den
  Slug vom Aufrufer (Message-Id der Karte).
* `_isRecipeAdded(message)` wird eine reine Ableitung:
  `message.recipeProposal != null &&
  userRecipeSlugs.contains(coachProposalSlug(message.id))`.
  Die Map `_createdRecipeSlugByMessage` entfällt ersatzlos.
* Slug-Spalte ist `text not null` mit Unique `(user_id, slug)` — kein
  Format-Constraint, UUID-Länge unkritisch, kein Server-Touch.

### Eigenschaften

* Übersteht Neustart UND synct aufs Zweitgerät (Slugs kommen live aus
  `user_recipes` über den bestehenden `userRecipeSlugs`-Selector).
* Löschen im Rezepte-Tab reaktiviert den Button weiterhin von selbst.
* Doppel-Tap wird idempotent: Upsert-Konfliktschlüssel `(user_id, slug)`
  fängt Duplikate ab (bisher entstand ein zweites Rezept).
* Lokale Fallback-Ids (`local-r-<ts>`, wenn die Function keine
  `assistant_message_id` lieferte) funktionieren in der Session; nach Reload
  trägt die Nachricht die Server-Id und der Zustand ist wieder „nicht
  hinzugefügt" — derselbe degradierte Pfad wie heute, ohne Bild, akzeptiert.

### Bekannter Grenzfall

Rezepte, die VOR diesem Fix aus Karten erzeugt wurden, tragen Zufalls-Slugs —
deren Karten zeigen nach dem Update einmalig wieder „Hinzufügen" (Verhalten
wie heute, kein Datenverlust). Keine Rückwärts-Zuordnung nötig.

## Fehlerbehandlung

* Formular: Ablehnen mit Feld-Fehlertext; Speichern-Button bleibt bis zur
  Gültigkeit deaktiviert. Kein stilles Korrigieren.
* Logging-Pfad unverändert (DATA-7: kein Rollback, Outbox holt nach).
* Coach-Pfad unverändert (`_addingRecipe`-Sperre, Ausgangs-Snack über
  `deliveryHint`).

## Tests

* **Formular:** Pflichtfeld-Ablehnung (leerer Name, 0 g, > 900 kcal/100 g),
  Portions-Berechnung inkl. Makros, 0-kcal-Wasser → `explicitZeroKcal` und
  loggbar, leere Makros → „-".
* **Einstiege:** Header-Icon öffnet Formular; leere Suche zeigt CTA; CTA
  übernimmt Suchbegriff; Fehler-/Min-Zeichen-Hinweis zeigt KEINEN CTA.
* **Ergebnis:** Quelle/Confidence/Notiz lokalisiert aufgelöst (de+en),
  Persistenz-Roundtrip über `mealResultToJson`.
* **Coach-Karte:** Screen-Neuaufbau mit deterministischem Slug in
  `userRecipeSlugs` → Karte zeigt „Hinzugefügt" (Neustart-Simulation);
  Slug fehlt → Button aktiv; bestehende Flow-Tests auf den neuen Slug
  angepasst.
