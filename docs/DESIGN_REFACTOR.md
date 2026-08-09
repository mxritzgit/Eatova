# Design-Refactor 2026-08-09 — Briefing für alle Screen-Pakete

Dieses Dokument ist der **Vertrag**. Sechs Screen-Pakete arbeiten parallel gegen
ihn. Wenn du hier etwas anderes liest als in deinem Auftrag: dieses Dokument
gewinnt. Wenn etwas fehlt: melde es in deinem Bericht, erfinde es nicht.

---

## 1. Was passiert hier

Die App bekommt eine neue Designsprache und einen **Hell-Modus**. Vorlage ist
`newScreen/nutrition_app(1).dart` (3126 Zeilen) — ein einzelner Entwurf mit
sechs Screens und einer kompletten Design-Schicht. Die Vorlage ist englisch,
zustandslos und arbeitet mit Demo-Daten. Unsere Aufgabe ist die Umkehrung:

> **Das Aussehen kommt aus der Vorlage. Die Logik kommt aus unserer App.
> Nichts an Funktion darf verloren gehen.**

Die Architektur ist bewusst zweischichtig:

- **Material 3 unten** — `Scaffold`, `Navigator`, `TextField`, `InkWell`,
  `showModalBottomSheet`, Ripple, Fokus, Screenreader, Scroll-Physik,
  Textskalierung. Das bauen wir nicht nach.
- **Eigene Widgets oben** — jede sichtbare Fläche. Farben ausschließlich aus
  `AppTokens`.

---

## 2. Entscheidungen (vom Nutzer bestätigt, nicht verhandelbar)

| Frage | Entscheidung |
|---|---|
| Navigation | **4 Tabs**: `Heute` · `Food` · `Rezepte` · `Coach` (in dieser Reihenfolge, Heute = Index 0) |
| Start-Modus | **`ThemeMode.system`** — die App folgt dem Gerät, bis jemand in den Einstellungen umschaltet |
| Umfang | **Alles** — die 6 Screens *und* alle Sheets/Dialoge des Alltags *und* das Onboarding |
| Sprache | **Deutsch.** Die Vorlage ist englisch; jeder Text wird übersetzt. Wo bereits ein deutscher Text existiert, bleibt er **wortgleich** (Tests hängen daran, s. §6) |
| Login/Registrieren/Passwort | **Nicht in dieser Runde.** `auth_screen.dart` und `auth_code_screen.dart` bleiben unangetastet |

> **Nachtrag 2026-08-09:** `lib/src/widgets/auth/welcome_screen.dart` ist
> **doch schon migriert** (er läuft nach dem Login, nicht davor — ein
> dark-only Splash wäre im Hell-Modus ein sichtbarer Bruch gewesen). Er ist
> fertig und gehört niemandem mehr. Besonderheit: Er folgt dem Anzeige-Modus
> bewusst NICHT, sondern bleibt in beiden Modi auf der Marken-Fläche
> (`forest`/`onForest`/`lime` sind in beiden Paletten kontrast-gesichert).
> Das ist Absicht und im Code begründet — bitte nicht „korrigieren".

---

## 3. Der Token-Vertrag

Alles liegt in `lib/src/theme/app_tokens.dart` und hängt als `ThemeExtension`
am Theme. Zugriff im `build()`:

```dart
import '../../theme/app_tokens.dart';
...
final t = context.t;
```

### Farben (`AppTokens`)

| Token | Rolle |
|---|---|
| `bg` | Seitengrund (Scaffold) |
| `surf` | Karten-/Panelfläche |
| `surf2` | zweite, abgesetzte Fläche (Banner, Bildplatzhalter) |
| `tile` | sehr schwache Füllung (Icon-Kacheln, Balkenspuren) |
| `line` | Trennlinien und Kartenränder, 1 px |
| `ink` / `ink2` | Haupttext / Sekundärtext + Icons |
| `forest` / `onForest` | dunkelgrüne Markenfläche + Text darauf |
| `lime` / `onLime` | Markenakzent + Text darauf (immer dunkel) |
| `accent` | Strich-/Füllfarbe für Grafiken **auf** einer Karte (dunkel: lime, hell: forest) |
| `protein` `carbs` `fat` | **nur** Nährwert-Kodierung |
| `snack` | vierte kategorische Farbe (Snack-Slot) |
| `danger` `warning` | **nur** Zustands-Signale |
| `shadowTint` | getönter Schatten, nie reines Schwarz |

### Form

`rChip`=11 · `rControl`=15 · `rCard`=22 · `rSheet`=28 · `rHero`=28 · `rPill`.
Wo die Vorlage einen anderen Wert nennt, gilt die Vorlage.

Achtung: Die Skala hat sich gegenüber `app_colors.dart` **verschoben**
(vorher `rChip`=8 · `rControl`=12 · `rCard`=16 · `rSheet`=24). Code, der die
Namen liest, wird dadurch still runder — das ist gewollt. Wo daneben eine
hartkodierte Zahl mitläuft (z. B. ein Ring um eine Kapsel), läuft sie jetzt
auseinander: solche Zahlen an die Skala koppeln, statt sie stehen zu lassen.

### Schrift

`AppType.display(size, {weight, color, letterSpacing, height})` — Bricolage
Grotesque, für Zahlen und Überschriften, tabellarische Ziffern.
`AppType.ui(...)` — Archivo, für alles Übrige.
`AppType.eyebrow(color, {size})` — kleine Versalien über Abschnitten.

Beide Familien liegen gebündelt unter `assets/fonts`. **Niemals `google_fonts`
importieren** — das wäre ein Laufzeit-Request an Google (Datenschutzerklärung)
und bricht offline.

### Drei harte Regeln

1. **`lib/src/theme/app_colors.dart` wird in neuem/angefasstem Code nicht mehr
   importiert.** Die Datei lebt nur noch, bis der letzte Import weg ist; sie
   wird am Ende gelöscht. Wenn du eine Datei anfasst, migriere ihre Farben.
   Übersetzungstabelle:
   `bg`→`t.bg` · `surface`→`t.surf` · `surfaceSoft`→`t.surf2` · `hairline`→`t.line`
   · `textPrimary`→`t.ink` · `textMuted`→`t.ink2` · `lime`→`t.lime` (Fläche) bzw.
   `t.accent` (Strich/Text auf Karte) · `macroProtein`/`cyan`→`t.protein`/`t.carbs`
   · `macroCarbs`→`t.carbs` · `macroFat`/`orange`→`t.fat` · `danger`→`t.danger`
   · `warning`→`t.warning` · `slotDinner`→`t.fat` · `wellnessTone`→`t.snack`
   · `forgeLime`/`forgeGlass*`→ entfallen (die Glaskarte weicht dem Forest-Hero)
   · `coachAccent`→`t.forest` (der Coach zieht in die Markenfarbe um)
   · `cardShadow`→`softShadow(t)`
2. **Keine hart geschriebene Farbe.** Kein `Color(0x...)` in Widget-Code.
3. **Kein `Theme.of(context).brightness`-Abzweig für Farben.** Wenn du in
   beiden Modi etwas anderes brauchst, gehört das als Token in `AppTokens` —
   melde es, dann ergänze ich es zentral.

### Anzeige-Modus lesen/schreiben

```dart
final controller = ThemeModeScope.maybeOf(context); // null außerhalb der App-Schale
controller?.mode;                 // ThemeMode
await controller?.setMode(ThemeMode.dark);
controller?.isDark(MediaQuery.platformBrightnessOf(context));
```

---

## 4. Die gemeinsame Widget-Bibliothek

`lib/src/widgets/design/` (Barrel: `design.dart`). **Nutze sie, statt Karten,
Zeilen, Schalter und Sheets erneut zu bauen.** Inhalt:

- `surfaces.dart` — `AppCard`, `ScreenTitle`, `SectionHeading`,
  `ImagePlaceholder`, `DottedAddSlot`
- `controls.dart` — `SquareIconButton`, `IconTile`, `AppToggle`,
  `SegmentedPill`, `FilterChipPill`, `PrimaryActionButton`, `AppNavBar`
- `rows.dart` — `PageHeader`, `SettingsGroup`, `SettingsRow`
- `sheets.dart` — `SheetScaffold`, `SheetField`, `showEatovaSheet`
- `meters.dart` — `TickGauge`, `MacroBar`, `MealAvatar`, `Sparkline`,
  `DotGridBackground`

Fehlt dir ein Baustein, den **mehrere** Screens brauchen: baue ihn dort,
nicht in deinem Screen. Brauchst nur du ihn: baue ihn in deinem Paket.

---

## 5. Bestehende Fakten, die du kennen musst

### Datenquellen (nicht ändern)

- `HomeStore` — alle Zustandsfelder sind **öffentliche mutable Felder**, kein
  Getter-Wall. Wichtige Members:
  `selectedFoodDate`, `selectedFoodDateIsToday`, `loggedMeals`,
  `mealsForFoodDate(d)`, `consumedKcalForFoodDate(d)`, `macroProgressForFoodDate(d)`,
  `isLoadingFoodDay(d)`, `profile`, `favorites`, `dailySteps`, `lifetimeStats`,
  `weightLog`, `userRecipes`, `selectedTab`, `setTab(i)`, `setFoodDate(d)`,
  `addResultToDailyTotal(...)`, `updateLoggedMealDetails(...)`,
  `removeLoggedMeal(id)`, `isFavorite(r)`, `toggleFavorite(r)`,
  `applySettings(...)`, `resetTodayData()`, `logWeight(kg)`, `coachContext`.
- **Makros pro Mahlzeit sind Strings** (`"24 g"`), nicht Zahlen —
  `MacroProgress` parst sie. Nicht selbst parsen, `MacroProgress` nutzen.
- **Verbrannte Kalorien** sind aus Schritten geschätzt
  (`estimateKcalBurnedFromSteps`) und an einem Nicht-Heute-Tag **hart 0** —
  das ist Absicht, die Karte zeigt dann „—".
- **Streak**: `lifetimeStats.effectiveStreakOn(now)` — nie `currentStreak`
  direkt anzeigen (gerissene Kette muss 0 ergeben).
- **Datums-Mathematik**: immer über `lib/src/services/day_math.dart`
  (`dayStrip`, `daysBetween`) bzw. die vorhandenen
  `foodDateStripDays`/`foodDateChipLabel`. **Niemals `Duration`-Arithmetik** —
  das war ein DST-Bug.

### Bewahrte Konstruktionen

- `MealEditScope` muss über der Verlaufsliste **und** über dem Öffner des
  Add-Sheets liegen; `showAddMealSheet` löst ihn **vor** dem Routenwechsel auf.
- **Verwerfen-Schutz** (`PopScope` + `_DiscardDragGuard` + Dialog
  `discard-changes-dialog`) existiert in `settings_sheet.dart`,
  `edit_meal_sheet.dart`, `recipe_create_sheet.dart`. Er bleibt erhalten.
- **`SecureScreenGuard`** umschließt Profil und Auth-Screens (Screenshot-/
  Recents-Schutz). Bleibt erhalten; neue Screens mit Gesundheitsdaten
  bekommen ihn.
- **A11y**: Textskalierung ist app-weit auf 2.0 gedeckelt.
  `test/text_scale_stress_test.dart` erzwingt Overflow-Freiheit. Feste Höhen
  und `Row`s ohne `Flexible` sind die häufigste Bruchstelle.
- `motionDuration(context, ...)` respektiert „Bewegung reduzieren" — für neue
  Animationen benutzen.

---

## 6. Tests sind API

132 Testdateien hängen an **`ValueKey`s** und an **wortgleichen deutschen
Texten**. Regel:

- **Key bleibt Key.** Ändere niemals einen bestehenden `ValueKey`, nur weil
  ein Widget umzieht. Der Key wandert mit.
- **Text bleibt Text**, solange die Bedeutung dieselbe ist. Ein Redesign ist
  kein Grund, „Verlauf" in „Heutige Mahlzeiten" umzubenennen.
- Ändert sich ein **Ablauf** wirklich (Sheet wird Seite, Tab kommt dazu),
  dann wird der Test **umgeschrieben, nicht gelöscht** — und im Bericht
  begründet.

Keys, die bestehen bleiben müssen (Auswahl):
`screen-kcal-tracker`, `kcal-page-fill`, `analyse-daily-kcal-card`,
`analyse-daily-kcal-total`, `kcal-meals-today-card`, `food-history`,
`food-history-entry-N`, `food-history-delete-N`, `food-date-strip`,
`food-date-selected-label`, `food-date-chip-N`, `food-date-chip-archive`,
`food-date-calendar`, `food-search`, `food-action-barcode`, `food-action-ai`,
`food-day-loading`, `topbar-trends`, `topbar-settings`, `topbar-profile`,
`nav-Food`, `nav-Rezepte`, `nav-Coach`, `screen-recipes`,
`recipes-search-input`, `recipes-search-clear`, `recipe-filter-*`,
`recipe-tile-*`, `recipe-detail-*`, `recipe-add-card`, `recipe-add-button`,
`recipe-meal-picker-*`, `recipe-create-*`, `recipe-goal-matches`,
`coach-empty`, `coach-ai-note`, `coach-input`, `coach-send`, `coach-mic`,
`coach-attach`, `coach-info`, `coach-info-sheet`, `coach-sessions-open`,
`coach-sessions-new`, `coach-quota-hint`, `coach-streak`, `coach-loading`,
`coach-message-list`, `coach-suggestion-N`, `screen-profile`, `profile-close`,
`profile-hero-*`, `profile-goalplan-edit`, `profile-edit-goals`,
`profile-log-weight`, `profile-health-refresh`, `profile-health-connect`,
`profile-action-edit`, `profile-action-reset`, `profile-action-export`,
`profile-action-about`, `profile-action-logout`, `profile-action-delete`,
`profile-privacy-link`, `profile-export-copy`, `confirm-delete-account`,
`settings-weight`, `settings-height`, `settings-age`, `settings-sex`,
`settings-activity`, `settings-target-weight`, `settings-weight-goal`,
`settings-weight-goal-effective`, `settings-manual-energy`, `settings-kcal`,
`settings-protein`, `settings-carbs`, `settings-fat`, `settings-steps-goal`,
`settings-water`, `settings-sleep-goal`, `settings-notifications`,
`settings-reminder-note`, `settings-open-system-settings`,
`settings-validation-note`, `settings-reset-day`, `settings-save`,
`settings-pace-warning`, `settings-privacy-link`, `settings-terms-link`,
`settings-imprint-link`, `target-bmi-hint`, `discard-changes-dialog`,
`add-meal-slot-select`, `slot-select-*`, `edit-slot-select-*`,
`edit-meal-sheet`, `edit-day-chip-*`, `edit-day-calendar`,
`edit-meal-adjust-button`, `analyse-result-card`, `analyse-item-breakdown`,
`analyse-add-daily-button`, `analyse-adjust-button`, `analyse-existing-*`,
`kcal-product-search-input`, `kcal-product-suggestion-*`.

Texte, die wortgleich bleiben (Auswahl): „Verlauf", „Ernährung",
„Noch nichts geloggt", „Tag wird geladen…", „Heute" / „Gestern" /
„Vor N Tagen", „Profil & Ziele", „Mein Profil", „Rezepte", „Treffer",
„Frühstück" / „Mittagessen" / „Abendessen" / „Snacks", das Makro-Balken-Format
`0/130g`, die kcal-Formatierung mit Tausenderpunkt (`2.200 kcal`), alle
Validierungs-Bereichstexte („30–300 kg (ganze Zahl)", „100–250 cm",
„16–100 Jahre", „1000–100000", „500–12000 ml", „800–7000 kcal", „0–400 g",
„0–800 g", „0–300 g", „Bitte ausfüllen"), die drei Erinnerungs-Zustandstexte,
die Coach-Offenlegungstexte.

---

## 7. Arbeitsweise (für jedes Paket gleich)

1. **TDD.** Neues Verhalten: erst Test, RED sehen, dann Code. Reines Umstylen
   braucht keinen neuen Test, muss aber die bestehenden grün lassen.
2. **Immer beide Modi prüfen.** Mindestens ein Widget-Test pro Screen pumpt
   ihn unter `buildEatovaTheme(Brightness.light)` **und** `(Brightness.dark)`.
3. **Nur deine Dateien.** Wer welche Datei besitzt, steht in deinem Auftrag.
   `lib/src/app/eatova_home_page.dart`, `eatova_app.dart`,
   `lib/src/theme/*` und `lib/src/widgets/design/*` gehören **niemandem** von
   euch — Änderungswünsche daran gehen in den Bericht.
4. **Befehle** immer mit vollem Pfad:
   `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat`.
   **Niemals `flutter pub get`.** Niemals committen, niemals branchen.
5. **Abschluss-Pflicht**: `flutter analyze <deine Pfade>` ohne Fehler/Warnungen
   **und** `flutter test <deine Testdateien>` grün. Wenn ein bestehender Test
   rot ist und du ihn nicht ehrlich reparieren kannst: **melde ihn**, statt ihn
   zu löschen oder `skip` zu setzen.

---

## 8. Paketzuschnitt

| # | Paket | Besitzt |
|---|---|---|
| 1 | **Heute** | `lib/src/screens/today/**` (neu) |
| 2 | **Food** | `lib/src/screens/meal_analysis_screen.dart`, `lib/src/widgets/kcal/**`, `lib/src/widgets/meal/**`, `lib/src/screens/barcode_scanner_sheet.dart`, `lib/src/screens/meal_camera_sheet.dart` |
| 3 | **Rezepte** | `lib/src/screens/recipes/**` |
| 4 | **Coach** | `lib/src/screens/coach/**` |
| 5 | **Profil** | `lib/src/screens/profile_screen.dart`, `lib/src/widgets/profile/**`, `lib/src/screens/trends_screen.dart` |
| 6 | **Einstellungen** | `lib/src/screens/settings/**` (neu), `lib/src/widgets/shared/**`, `lib/src/screens/onboarding_screen.dart` |

Gemeinsam genutzte Kleinteile (`lib/src/widgets/common/**`) migriere ich
zentral.
