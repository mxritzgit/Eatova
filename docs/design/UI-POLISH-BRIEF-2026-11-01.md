# UI-Polish-Brief Eatova, 2026-11-01

Stand: `main` @ `138f0046` (#174). Flutter 3.47.2 lokal und in CI. Autor: UI-Agent 1 (Recherche und Brief, ohne Code-Änderung).
Leser: Agent 2 (Basis-Schicht) und die Agents 3 bis 10 (Screens). Wer hier etwas anderes liest als im eigenen Auftrag, folgt diesem Brief. Fehlt etwas, steht es in eurem Bericht. Erfindet nichts.

Ziel des Owners: Die App soll „einfach schön" werden. Keine generischen Buttons, schöne Aufzählungen und Listen, harmonische und schlichte Icons. Das Grundprinzip des bestehenden Designs bleibt.

**Reihenfolge:** Agent 2 baut die Basis-Schicht. Sie wird gemergt, erst dann starten die Agents 3 bis 10 parallel, jeder in einem eigenen Worktree auf dem neuen `main`. Zehn Feature-Branches `build/2026-11-01-*` sind gerade offen (Kochmodus, Wochenplan, Training, First Entry, Portionsbasis usw.). Die UI-Runde setzt auf `main` auf, **nachdem** diese gemergt sind. Wer früher startet, rebased vor der Abgabe. Konfliktzonen am 2026-11-01: `screens/today/today_screen.dart` (first-entry), `screens/recipes/recipe_create_sheet.dart` (servings-basis), `widgets/meal/meal_widgets_*.dart` und `widgets/kcal/existing_meals_list.dart` (ci-tests-texts), beide ARB-Dateien (mehrere Branches).

---

## 0. Die Entscheidungen auf einen Blick

1. **Ein Icon-System:** Material Symbols Rounded als Kontur (FILL 0, wght 400), gefüllt nur für einen Zustand (FILL 1), über eine semantische Konstantenschicht `AppIcons`. Neue Abhängigkeit `material_symbols_icons` (Owner-Freigabe nötig, siehe Abschnitt c). Die eigenen Strich-Glyphen der Tab-Wurzeln bleiben.
2. **Eine Button-Familie mit fester Hierarchie:** Lit (eine pro Ansicht), Tonal, Leise, Text, Destruktiv und **ein** Icon-Button-Widget mit drei Größen. Dazu ein gemeinsamer Stepper. Damit fallen 20 rohe `IconButton`, 8 private Rundbuttons und 11 private Stepper weg.
3. **Eine Listen-Anatomie:** `ListSection` plus `ListRow` ersetzen die zwei parallelen Systeme (`SettingsGroup/Row` und `SettingsStudioGroup/Row`). Trenner beginnen an der Textspalte, und der Chevron folgt einer festen Regel.
4. **Echte Aufzählungs-Widgets:** `BulletList`, `NumberedSteps` und `StepNumber` kommen aus `recipe_sections.dart` in die Design-Bibliothek. Es gibt nur noch einen Nummernstil statt vier.
5. **Kleine, feste Skalen:** sechs Icon-Größen (statt 17), drei Icon-Badge-Größen (statt sieben), benannte Typo-Rollen mit **11 px Minimum**, ein Status-Pill statt 18 privater Pill-Klassen. Leere Zustände, Laden und Fehler laufen ausschließlich über `CalmState`, `Skeleton*`, `AppSpinner` und `SignalNote`.

---

## 1. Bestandsaufnahme (Zahlen, `datei:zeile`)

Gezählt mit `grep` und einem Python-Parser über `lib/src/**` (ohne generierte l10n). Die Zahlen gelten für `138f0046`.

### 1.1 Buttons

| Art | Aufrufe | Dateien | Bemerkung |
|---|---:|---:|---|
| `PrimaryActionButton` | 54 | 44 | lit, 54 px (in Karten 48 px über `height:`), `busy`, `destructive` |
| `SoftPillButton` | ≈125 | 63 | Töne accent/neutral/danger/quiet, 48 px |
| `EatovaTextAction` | 12 | 10 | Link-Gewicht, 48-px-Ziel |
| `EatovaDialogAction` | 16 | 6 | nur in der Entscheidungskarte |
| `HeaderIconButton` (+`.custom`) | 16 | 11 | 44 px rund, neutral/primary |
| `SquareIconButton` | 2 | 2 | 34 px **eckig** (rChip) in 44-px-Ziel: `rows.dart:59`, `recipe_detail.dart:437` |
| `SheetCloseButton` | 17 | 17 | 44 px rund in 48-px-Ziel |
| `CreationAddButton` | 3 | 3 | Dublette von `SoftPillButton(accent, expand)` (`creation.dart:94`) |
| `FilterChipPill` | 16 | 14 | einzige Chip-Sprache |
| rohes Material `IconButton(` | 20 | 16 | z. B. `add_meal_sheet.dart:2134/2141`, `export_sections.dart:348/354`, `coach_sessions.dart:171`, `player_exercise_card.dart:124/167`, `training_log_editor.dart:949/1117` |
| rohes `FilledButton(`/`TextButton(`/`TextButton.icon(` außerhalb des Designs | 2 / 4 / 0 | | `player_header.dart:57`, `meal_suggestion_item.dart:556`, `player_set_row.dart:156`, `training_plan_picker.dart:272`, `profile_widgets_actions.dart:325/351` |
| private Rund- und Icon-Buttons | 8 | | `_RoundButton` (`meal_camera_sheet.dart:765`), `_RoundDockButton` (`food_page_chrome.dart:613`), `_RoundAddButton` (`meal_plan_week.dart:434`), `_AddButton` (`today_sections.dart:462`, `meal_suggestion_item.dart:523`), `_RoundIconButton` (`recipe_ingredient_editor.dart:205`), `TrainingRoundButton` (`training_overview_widgets.dart:568`, 54 px `surf2`), `MealQuickAddButton` |
| private Stepper | 11 Klassen, 7 Bauarten | | `edit_meal_sheet.dart:726/786`, `meal_describe_draft.dart:755/863`, `meal_suggestion_item.dart:642/765`, `meal_widgets_adjust.dart:794`, `meal_plan_editor.dart:419/557`, `onboarding_controls.dart:434`, `coach_training_brief.dart:885/1025` |
| `InkWell(` / `GestureDetector(` | 109 / 18 | 60 / 16 | Ripple ist global aus (`app_theme.dart`, `splashFactory: NoSplash`). Die meisten GestureDetector tragen Semantik. Ohne Druck- und Deaktiviert-Zustand ist `meal_widgets_adjust.dart:813`. |
| `PressScale(` | 50 | 32 | Druck-Dip 0,97, Karte 0,985, Rebound 0,965 (`lively.dart:426`) |

### 1.2 Icons

- **690 `Icons.*`-Referenzen, 178 verschiedene Glyphen.** Davon sind 563 `_rounded` (Material „Rounded" ist **gefüllt**; darin 120 `_outline_rounded`), 122 `_outlined` (Material „Outlined", **kontur**, eckigere Ecken) und 4 ohne Suffix, also „Filled" (`Icons.chevron_left/right` in `export_sections.dart:352/360`, `expand_less/more` in `:291`, `check_circle_outline` in `meal_plan_editor.dart:130`). Kein `CupertinoIcons`, kein SVG-Paket.
- **Sechs eigene Glyph-Painter** im offenen Strich (1,7 bis 2,6 auf 24er-Raster, runde Kappen): `AppIcon` (Tabs, Schritte, `app_icon.dart`), `SlotIconTile` (4 Slots), `FoodGlyph` (7, `food_glyphs.dart`), `RecipeGlyph` (11, `recipe_glyphs.dart`), `TodayGlyph` (5, `today_glyphs.dart`), `TrainingWorkoutGlyph` und der Exit-Glyph der Entscheidungskarte. Diese Glyphen stammen aus `Design.html`. Daneben sitzen gefüllte Material-Glyphen: Das ist der Kern der Disharmonie.
- **Gleiches Konzept, verschiedene Glyphen:**
  - Bearbeiten: `edit_outlined` 16×, `edit_rounded` 7× (gefüllt), `edit_note_rounded` 5×, `drive_file_rename_outline_rounded` 1×.
  - Favorit: `favorite_outline_rounded`, `favorite_border_rounded` (dieselbe Form unter zwei Namen) und `favorite_rounded`.
  - Kopieren: `content_copy_rounded`, `copy_rounded`, `copy_outlined`.
  - Haken im Kreis: `check_circle_rounded`, `check_circle_outline_rounded`, `check_circle_outline`, `task_alt_rounded`.
  - Kalender: `calendar_month`, `calendar_today`, `today`, dazu `FoodGlyph.calendar` und `RecipeGlyph.calendar`.
- **Entschiedenes wird unterlaufen:**
  - Schritte als Person (`directions_walk_rounded` in `goals_screen.dart:853`, `profile_widgets_hero.dart:61`, `profile_widgets_actions.dart:274`), obwohl seit 2026-09-07 der Fußabdruck `StepsIcon` gilt.
  - Funkel-Sterne (`auto_awesome`) 15×, obwohl der Review vom 2026-09-07 und #174 „keine dekorativen KI-Sterne" festhalten.
- **Größen:** 17 verschiedene Literalgrößen in `Icon(size:)` (12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 24, 26, 28, 30, 32, 40). Am häufigsten: 20 (38×), 18 (30×), 22 (28×). Das Theme setzt 20 (`app_theme.dart:108`).
- **Icon-Container: sieben Bauarten, sieben Kantenlängen.**

  | Widget | Ort | Kante, Glyph, Radius |
  |---|---|---|
  | `IconTile` | `controls.dart:181` | 34, 16, rChip; Aufrufer setzen 30, 36, 38 und 48 |
  | `SettingsRowTile` | `settings_studio_widgets.dart:100` | 40, 20, rChip |
  | `SettingsGlyphTile` | `settings_controls.dart:243` | Dublette von `SettingsRowTile` |
  | `OptionGlyphTile` | `option_card.dart:64` | 44, 22, rControl |
  | Today-`_GlyphTile` | `today_sections.dart:49` | 44, rControl |
  | `CalmState` inline | `states.dart:189` | 48, rChip |
  | `CalmState` als Karte | `states.dart:221` | 44, rControl |
  | Food-Zeilen | `diary_meal_card.dart` | 36, rChip |
  | Plan-Zeilen | `meal_plan_week.dart` | 30 |

### 1.3 Listen und Aufzählungen

- `ListTile` kommt praktisch nicht vor: 2 Treffer, beide private `_RecipeListTile`. Es gibt **57 private `*Row`-Klassen**, dazu zwei Design-Systeme:
  - `SettingsGroup` mit `SettingsRow` (`rows.dart:178/241`): Kopf in Versalien als Eyebrow (`rows.dart:203`), Zeile mindestens 56 px (`:284`), Trenner immer bei 18 eingerückt (`:224`), auch bei vorangestellter Kachel.
  - `SettingsStudioGroup` mit `SettingsStudioRow` (`settings_studio_widgets.dart:27/131`): Kopf Display 19/700 (`:53`), Zeile mindestens 68 px (`:186`), Trenner an der Textspalte bei 72 (`:77`), Chevron 22 px (`:177`).
  - `goals_screen.dart:768–1110` mischt beide.
- Zeilenhöhen in privaten Zeilen: 48, 52, 56, 64, 68. Führende Elemente: 30, 32, 34, 36, 40, 44, 78×84. Chevron: 20 `ink3` (`rows.dart:356`), 22 `ink3` (`training_overview_widgets.dart:1245`, `training_history_screen.dart:219`), 20 **`ink2`** (`recipe_cards.dart:65`).
- **Aufzählungen:** In Code und ARB steht nirgends „•" als Text. Das ist gut. Es gibt genau eine Bullet-Liste (`RecipeIngredientLines`, `recipe_sections.dart:124`, 6-px-Akzentpunkt) und eine Icon-Bullet-Liste (`DecisionConsequence`, `dialogs.dart:471`).
- **Nummerierte Folgen in vier Stilen:**
  - Kreis in Akzent-Tönung (`RecipeStepBadge`, `recipe_sections.dart:257`, 26 und 34 px).
  - „01" in einer `surf2`-Kachel (`CreationSectionHeading`, `creation.dart:36`).
  - „01" nackt in `ink2`, Display 17 (`training_exercise_list.dart:43`).
  - „01" in `accentText`, Display 18 (`training_plan_editor.dart:789`).
- **Pills:** 21 private Pill- und Chip-Klassen, davon sind 3 Segment-Controls der Einstellungen. Die übrigen 18 sind Status-, Meta- oder Aktions-Pills ohne gemeinsame Höhe, Schrift oder Tönung, z. B. `_MetaChip`, `_Pill`, `_CategoryPill` (10,5 px Text, `recipe_atoms.dart:198`), `_TintChip`, `_DeltaPill`, `_ZonePill`, `_IdentityPill`, `_StreakPill`, `_EatenPill`, `_WeighChip`, `_AlertsOffChip`, `_SuggestionPill`, `_TryChip`, `_CardPill`.

### 1.4 Leer, Laden, Fehler

- `CalmState` 20× in 13 Dateien, `SignalNote` 15×, `SkeletonCard/Row/Bar` in 6 Dateien, `AppSpinner` in 11 Dateien.
- **Handkopien und Ausreißer:**
  - `_ShoppingEmpty` (`meal_plan_shopping.dart:9–59`) ist eine wörtliche Kopie von `CalmState(card: true)`.
  - `_EmptyDraft` (`meal_describe_draft.dart:236`) hat ein nacktes 26-px-Icon in `ink3`.
  - Trends `_EmptyCard` und `_ErrorCard` (`trends_screen.dart:1529/1594`).
  - Drei eigene Fehlerkarten: `meal_analysis_sheet.dart:720`, `meal_describe_sheet.dart:1837`, `coach_message_list.dart:608`.
- **Rohe `CircularProgressIndicator`** neben `AppSpinner`: `auth_screen.dart:442`, `auth_controls.dart:510`, `meal_camera_sheet.dart:856`, `recipe_create_sheet.dart:1097`, `training_overview_widgets.dart:606`, `dialogs.dart:987`, `eatova_home_page.dart:2438`.
- **Lade-Buttons doppelt gebaut:**
  - `AuthPrimaryButton` zeichnet einen eigenen, unbeleuchteten Container mit Spinner (`auth_controls.dart:482–516`), obwohl `PrimaryActionButton.busy` existiert (`controls.dart:538`).
  - `recipe_create_sheet.dart:1091–1103` legt einen rohen Spinner **über** den Primärbutton.

### 1.5 Typografie, Abstände, A11y

- `AppType.ui` wird mit 14 Größen aufgerufen, darunter halbe Schritte (10,5 / 11 / 11,5 / 12 / 12,5 / 13 / 13,5 / 14 / 14,5 / 15 / 15,5 / 16 / 17 / 18). `AppType.display` mit 25 Größen. Es gibt keine benannten Rollen außer `pageTitle`, `sectionEyebrow` und `eyebrow`.
- **Unter dem HIG-Minimum von 11 pt:**
  - `AppType.eyebrow` hat den Default 10 (`app_tokens.dart:1052`).
  - Aufrufe mit 9,5 px: `barcode_scanner_sheet.dart:624`, `meal_plan_editor.dart:409`, `account_change_sheets.dart:748`, `training_log_editor.dart:896`.
  - Aufrufe mit 10,5 px: `recipe_detail.dart:858`, `player_exercise_card.dart:416`, `profile_widgets_hero.dart:566`, `recipe_atoms.dart:198`.
- Es gibt keine Abstands-Tokens. Gerade Werte von 2 bis 24 sind üblich. Halb-semantische Konstanten liegen verstreut: `_kGutter = 20` (`recipes_header.dart:12`), `_gap = 14` (`meal_analysis_screen.dart:535`), `kSettingsRowPad = 18`.
- Tabellarische Ziffern sind nur in `AppType.display` gesetzt. Figtree hat `tnum` (geprüft mit fontTools), es wird aber nur an 18 Stellen genutzt.
- **A11y-Fund:**
  - `_AutoDismiss` (`app_snack.dart:363–399`) entfernt jeden Toast nach Ablauf, **auch einen mit Undo-Aktion bei aktivem Screenreader**. Flutters eigene SnackBar lässt solche Toasts bei `accessibleNavigation` absichtlich stehen (`snack_bar.dart:227–228`: „A SnackBar with an action will not time out when TalkBack or VoiceOver are enabled"). Mit TalkBack oder VoiceOver ist „Rückgängig" deshalb praktisch unerreichbar.
  - Zum Vergleich die Standzeiten: 1,6 s für Toasts, 2,2 s für Toasts mit Aktion.

### 1.6 Die zehn sichtbarsten Inkonsistenzen

1. **Drei Icon-Sprachen nebeneinander:** gefüllte Rounded-, Outlined- und eigene Strich-Glyphen. Beispiel aus einer einzigen Gruppe der Einstellungen: `tune_rounded` (gefüllt, `settings_screen.dart:442`) neben `file_download_outlined` (`:529`) und `shield_outlined` (`:538`). Dazu kommen vier „Bearbeiten"-Glyphen.
2. **Zwei Listen-Sprachen:** Einstellungen, Ziele und Picker-Sheets zeigen Versalien-Kopf gegen Display-19-Kopf, Trenner bei 18 gegen 72 und Zeilen mit 56 gegen 68 px (siehe 1.3).
3. **Icon-Kacheln** in 30 bis 48 px und zwei Radien. `CalmState` hat sogar zwei Kacheln (`states.dart:189` gegen `:221`).
4. **Zurück-Knopf in zwei Formen:** 34 px eckig (`PageHeader` ohne `prominent`, `rows.dart:59`: Rezeptdetail, Rezeptverlauf, Trends) gegen 44 px rund (alle anderen Seiten, Sheets).
5. **20 rohe Material-`IconButton`** mit Stock-Optik und uneinheitlichen 40-, 44- und 48-px-Kästen. Am deutlichsten in `export_sections.dart:348–360`, mit „Filled"-Chevrons.
6. **Sieben Stepper-Optiken:**
   - Akzent-Kreis (`edit_meal_sheet.dart:786`).
   - `surf2`-Kreis mit Akzent-Glyph per `GestureDetector`, ohne Druck- und Deaktiviert-Zustand (`meal_widgets_adjust.dart:794–822`).
   - Weitere in Onboarding, Plan-Editor, Coach-Brief, Vorschlag und Beschreiben.
7. **Vier Nummern-Stile** für Schritte und Reihenfolgen (siehe 1.3).
8. **Ladezustand im Button uneinheitlich:** überlagerter Spinner (`recipe_create_sheet.dart:1091`), eigener Auth-Container (`auth_controls.dart:500`) und `TrainingRoundButton` mit rohem Spinner (`training_overview_widgets.dart:606`).
9. **Zu kleine Schrift:** Eyebrows mit 9,5 bis 10,5 px (siehe 1.5) und eine Kategorie-Pill mit 10,5 px.
10. **„Nicht jetzt" so schwer wie die Antwort:** Neutral gefüllte, volle Breite direkt unter dem Primärbutton, statt des leisen Tons aus #174. Betroffen sind `today_health_prompt.dart:180`, `today_reminder_prompt.dart:130` und `today_energy_check.dart:104`.

Weitere Funde: der Chevron-Mix aus 20 und 22 px sowie `ink2` und `ink3`; die Handkopie des Leerzustands im Einkauf; 18 private Pills; die Schritte als Person.

---

## a) Prinzipien

### Was bleibt (Grundprinzip)

- **Tokens und Paletten** aus `lib/src/theme/app_tokens.dart`: dunkel `bg #09090C`, `surf #131318`, Violett-Akzent `#B9A5FF`; die helle Palette spiegelt jede Rolle. Keine hart kodierte Farbe, kein Helligkeits-Abzweig (`test/repo_rules_test.dart`, „Token-Disziplin in lib/"). Die Radius-Skala bleibt, sie ist in `app_tokens_test.dart` „Form-Skala" festgenagelt.
- **Zwei Schriften:** Figtree für UI und Bricolage Grotesque für Display und Zahlen (tabellarisch). Dazu DM Mono nur für den Bon. Alles gebündelt, kein `google_fonts`.
- **Tiefe und Licht aus #174:**
  - genau **eine** beleuchtete Aktion pro Ansicht (`castLight`);
  - schwebende Flächen trennen sich durch Licht und Schatten, nicht durch eine Haarlinie (`LitSurface`);
  - keine Ripples, ein Druck vertieft die Füllung und federt zurück (`PressScale`);
  - Tastaturfokus heißt Füllwechsel plus Anheben, kein Ring.
- **Entscheidungskarten, Paywall und Abo-Karte** aus #174 sind Ausgangspunkt. Dort wird nur das Icon-System migriert.
- **Eingabefelder** bleiben randlose Kapseln (`field`, `fieldFocus` heller, `fieldError`) mit `softShadow`. Fokus ist sichtbar über die Füllung.
- **Auswahl-Sprache:** Akzentfüllung mit On-Akzent-Beschriftung (`SelectionTone`, `controls.dart:39`).
- **Bewegungs-Sprache:** `kMotionCurve` (easeOutCubic), Druck 90/160 ms, Eintritt 220 ms, Werte 520 ms, Federn nur für Ankunft und Entscheidung. Alles läuft über `motionDuration` (`motion.dart`).
- **Tab-Wurzeln aus `Design.html`** (Today, Food, Rezepte, Training, Coach) mit Glas-Tab-Bar und ihren eigenen Strich-Glyphen.
- **A11y-Verträge:**
  - 44-pt-Tippziel als Untergrenze;
  - `HeadingSemantics` (Rang 1 und 2);
  - Textskalierung bis 2,0 ohne Overflow (`text_scale_stress_test.dart`, `app_layout_sweep_test.dart`);
  - Kontrast 4,5:1 für Text und 3:1 für Zustands-Grafik in **beiden** Paletten.

### Was sich ändert, und warum

| Änderung | Warum (Quelle) |
|---|---|
| Ein Icon-System: Kontur in Listen und Buttons, Füllung nur für Zustand; eine Strichstärke, die zu den eigenen Glyphen passt | HIG `icons.md › Best practices`: „all interface icons in your app need to use a consistent size, level of detail, stroke thickness (or weight), and perspective"; „match the weights of interface icons and adjacent text". `sf-symbols.md › Design variants`: Kontur „works well in toolbars, lists, and other places where you display a symbol alongside text", Füllung für „places where you use an accent color to communicate selection". |
| Feste Button-Hierarchie, eine Prominente pro Ansicht, Stil statt Größe | `buttons.md › Style`: „Keep the number of prominent buttons to one or two per view"; „Use style — not size — to visually distinguish the preferred choice". `buttons.md › Best practices`: „Always include a press state for a custom button." `buttons.md › Mobile`: Aktivitätsanzeige **im** Button. |
| Eine Zeilen-Anatomie, gruppierte Sektionen, Trenner an der Textspalte | `lists-and-tables.md › Style` (gruppierter Stil mit Kopf, Fuß und Abstand); `layout.md › Visual hierarchy`: „Align elements … use indentation to convey hierarchy". Material-3-Defaults in Flutter (`list_tile.dart`, `_LisTileDefaultsM3`): Höhen 56/72/88, Einzug 16/24, `minLeadingWidth 24`, Abstand 16. |
| Aufzählungen als Widgets, Nummern nur für echte Folgen | Craft-Linse des `apple-design`-Skills: „01 / 02 / 03 markers on content that isn't a sequence" wirken wie eine Vorlage; Struktur muss etwas Wahres über den Inhalt sagen. |
| Benannte Typo-Rollen, Minimum 11 | `typography.md`: iOS Default 17 pt, Minimum 11 pt; `accessibility.md › Vision`: dünne oder kleine Schnitte meiden. |
| Leer, Laden, Fehler in einer Sprache | HIG `loading.md › Best practices`: „Show something as soon as possible". NN/g, Skeleton Screens: Skeleton für Seiten- und Listen-Ladevorgänge unter 10 s, Spinner für ein einzelnes Modul, über 10 s Fortschritt mit Zeitangabe; statisch statt Shimmer, weil Shimmer ablenken kann. NN/g, Empty States: Systemstatus nennen, Lernhinweis geben, direkter Weg zur Aktion. |
| Weniger Varianten, saubere Ausrichtung | Linear-Redesign: „reduce visual noise, maintain visual alignment, and increase the hierarchy". Linear richtete Labels, Icons und Buttons horizontal und vertikal aus. |
| Haptik schmal halten | `playing-haptics.md › Best practices`: konsistent, kurz, nicht übernutzen. Das entspricht der #174-Politik. |

**Begründung „nicht generisch":** Generisch wirkt die App heute dort, wo Stock-Material durchscheint: rohe `IconButton`, gefüllte Material-Glyphen neben feinen Strich-Glyphen, 18 verschiedene Pills und Zeilen ohne gemeinsame Kante. Identität entsteht nicht durch neue Effekte. Sie entsteht durch **eine** Sprache, die an jeder Stelle gleich spricht. Die eine Signatur bleibt das Licht der einen Aktion (#174); alles andere wird leiser und gleichmäßiger.

---

## b) Komponenten-Spezifikation der Basis-Schicht (Agent 2)

Grundsatz: **erweitern statt ersetzen**. Alte Klassennamen bleiben als dünne Wrapper, damit Keys, Finder und Aufrufer nicht brechen. Jede Farbe kommt aus `AppTokens`, jede Dauer läuft durch `motionDuration`. Neue Komponenten werden über `design.dart` exportiert und bekommen je eine Vorschau in `design_previews.dart` (`@EatovaPreview`, hell und dunkel).

### B0 Neue Token-Gruppen (additiv; bestehende Werte bleiben unverändert)

In `lib/src/theme/app_tokens.dart`:

```dart
// --- SPACE (polish 2026-11) --------------------------------------------------
const double kSpace4 = 4, kSpace8 = 8, kSpace12 = 12, kSpace16 = 16,
    kSpace20 = 20, kSpace24 = 24, kSpace32 = 32;
const double kPageGutter = 20;     // Seitenrand aller Tabs/Seiten
const double kCardInset = 18;      // Innenrand von Karten und Zeilen (heute 18)
const double kRowLeadingGap = 14;  // führendes Element → Textspalte
const double kCardGap = 14;        // Abstand zwischen Karten einer Sektion
const double kSectionGap = 28;     // Abstand zwischen Sektionen
```

Neuer Code nimmt nur diese Werte. Bestehender Code wird **nur in Widgets umgestellt, die ihr ohnehin anfasst**; es gibt keinen globalen Ersatz per `sed`.

`AppTokens` bekommt ein Feld `iconGrade` (double, dunkel `-25`, hell `0`), mit `copyWith` und `lerp` wie `glowStrength`. So bleibt die Regel ohne Helligkeits-Abzweig erfüllt. Laut Google-Guide ist ein niedriger Grad (−25) für helle Symbole auf dunklem Grund gedacht, um Überstrahlen zu dämpfen.

**Typo-Rollen** als statische Methoden auf `AppType`, additiv. Die bisherigen Stile bleiben bestehen. `AppType.ui` bekommt `{bool tabular = false}`.

| Rolle | Stil | ersetzt typischerweise |
|---|---|---|
| `pageTitle` (besteht) | Display 36/800, h1,05; Unterseite 24 | – |
| `sheetTitle` (besteht als `sheetTitleStyle`) | Display 24 (kompakt 20) | – |
| `title2(c)` | Display 19/700, h1,2 | Kartentitel, `CalmState`-Karte |
| `section(c)` | Display 17/700 | `SectionHeading`, Sektionsköpfe (bisher 19 in den Einstellungen) |
| `headline(c)` | UI 16/700, −0,2 | `OptionCard`-Titel |
| `rowTitle(c)` | UI 15/600 | Zeilentitel |
| `body(c)` | UI 15/400, h1,45 | Fließtext, Schritte |
| `callout(c)` | UI 14/400, h1,4 | Karten- und Leerzustandstext (13,5 → 14) |
| `subhead(c)` | UI 13/400, h1,35 | Zeilen-Untertitel, Hinweise |
| `caption(c)` | UI 12/600 | Meta-Zeilen (12,5 → 12) |
| `sectionEyebrow` (besteht) | UI 12/700, 0,07 em, Versalien | Eyebrow über Kartentiteln |
| `micro(c)` | UI 11/600 | Nav-Label, Badge; **das Minimum** |
| `numeric(size, …)` | Display mit `tnum` | Zahlen; in Figtree `ui(…, tabular: true)` |

Den Default von `AppType.eyebrow` von 10 auf **11** setzen (`app_tokens.dart:1052`). Kein Text liegt unter 11. Halbe Größen werden beim Anfassen auf die nächste Rolle gezogen: 10,5 → 11, 11,5 → 12, 12,5 → 12, 13,5 → 14, 14,5 → 15, 15,5 → 15.

**Ebenen im Dark Mode** (Regel, keine neuen Werte):

| Ebene | Fläche | Kante | Schatten | Beispiele |
|---|---|---|---|---|
| 0 Grund | `bg` | – | – | Scaffold, Sheet-Grund |
| 1 Inhalt | `surf`; Mulden `surf2`/`surfRaised` | 1 px `line` | **nie** | `AppCard`, `ListSection` |
| 2 schwebend | `litSurface` (`surfLit` → `surf`) | **keine** | `raisedShadow` / `decisionShadow` | Entscheidungskarte, Plan-Picker, Abo-Karte |
| 3 Chrome | `navGlass` mit Blur | `lineStrong` | `floatingShadow` | Tab-Bar |
| Modal | `scrim` | – | – | Sheets, Dialoge |

Tiefe entsteht im Dark Mode durch einen helleren Ton, nicht durch Schwarz-Schatten (HIG `dark-mode.md › Mobile`: „elevated background color"). **Radien:** Buttons sind Kapseln (`StadiumBorder`, `rButton` = 27 bei 54 px), Icon-Buttons Kreise, Icon-Badges abgerundete Quadrate, Karten `rCard`. Verschachtelte Ecken laufen konzentrisch (innen = außen − Innenabstand), wo ihr ein Element ohnehin anfasst.

### B1 Icon-Schicht `AppIcons` (neu: `lib/src/theme/app_icons.dart`)

- `abstract final class AppIcons { static const IconData edit = Symbols.edit_rounded; … }`. Die Konstanten müssen `const` sein, sonst greift das Icon-Tree-Shaking nicht.
- Agent 2 füllt **alle 153 Konzepte aus Anhang A** auf einmal. Danach ersetzen die Screen-Agents nur noch Referenzen und ändern diese Datei nicht. Braucht ein Screen ein neues Glyph, nimmt er `Symbols.<name>_rounded` direkt und meldet es; die Integration zieht es nach `AppIcons`.
- `AppIconSize`: `meta 14`, `small 16`, `button 18`, `standard 20`, `tile 22`, `large 24`.

  | Kontext | Größe |
  |---|---|
  | Meta-Zeile, `StatusPill`, Chip `sm` | 14 |
  | neben 13–14-px-Text, Badge `sm`, Chip `md` | 16 |
  | in beschrifteten Buttons (Primary, Soft, Text) | 18 |
  | Standard: Icon-Button, `MenuRow`, Chevron, Badge `md` | 20 |
  | Badge `lg`, Design-Glyphen der Tab-Wurzeln | 22 |
  | Icon-Button `large` (Player-✓, Kamera-Dock), Leerzustand | 24 |

  Andere Literalgrößen sind in neuem Code verboten.
- **Theme** (`app_theme.dart:108`): `iconTheme: IconThemeData(color: t.ink2, size: 20, fill: 0, weight: 400, grade: t.iconGrade, opticalSize: 20)`. Bei 24 px setzt der Aufrufer `opticalSize: 24`.
- **Zustand durch Füllung:** Nur ein „an" ist gefüllt: Favorit gesetzt, gespeichert, gegessen oder abgehakt, laufende Medien-Steuerung (play, pause, stop, skip). Alles andere ist Kontur. Der Wechsel animiert die `fill`-Achse von 0 nach 1 über `kMotionLightUp` (240 ms) mit `kMotionCurve`; bei reduzierter Bewegung springt er sofort.
- **Optische Ausrichtung:** Ein Glyph neben mehrzeiligem Text wird auf die **erste** Zeile zentriert (Vorbild `DecisionConsequence`, `dialogs.dart:487`). `play_arrow` sitzt in runden Buttons 1 px nach rechts versetzt (HIG `icons.md`, optisches Zentrieren).
- **Fonts im Test-Harness:** `loadDesignFonts` (`test/support/design_capture.dart`) lädt zusätzlich die Familie `packages/material_symbols_icons/MaterialSymbolsRounded` aus `packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf`. Ohne diesen Schritt zeigen die Aufnahmen Kästchen.

### B2 Button-Familie

| Rang | Widget | Maße | Verwendung |
|---|---|---|---|
| **Primär (lit)** | `PrimaryActionButton` (besteht, `controls.dart:514`) | `regular` 54, `compact` 48; Kapsel; Label UI 15/800; Icon 18; Innenabstand h18 | die **eine** wahrscheinlichste Aktion der Ansicht |
| **Sekundär (tonal)** | `SoftPillButton` `accent` / `neutral` (`soft_actions.dart:40`) | 48, **neu `size: regular` = 54**; Kapsel; Label 14/700; Icon 18; h20 | „hier etwas tun" (accent), Alternative (neutral) |
| **Tertiär (leise)** | `SoftPillButton.quiet`, `EatovaTextAction` (`soft_actions.dart:156`) | 48-Ziel; leise ohne Ruhefüllung | Abbrechen, „Nicht jetzt", „Später"; Links im Text |
| **Destruktiv** | Einstieg: `SoftPillButton.danger`, `MenuRow(destructive)` (nur der Glyph rot), Zeile mit `destructive`. Bestätigung: `EatovaDialogAction(destructive)` → `dangerFill` | wie oben | Rot **füllt** nur die bestätigende Aktion der Entscheidungskarte |
| **Icon-Button** | **neu `AppIconButton`** (B3) | 36/44/56 | alle Icon-only-Aktionen |

**Regeln:**

1. Höchstens **eine** lit-Aktion pro Ansicht. Ein Sheet hat seine Aktion am Fuß, eine Karte ihr `compact`.
2. Steht eine Sekundäraktion **direkt** unter einer Primäraktion, ist sie genauso hoch (`size: regular`) und genauso breit (`expand: true`). Die Hierarchie trägt der Stil (HIG; Vorbild „Weiter mit Free" aus #174).
3. Ein Ablehnen („Nicht jetzt", „Abbrechen", „Später") ist **immer** `quiet`, nie `neutral`.
4. Button-Labels beginnen mit einem Verb und behalten ihren Namen durch den Ablauf (HIG `writing.md`). **ARB-Texte bleiben trotzdem wortgleich** (Tests); Umbenennungen nur mit Owner-Freigabe.

**Zustände** (für alle Buttons gleich):

| Zustand | Darstellung |
|---|---|
| normal | Ruhe-Füllung des Tons |
| gedrückt | `PressScale` (lit und tonal mit `rebound`), Füllung vertieft sich um 10 % Label-Ton; lit zieht sein Licht ein (`castLight(press:)`) |
| Fokus (Tastatur) | Overlay 16 % Label-Ton bzw. `kLitFocusOverlay` auf lit, lit hebt das Licht ×1,4; **kein Ring** |
| deaktiviert | `onTap: null`, Label und Füllung 45 %, `Semantics(enabled: false)`, kein Dip; lit wird „noch nicht" (`kLockedFillAlpha`) |
| laden | `busy: true`: `AppSpinner` 18/2 im Label-Ton an der Stelle des Icons, Füllung bleibt, Taps werden ignoriert, Label bleibt lesbar (optional „Speichern…") |

**Neu für `SoftPillButton`:** `size` (`compact` 48 Default, `regular` 54) und `busy` (Spinner 16 im Label-Ton). `CreationAddButton` (`creation.dart:94`) wird Wrapper auf `SoftPillButton(tone: accent, expand: true, icon: AppIcons.add)`.

**Haptik** (bestehende Politik, nicht erweitern):

- `selectionClick` bei einem diskreten Wertwechsel (Tab, Segment, Stepper);
- `lightImpact` bei Bestätigen und Hinzufügen;
- `mediumImpact` bei destruktivem Bestätigen;
- nichts auf Zeilen und beim Scrollen.

**A11y:** Ziel mindestens 44 × 44, besser 48, wo Platz ist. Zwischen benachbarten Zielen 8 px (HIG `accessibility.md › Mobility`). Labels über `semanticLabel`, Icon-only immer mit Label.

### B3 `AppIconButton` (neu in `controls.dart`)

```dart
enum IconButtonTone { neutral, accent, primary, plain, danger }
enum IconButtonSize { compact, regular, large } // 36 in 44 | 44 | 56
class AppIconButton extends StatefulWidget {
  const AppIconButton({super.key, IconData? icon, Widget? child,
    required String semanticLabel, VoidCallback? onTap,
    IconButtonTone tone = IconButtonTone.neutral,
    IconButtonSize size = IconButtonSize.regular,
    bool busy = false, bool? selected /* Toggle: fill 1 + Semantics toggled */,
    bool haptic = false, Key? buttonKey});
}
```

| Ton | Füllung | Glyph |
|---|---|---|
| `neutral` | `softFill` | `inkMuted` |
| `accent` (tonal) | `accentTintStrong` | `accentText` |
| `primary` (lit) | `accentFill` mit `castLight` | `onAccentFill` |
| `plain` | ohne; `softFill` erscheint nur bei Druck oder Fokus | `ink2` |
| `danger` | `danger` @ 12 % | `danger` |

`plain` ist für Aktionen in einer Zeile: Löschen, Feld leeren, Menü-Trigger.

**Größen:**

| Größe | sichtbar | Ziel | Glyph |
|---|---|---|---|
| `compact` | 36 | 44 | 18 |
| `regular` | 44 | 44 | 20 |
| `large` | 56 | 56 | 24 |

Die Form ist immer ein Kreis. Die Zustände folgen B2. `selected` setzt `fill: 1` und `Semantics(toggled:)`. Ein Tooltip zeigt bei langem Druck `semanticLabel` (das Theme ist gesetzt).

**Abbildung:**

- `HeaderIconButton` (`controls.dart:113`) wird Wrapper: `neutral`/`primary` auf `regular`.
- `SquareIconButton` (`controls.dart:49`) wird Wrapper auf `compact` und `neutral` und damit **rund**.
- `PageHeader` ohne `prominent` (`rows.dart:59`) nutzt ab jetzt `regular`, ebenfalls rund.
- `SheetCloseButton` (`sheets.dart:27`) delegiert und behält sein 48-px-Ziel.

### B4 `AppStepper` (neu in `controls.dart`)

```
[ (−) ]  250 g  [ (+) ]
```

- Die Knöpfe sind `AppIconButton(tone: accent)`, `regular` (oder `compact` in Zeilen). Der Wert steht in `AppType.numeric(20, weight: 700)` und ist mindestens 56 px breit, zentriert. Die Einheit in `subhead`/`ink2`.
- Grenzen: `onDecrement: null` dimmt den Knopf auf 45 % und meldet ihn deaktiviert.
- Optional `onLongPressDecrement/Increment` für Aufrufer, die heute einen langen Druck kennen (`meal_widgets_adjust.dart:813`).
- **Semantik:** Der ganze Stepper ist **ein** einstellbarer Knoten (`Semantics(label:, value:, increasedValue:, decreasedValue:, onIncrease:, onDecrease:)`). Bei VoiceOver geht das mit Wischen hoch oder runter. Die Knöpfe behalten eigene Labels für das Ertasten (vom Aufrufer, sonst die neuen ARB-Keys `commonDecrease`/`commonIncrease`).
- `selectionClick` bei jedem Schritt. Keys übergibt der Aufrufer (`decrementKey`, `incrementKey`), damit Tests weiterlaufen.

### B5 `IconBadge` (neu in `controls.dart`; `IconTile` wird Wrapper)

| Größe | Kante | Glyph | Radius | Einsatz |
|---|---|---|---|---|
| `sm` | 32 | 16 | `rChip` | dichte Zeilen, Plan, Sessions |
| `md` | 40 | 20 | `rChip` | Standard-Listenzeile (heute Einstellungen) |
| `lg` | 44 | 22 | `rControl` | Tab-Wurzeln (Design.html), Leerzustände, Option-Karten |

| Ton | Füllung | Glyph |
|---|---|---|
| `neutral` | `tile` | `inkMuted` |
| `accent` | `accentTint` | `accentText` |
| `tone(Color c)` | c @ 15 % | `readableOnTint(c)` (wie heute `IconTile`) |
| `solid` | `accentFill` | `onAccentFill` |

`tone(c)` gilt für Makro-, Slot-, Warn-, Erfolgs- und Gefahr-Farben. `solid` ist selten und nie neben einer lit-Aktion. `child:` nimmt eigene Glyphen auf (`StepsIcon`, `TodayGlyphIcon`) und reicht Größe und Farbe per `IconTheme` durch.

Das Badge ist immer dekorativ (`ExcludeSemantics`); das Label trägt die Zeile.

**Abbildung:**

- `IconTile`: Größe auf die nächste Stufe abbilden, Default `sm`.
- `OptionGlyphTile` → `lg` accent.
- `CalmState` → beide Varianten `lg` (inline `neutral`, Karte `accent`).
- `SettingsRowTile`/`SettingsGlyphTile` → `md` (Agent 9).
- Today `_GlyphTile` → `lg` (Agent 3).

### B6 `ListSection` und `ListRow` (in `rows.dart`; `SettingsGroup`/`SettingsRow` werden Wrapper)

**Zeile, Anatomie** (übernimmt die erprobte Studio-Geometrie):

```
| 18 | [Badge md 40] | 14 | Titel rowTitle 15/600 ink       | 12 | Wert 14/600 inkMuted tnum | 6 | › 20 ink3 | 18 |
|    |               |    | Untertitel subhead 13 ink2 (+3) |    |                           |   |           |    |
```

- Mindesthöhe 56; vertikal 14. Mit Badge `md` entstehen so 68.
- Lange Werte (über 45 % der Breite) wandern unter den Titel (Logik aus `SettingsRow`, `rows.dart:274`).
- Ab Textskalierung 1,6 steht das Badge über dem Text (Logik `settingsTileStacked`). Die Trenner liegen dann bei 18.
- `below:` nimmt ein Control auf eigener Zeile auf, z. B. Segmente oder Retry (wie `SettingsStudioRow.trailing`).
- **Trailing-Regel:**

  | Typ | wann | Darstellung |
  |---|---|---|
  | `chevron` | nur wenn die Zeile eine Seite oder ein Sheet **zum Navigieren** öffnet | `AppIcons.chevronRight`, 20, `ink3` |
  | `external` | Link nach außen (Rechtliches, App-Einstellungen) | `AppIcons.openInNew`, 18, `ink3` |
  | `check` | ausgewählte Option in Picker-Listen | `AppIcons.check`, 20, `accentText` |
  | `toggle` | Schalter | `AppToggle`; die ganze Zeile schaltet |
  | `value` | Wert ohne Navigation | Text rechts, ohne Chevron |
  | `none` | **Aktionen**: Abmelden, Löschen, Exportieren | kein Chevron (HIG `lists-and-tables.md › Mobile`: Disclosure nur für Hierarchie) |

- **Zustände:**
  - gedrückt: `ink` @ 6 % Overlay (Theme-Highlight), **ohne** Scale; Zeilen werden häufig getippt (HIG `motion.md`: „avoid adding motion to UI interactions that occur frequently");
  - Fokus: `ink` @ 10 %;
  - deaktiviert: 45 %;
  - destruktiv: Titel in `danger`, Badge `tone(danger)`;
  - ausgewählt: `check` plus `Semantics(selected: true)`.
- **Semantik:** Die Zeile ist **ein** Knoten (`MergeSemantics`) mit `button: onTap != null`, Label = Titel + Untertitel + Wert, bei Toggle `toggled`.

**Sektion:**

- Kopf `SectionHeading` (Display 17/700, `HeadingSemantics(level: 2)`), 12 px darüber Abstand zur Karte.
- Karte: `Material(surf, rCard, 1 px cardBorder, clip antiAlias)`.
- Trenner 1 px `line`. `endIndent` 18. Der Einzug richtet sich nach `ListDividerInset`:

  | Einzug | Wert |
  |---|---|
  | `text` (Default) | 18 + 40 + 14 = 72 |
  | `textLg` | 76 |
  | `edge` | 18 |

- Fußnote: `subhead`/`ink2`, 8 px Abstand. Abstand zur nächsten Sektion `kSectionGap` 28.
- `SettingsGroup` (Versalien-Kopf) wird Wrapper auf `ListSection`. Der Versalien-Kopf entfällt zugunsten von `SectionHeading`.

### B7 `SectionHeading` (erweitern, `surfaces.dart`)

Neu ist `action:` (Widget?): ein `EatovaTextAction` rechts, zur Grundlinie ausgerichtet, z. B. „Alle", „Food-Log öffnen". Das bisherige `trailing:` (stummer Text) bleibt. Es gibt genau eine Sektionskopf-Größe: 17/700.

### B8 Aufzählungen (neu: `lib/src/widgets/design/lists.dart`)

Quelle ist `recipe_sections.dart:124–270`. Agent 2 übernimmt diese Datei und lässt `RecipeIngredientLines`, `RecipePreparationSteps` und `RecipeStepBadge` als Wrapper weiterlaufen.

- **`BulletList(items, {marker = BulletMarker.dot, style, gap})`**
  - Punkt 6 px, Farbe `accent`; auf der Marken-Fläche `onBrandSurface`.
  - Der Punkt sitzt mittig auf der **ersten** Zeile: `top = (scaler.scale(fontSize) * height − 6) / 2`. Die Logik besteht schon und bleibt.
  - 12 px Abstand zum Text. Der Text nutzt `body`.
  - `gap` 6 für kurze Listen (Zutaten), 12 für Satzlisten (Konsequenzen).
  - Marker, die schon in den Daten stehen („-", „•", „*", „·", „–"), werden entfernt (bestehende Regex).
- **`BulletList.icons([(icon, color, text)])`**: 18-px-Glyph in einer Bedeutungsfarbe. `DecisionConsequences` (`dialogs.dart:510`) wird Wrapper darauf.
- **`StepNumber(n, {size = 26})`**
  - Kreis `accentTint`, Ziffer `AppType.display(size * 0.46, color: accentText)`.
  - Die Ziffer skaliert mit dem Text nur bis 1,3×. Das besteht schon.
  - Größen: 26 inline, 32 als führendes Element einer Zeile.
- **`NumberedSteps(steps, {hint})`**
  - `StepNumber` 26, 12 px Abstand, Text `body`, 12 px zwischen den Schritten.
  - Ein einzelner Absatz bleibt Absatz (bestehende Regel).
  - Badge und erste Zeile teilen eine Mitte (bestehende Rechnung).
- **Semantik:**
  - Punkte und Nummern sind `ExcludeSemantics`.
  - Jeder Schritt wird als „Schritt 2 von 5. <Text>" gelesen, über den neuen ARB-Key `commonStepOf`. Agent 2 fügt ihn in de und en nach `commonDelete` ein, nicht am Dateiende.
  - Kein typografischer Bullet in Strings: Listen sind Daten, keine Satzzeichen.
- **Regel:** Nummern stehen **nur** bei echten Folgen: Zubereitungsschritte, Übungsreihenfolge, Kandidaten eines Imports. `CreationSectionHeading` (`creation.dart:30–40`) nutzt `StepNumber(32)` statt „01" in der `surf2`-Kachel. Ob die Nummern dort ganz entfallen, entscheidet der Owner.

### B9 `StatusPill` (neu in `soft_actions.dart`)

- Ein **nicht** tippbarer Status- oder Meta-Hinweis. Wer tippen soll, bekommt `FilterChipPill` (Auswahl) oder `SoftPillButton` (Aktion). Damit kann man nicht mehr raten, ob etwas ein Button ist.
- Mindesthöhe 28, Innenabstand h10 v5, Kapsel.
- Führend steht ein Icon 14 **oder** ein 8-px-Punkt in der Tonfarbe. Das Label ist UI 12/700 in `inkSoft`, beim Ton `accent` in `accentText`. Farbe allein trägt keine Bedeutung; der Text sagt sie.
- Töne:

  | Ton | Füllung |
  |---|---|
  | `neutral` | `tile` |
  | `accent` | `accentTint` |
  | `success`, `warning`, `danger`, `custom(Color)` | `tile`; nur Icon oder Punkt in der Farbe (kontrastsicher wie `SignalNote` mit Box) |

- `SourcePill` (`soft_actions.dart:257`) bleibt mit seiner Tipp-Funktion.

### B10 Leerer Zustand `CalmState` (vereinheitlichen, `states.dart`)

- Der Glyph sitzt in `IconBadge.lg`: inline `neutral`, Karte `accent`.
- Inline: Titel `headline`, Text `callout`.
- Karte: Titel `title2` mit `HeadingSemantics(2)`, Text `callout`.
- Höchstens zwei Wege (`SoftPillButton`), nie eine lit-Aktion. Die Seite hat ihre eigene.
- Texte nach dem Muster „was ist, wie weiter". Fehler sagen, was passiert ist, und bieten „Erneut versuchen". Kein Rot (NN/g; HIG `writing.md`).

### B11 Laden

- **Skeleton:** `SkeletonCard`, `SkeletonRow` und `SkeletonBar` bleiben statisch, ohne Shimmer. Die Kachelgröße folgt dem `IconBadge` der Zeile, die sie ersetzen: `md` 40 als Default, Food `lg` 44.
- **Spinner:** Nur `AppSpinner`, 18 px im Button und 22 px in einem Modul. Er sitzt nie bildschirmfüllend, außer beim Boot.
- **Lange Läufe:** Ab etwa 10 s gibt es gestufte Texte mit „Schritt n von m". Das macht `MealLoadingCard` schon.
- Agent 2 ersetzt den rohen Spinner in `dialogs.dart:987`.

### B12 Sheets, Dialoge, Snackbars, Fokus, Bewegung (Regeln, kaum neuer Code)

- **Sheets** (`showEatovaSheet`, `SheetScaffold`):
  - Griff 40 × 4 in `inkDisabled`;
  - Titel Display 24;
  - Schließen oben rechts;
  - **eine** Aktion am Fuß;
  - Verwerfen-Schutz bleibt;
  - immer nur ein Sheet auf einmal (HIG `sheets.md`).
- **Dialoge:** nur `EatovaDialog` als Entscheidungskarte, unten verankert, mit gestapelten Aktionen (lit, sekundär, leise). Es gibt keinen Material-`AlertDialog` (0 Treffer); das bleibt so.
- **Snackbars:**
  - nur `showAppSnack` mit `SnackTone`;
  - immer einer auf einmal;
  - die Haarlinie bleibt, als begründete Ausnahme (`app_theme.dart`, `snackBarTheme`: Der Schatten wurde im `SnackHost` zur Naht);
  - die Glyphen kommen aus `AppIcons`.
- **Fokus:** Füllwechsel. Die Overlay-Stärken stehen in B2. Für `InkWell`-Zeilen setzt das Theme `focusColor: t.ink @ 10 %` und `hoverColor: t.ink @ 4 %` (`app_theme.dart`).
- **Bewegung:**
  - nur die Tokens aus `motion.dart`;
  - Federn nur für Ankunft (Entscheidungskarte) und „Pop" (Haken, Medaillon);
  - Zeilen bewegen sich nicht beim Tippen;
  - Fill-Achsen-Wechsel 240 ms;
  - bei reduzierter Bewegung ist alles im ersten Frame in Ruhe.

  Ergänzend zu den Flutter-Tokens (`Durations.short2` 100 ms, `medium1` 250 ms; `Easing.emphasizedDecelerate`): Eatova nutzt **nur** die eigenen `kMotion*`. Mischt keine Material-Easings hinein.

**Tests der Basis** (wenige, scharf; `CONTRIBUTING.md › Writing tests`):

1. `test/widgets/design/controls_test.dart`, ein Tabellentest über alle Töne und Größen von `AppIconButton` und `AppStepper`. Er prüft:
   - `meetsGuideline(iOSTapTargetGuideline)` und `labeledTapTargetGuideline`;
   - deaktiviert heißt `Semantics.enabled == false`;
   - der Stepper ist einstellbar (`increasedValue`/`decreasedValue`, `SemanticsAction.increase` erhöht).
2. `rows_test.dart`: Bei 320 px und 2,0× Text überlappt nichts. Die Trenner beginnen auf der x-Position des Titeltexts, das ist ein Ergebnis und kein Pixel-Pin.
3. `states_test.dart` oder `lists_test.dart`: Ein Schritt liest sich als „Schritt 2 von 3".

Jeder Test muss einmal gegen eine absichtlich falsche Variante rot gewesen sein.

---

## c) Icon-Entscheidung

### Reicht die bestehende Familie?

Nein. Die eigene Familie (`AppSymbol` und die Painter) hat 6 plus rund 30 Glyphen und deckt nur die Tab-Wurzeln ab. Für die übrigen 178 Glyphen nutzt die App Material Icons. Dort ist „Rounded" **gefüllt** und „Outlined" **kontur, aber eckig**. Eine Kontur mit runden Enden, wie sie die eigenen Glyphen haben, gibt es in Material Icons nur für einzelne `_outline_rounded`-Namen. Darum mischt der Code heute zwangsläufig.

### Optionen

| Kriterium | **A: Material Symbols Rounded** (`material_symbols_icons`) | B: Material Icons (keine neue Abhängigkeit) | C: Lucide (`lucide_icons_flutter`) | D: Phosphor (`phosphor_flutter`) |
|---|---|---|---|---|
| Passt zu den eigenen Strich-Glyphen (1,9–2,0 px, runde Kappen) | **ja**: wght 400 ≈ 2 px bei 24, runde Enden, Achsen für Gewicht und Grad | teilweise: Outlined hat eckige Enden | ja: 2 px, rund | eher nein: regular 1,5 px, bold zu schwer |
| Zustand durch Füllung | **FILL-Achse 0→1, animierbar** (`Icon(fill:)`, Flutter-SDK `icon.dart`) | nur durch einen Glyph-Tausch | **keine** Füllvarianten | eigener Fill-Font |
| Abbildbarkeit der 178 Glyphen | **176 von 178 1:1 per Namen** (geprüft gegen `symbols.dart` 4.2960.0), `copy` → `content_copy` | 178 | manuell, Lücken (z. B. `health_and_safety`, `workspace_premium`) | manuell, 772 Icons |
| Lizenz | Apache-2.0 (Paket und Glyphen) | im SDK | MIT (Paket), ISC (Lucide) | MIT |
| Pflege | aktiv, verifizierter Publisher, 4.2960.0 vom Juli 2026 (Symbols 2.960) | SDK | aktiv (4.0.1) | **zuletzt vor ~2 Jahren** (2.1.0) |
| Bundle | Font Rounded 15,1 MB, Outlined 10,6 MB, Sharp 8,8 MB, **ungeschüttelt**. Im Release-Build schüttelt Flutter auf genutzte Glyphen; nicht referenzierte Stile schrumpfen auf ~2 kB (Paket-Doku). **Muss gemessen werden.** | 0 | Tree-Shaking laut Paket | unbekannt |
| Aufwand | Umbenennen mit Tabelle (Anhang A) plus Fill-Entscheidung je Zustand | Regel und Umbenennen | alles neu zuordnen und prüfen | alles neu zuordnen |
| Mischungsrisiko | gering: eine Familie, eine Achse, Guard-Test | bleibt: zwei Ecken-Sprachen | Füllzustände fehlen und erzwingen Mischung | ein Gewicht zu leicht |

### Empfehlung: Option A

`material_symbols_icons` (Version zur Bauzeit prüfen, Stand 4.2960.0), **nur Rounded**, über `AppIcons`.

Begründung:

- Es ist die einzige Option, die (1) die Strich-Sprache der Tab-Wurzeln trifft, (2) einen echten Füllzustand hat und (3) die bestehenden Namen fast vollständig übernimmt.
- `AppIcons` entkoppelt die Screens vom Paket. Lehnt der Owner die Abhängigkeit ab, zeigt Agent 2 dieselben Konzepte auf Option B (Material Icons) um. Die Screens bleiben unberührt; nur die Fill-Zustände fallen auf Glyph-Tausch zurück.

**Fallback B**, falls der Owner Nein sagt:

- Objekt-Glyphen in `_outlined`, Linien-Glyphen (Haken, Plus, Pfeile, Chevrons) in `_rounded`, ein „an" als `_rounded` (gefüllt).
- Ehrliche Folge: Zwei Ecken-Sprachen bleiben, aber kein Konzept hat mehr zwei Glyphen.

**Pflicht-Prüfungen für Agent 2, bevor er die Abhängigkeit committet:**

1. **Lockfile:** Vorher die Flutter-Version prüfen (3.47.2, `AGENTS.md`). Nur `material_symbols_icons` kommt hinzu; keine anderen Upgrades in `pubspec.lock`.
2. **Release-Größe:** `flutter build apk --release --target-platform android-arm64` mit Dummy-Defines. Im Log steht „Font asset "MaterialSymbolsRounded.ttf" was tree-shaken, reducing it from 15073408 to N bytes".
   - Ziel: N ≤ 250 kB; Outlined und Sharp jeweils wenige kB.
   - APK-Zuwachs ≤ 300 kB gegenüber `main`.
   - Die Werte gehören in den Bericht. Zu prüfen ist auch, dass kein `IconData` dynamisch entsteht (heute 0 Treffer) und nirgends `SymbolsGet`/`symbols_map.dart` importiert wird (beides schaltet das Shaking ab).
3. **Achsen nach dem Subsetting:** In einem Release-Build auf Emulator oder Gerät muss `fill: 0` sichtbar von `fill: 1` abweichen; `grade` −25 gegen 0 ebenso. Ein Screenshot gehört in den Bericht. Widget-Tests können das nicht zeigen: Sie nutzen den ungeschüttelten Font.
4. **iOS:** `ios.yml` baut Release ohne Signierung; das Shaking-Log dort prüfen, sobald der PR läuft.

**Größenregel:** siehe `AppIconSize` (B1). Kurz: 14 Meta, 16 klein, 18 im Button, **20 Standard**, 22 Badge lg und Design-Glyphen, 24 groß.

**Wichtigste Abbildungen** (vollständig in Anhang A):

| Konzept | `AppIcons` | Symbols | heute (Beispiele) | Fill |
|---|---|---|---|---|
| Bearbeiten | `edit` | `edit_rounded` | `edit_outlined` 16×, `edit_rounded` 7×, `drive_file_rename_outline_rounded` | 0 |
| Löschen | `delete` | `delete_rounded` | `delete_outline_rounded` 29× | 0 |
| Hinzufügen | `add` | `add_rounded` | `add_rounded` 26× | – |
| Fertig / Haken | `check` | `check_rounded` | 37× | – |
| Erledigt (Zustand) | `checkCircle` | `check_circle_rounded` | `check_circle_rounded` 28×, `_outline` 7×, `task_alt` | **1 wenn erledigt**, sonst 0 |
| Fehler / Info / Warnung | `error` / `info` / `warning` | `error_rounded` / `info_rounded` / `warning_amber_rounded` | `error_outline_rounded` 37×, `info_outline_rounded` 21× | 0 |
| Erneut | `refresh` | `refresh_rounded` | 20× | – |
| Weiter (Chevron) | `chevronRight` | `chevron_right_rounded` | 19× plus 1× Filled | – |
| Zurück | `chevronLeft` | `chevron_left_rounded` | 6× plus 1× Filled | – |
| Schließen | `close` | `close_rounded` | 11× | – |
| Favorit | `favorite` | `favorite_rounded` | drei Namen | **1 wenn gesetzt** |
| Gespeichert | `bookmarkAdded` | `bookmark_added_rounded` | | 1 |
| Kalender | `calendar` | `calendar_month_rounded` | `calendar_month`, `calendar_today`, `today` | 0 |
| Kopieren | `copy` | `content_copy_rounded` | drei Namen | 0 |
| Gewicht | `monitorWeight` | `monitor_weight_rounded` | `monitor_weight_outlined` 12× | 0 |
| Schritte | – | **`StepsIcon()`** (eigener Fußabdruck) | `directions_walk_rounded` 3× | – |
| Kalorien / Flamme | `flame` | `local_fire_department_rounded` | 6× (plus `TodayGlyph.flame` auf Today) | 0 |
| Einstellungen / Filter | `settings` / `tune` | `settings_rounded` / `tune_rounded` | | 0 |
| Offline | `cloudOff` | `cloud_off_rounded` | 14× | 0 |
| Abspielen / Pause | `playArrow` / `pause` | `play_arrow_rounded` / `pause_rounded` | | **1** |
| KI-Kennzeichen | `aiMark` | `auto_awesome_rounded` | 15× | 0, **Owner-Entscheidung** |

**Mischungs-Wache:** Agent 2 erweitert `test/repo_rules_test.dart` um eine Regel: „kein `Icons.` in `lib/src/theme/`, `lib/src/widgets/design/`, `lib/src/widgets/common/`". Nach dem Merge aller acht Screen-Agents erweitert die Integration sie auf `lib/` (Ausnahme: `app_icons.dart`; `Symbols.` nur dort). Die Regel muss einmal gegen eine absichtlich eingesetzte Zeile rot gewesen sein. Eigene Painter bleiben erlaubt; **neue** Painter-Sets sind verboten.

---

## d) Screen-für-Screen: acht Umsetzungs-Agents mit disjunktem Dateibesitz

**Gemeinsame Regeln für die Agents 3 bis 10:**

- **Besitz:** Nur eure Dateien. `lib/src/theme/**`, `lib/src/widgets/design/**` und `lib/src/widgets/common/**` (außer `app_snack.dart`) gehören Agent 2. `lib/src/app/**` gehört niemandem. Wünsche gehen in den Bericht.
- **Tests:** Jeder Agent besitzt die Tests seiner Pfade. Geteilte Tests (`test/flows/**`, `test/a11y_*`, `test/responsive/**`, `test/text_scale_stress_test.dart`) bekommen nur mechanische Finder-Updates (`Icons.x` → `AppIcons.x`). Konflikte löst die Integration.
- **Keys und Texte bleiben** (`DESIGN_REFACTOR.md` §6). Neue ARB-Keys kommen in euren Namensraum direkt neben verwandte Keys, **nie ans Dateiende**. Danach `flutter gen-l10n`.
- **Komponenten:** keine neuen privaten Buttons, Zeilen, Pills, Kacheln oder Stepper, wo B2–B11 sie liefern. Icons nur über `AppIcons`.
- **Sorgfalt:** Formatierung nur in geänderten Zeilen. Keine Lockfile-Änderung.
- **Prioritäten:** **P1** muss, **P2** soll, **P3** kann, wenn Zeit bleibt.

### Agent 2: Basis-Schicht (zuerst, allein)

**Besitzt:**

- `lib/src/theme/**`, neu `app_icons.dart`;
- `lib/src/widgets/design/**`, neu `lists.dart`;
- `lib/src/widgets/common/**` außer `app_snack.dart`;
- `lib/src/widgets/recipes/recipe_sections.dart` (Wrapper auf B8);
- `pubspec.yaml` und `pubspec.lock` (nur die eine Abhängigkeit);
- `test/theme/**`, `test/widgets/design/**`, `test/widgets/common/**`;
- `test/support/design_capture.dart`;
- `test/design/soft_controls_test.dart`, `test/design/dialogs_capture_test.dart`, `test/design/decision_card_motion_test.dart`;
- die `Icons`-Regel in `test/repo_rules_test.dart`;
- `lib/l10n/*.arb` nur für `commonStepOf`, `commonIncrease`, `commonDecrease`.

**Liefert:** B0 bis B12 und Anhang A in `app_icons.dart`.

**Darf nicht:**

- Screens anfassen; Ausnahme ist die eine Datei `recipe_sections.dart`;
- bestehende Token-Werte oder Radien ändern;
- das Aussehen von `PrimaryActionButton`, `EatovaDialog` oder `LitSurface` ändern; nur Icon-Migration und die Ergänzungen oben sind erlaubt.

### Agent 3: Today

**Besitzt:** `lib/src/screens/today/**`, nach dem Merge von first-entry auch `today_first_entry.dart`, und `test/screens/today/**`, `test/flows/today_*`.

1. **P1** „Nicht jetzt" und „Später" → `SoftPillTone.quiet`: `today_health_prompt.dart:180`, `today_reminder_prompt.dart:130`, `today_energy_check.dart:104`, `today_target_reached.dart:100` (prüfen, ob dort ein Ablehnen steht oder eine Alternative).
2. **P1** Die sieben Prompt-Karten (Gesundheit, Gewicht-Import, Erinnerung, Wochencheck, Energiecheck, Ziel erreicht, Legacy) bekommen **einen** gemeinsamen privaten Aufbau in `today/`:
   - `IconBadge.md` mit Ton `accent`, Titel `title2`, Text `callout`;
   - `PrimaryActionButton(compact)` plus `quiet`.

   Heute ist jede Karte eigen gebaut, z. B. `today_health_prompt.dart:130–140` und `IconTile` in `today_reminder_prompt.dart:80`, `today_weekly_check.dart:161`, `today_energy_check.dart:70`, `today_target_reached.dart:68`.
3. **P1** Icons → `AppIcons`: `today_health_prompt.dart:74/173`, `today_reminder_prompt.dart:124`, `today_weekly_check.dart:85`, `today_weigh.dart:248`, `today_energy_check.dart:70`, `today_target_reached.dart:68`. Für den Sterne-Glyph `today_legacy_notice.dart:202` gilt die Owner-Entscheidung.
4. **P2** `_GlyphTile` (`today_sections.dart:49–69`) → `IconBadge.lg` mit `child: TodayGlyphIcon`.
5. **P2** `_AddButton` (`today_sections.dart:462`) → `AppIconButton` (`accent`, der nächste offene Slot `primary`). Keys bleiben.
6. **P2** Aktivitätskarte: `TodayStepsRow` (`:613`), `_HealthMissingRow` (`:757`) und `_WorkoutRow` (`:810`) folgen der `ListRow`-Anatomie in der Karte: Trenner an der Textspalte, Chevron nur bei Navigation.
7. **P2** Pills: `_StreakPill` (`today_screen.dart:535`), `_EatenPill` (`today_hero.dart:148`) und `_WeighChip` (`today_weigh.dart:177`) → `StatusPill`. Ist das Element tippbar (Gewicht-Chip öffnet ein Sheet), wird es `SoftPillButton(neutral, compact)`.
8. **P2** Chevrons `today_streak_hint.dart:66` und `today_trends.dart:113` → 20/`ink3`.
9. **P3** Abschnitt „Mahlzeiten" mit Link → `SectionHeading(action:)`.
10. **P3** Zahlen in Figtree mit `tabular: true` (Tageswerte in den Zeilen).

**Nicht anfassen:**

- Kalorienkarte und Bogen (`today_hero.dart`), Tagesstreifen (`today_day_strip.dart`), Makro-Kacheln (Layout);
- Erst-Viewport-Vertrag (`test/flows/today_first_viewport_test.dart`);
- alles außerhalb von `today/`.

### Agent 4: Food mit Add-Sheet und Erfassung

**Besitzt:**

- `lib/src/screens/meal_analysis_screen.dart` (Food-Tab), `barcode_scanner_sheet.dart`, `meal_camera_sheet.dart`;
- `lib/src/widgets/kcal/**`, `lib/src/widgets/meal/**`;
- zugehörige Tests (`test/widgets/kcal/**`, `test/flows/food_*`, `test/food*`, `test/add_meal_*`, `test/meal_*`).

1. **P1** Fünf Stepper → `AppStepper`:
   - `edit_meal_sheet.dart:726/786`
   - `meal_describe_draft.dart:755/863`
   - `meal_suggestion_item.dart:642/765`
   - `meal_widgets_adjust.dart:794–822` (heute `GestureDetector` ohne Druck- und Deaktiviert-Zustand)

   Langer Druck bleibt erhalten. Keys bleiben.
2. **P1** Rohe `IconButton` → `AppIconButton`:
   - `add_meal_sheet.dart:2134` (leeren, `plain`) und `:2141` (Suchen, `accent`, heute 40 px);
   - `existing_meals_list.dart:202`, `favorites_sheet.dart:590`, `food_date_picker.dart:546`;
   - `food_page_chrome.dart:106` (Tag-Pfeile, `plain`);
   - `meal_describe_draft.dart:63`, `saved_meal_presentation.dart:502` (Favorit, `selected:` mit Fill-Zustand), `meal_widgets_adjust.dart:617`.
3. **P1** Icons → `AppIcons`, vor allem die vier „Bearbeiten":
   - `add_meal_sheet.dart:1527/1542/2350`, `edit_meal_sheet.dart:514`;
   - `meal_analysis_sheet.dart:658/752/813`, `meal_describe_sheet.dart:1869/1933`, `meal_entry_methods.dart:40/63`;
   - `edit_meal_sheet.dart:654`, `meal_widgets_adjust.dart:455/762`, `meal_widgets_cards.dart:42/79`;
   - Scanner und Kamera: `barcode_scanner_sheet.dart:537/549/555`, `meal_camera_sheet.dart:510/520/745`.
4. **P1** Leer und Fehler über `CalmState` und `SignalNote`: `_EmptyDraft` (`meal_describe_draft.dart:236`), `_AnalysisErrorCard` (`meal_analysis_sheet.dart:720`), `_ErrorCard` (`meal_describe_sheet.dart:1837`), `_EmptyState` (`add_meal_sheet.dart:2439`).
5. **P1** Eyebrow 9,5 px → mindestens 11 (`barcode_scanner_sheet.dart:624`).
6. **P2** Runde Buttons: `_RoundDockButton` (`food_page_chrome.dart:613`), `MealQuickAddButton` (`saved_meal_presentation.dart:433`) und `_AddButton` (`meal_suggestion_item.dart:523`, der lit „+") werden zu `AppIconButton` in den Tönen `neutral`, `accent` und `primary`, Größe `regular`/`large`. Der Kamera-Auslöser `_RoundButton` (`meal_camera_sheet.dart:765–860`) bleibt als Sonderfall über einem Foto (`onImage`). Nur sein roher Spinner (`:856`) wird `AppSpinner`, und `Colors.white`/`Colors.black` (`:852–858`) werden die Tokens `onImage`/`imageAccent`. Die Allowlist von `repo_rules` dabei prüfen.
7. **P2** Zeilen → `ListRow`-Anatomie:
   - `MealItemRow` (`saved_meal_presentation.dart:114`), `_ExistingMealRow` (`existing_meals_list.dart:141`);
   - `_MethodRow` (`meal_entry_methods.dart:188`), `_ManualEntryRow` (`add_meal_sheet.dart:2312`), `_FavoritesEntryRow` (`add_meal_sheet.dart:2205`).
8. **P2** Diary-Karte: Die Kacheln von `_AddRow` und `_RepeatRow` (`diary_meal_card.dart:348/404`, 36 px) → `IconBadge.sm`. Das Layout der Design-Karte bleibt.
9. **P2** `_SortChips` (`favorites_sheet.dart:615`) und `_ModeChips` (`manual_meal_sheet.dart:752`) → `FilterChipPill`. `_LanguagePill` (`meal_describe_sheet.dart:1519`) → `FilterChipPill(sm)`.
10. **P3** Sterne-Glyphen in `meal_camera_sheet.dart:598`, `meal_analysis_sheet.dart:773` und `meal_describe_sheet.dart:1018/1711/1890` nach Owner-Entscheidung.

**Nicht anfassen:**

- Dock-Geometrie und Food-Tagesansicht laut `FOOD-DESIGN.md`;
- die Slot-Segmentwahl und `SlotIconTile`;
- Scanner- und Kamera-Lebenszyklus;
- Logik-Dateien der Feature-Branches (own-food-suggestions).

### Agent 5: Rezepte mit Detail und Kochmodus

**Besitzt:**

- `lib/src/screens/recipes/**` **außer** `meal_plan_*.dart`;
- `lib/src/widgets/recipes/**` außer `recipe_sections.dart`;
- nach dem Merge von cooking-mode dessen neue Kochmodus-Dateien;
- `test/recipes*`, `test/widgets/recipes/**`, `test/flows/recipe_*`.

1. **P1** `recipe_create_sheet.dart:1085–1103`: Der überlagerte Spinner fällt weg, stattdessen `PrimaryActionButton(busy: _saving)`. Konflikt mit servings-basis, also rebasen.
2. **P1** Icons → `AppIcons`:
   - `recipe_detail.dart:567/577/652/671/731`;
   - `recipe_import_sheet.dart:747/1059/1090/1099/1112/1147/1261`;
   - `recipe_create_sheet.dart:1639/1647/1679`;
   - `recipe_ingredient_editor.dart:187/538`.
3. **P1** Kochmodus (neu aus dem Branch):
   - Schritte über `NumberedSteps` und `StepNumber(32)`, Text `body` mit 17 px;
   - ein `AppIconButton(large)` für Weiter und Zurück, aktiver Schritt hervorgehoben;
   - nichts Eigenes bauen.
4. **P1** Meta-Pills: `_MetaChip` (`recipes_hero.dart:272`), `_Pill` (`:409`), `_CategoryPill` (`recipe_atoms.dart:182`, Text 10,5 px bei `:198`) und `_TintChip` (`recipe_import_sheet.dart:1443`) → `StatusPill`. `_GlassPill` (`recipes_hero.dart:330`) bleibt auf dem Foto, mit `micro` als Mindestgröße.
5. **P2** `recipes_header.dart:204` (Suche leeren) → `AppIconButton(plain, compact)`. `_FilterButton` (`:229`) → `AppIconButton(neutral)`.
6. **P2** `_BookmarkButton` (`recipes_hero.dart:359`) → `AppIconButton(selected:)`; die Füllung trägt den Zustand. `RecipeGlyph.bookmark` darf bleiben, wenn es auf dem Foto besser liest; dann Fill über `filled:`.
7. **P2** `recipe_ingredient_editor.dart:205` (`_RoundIconButton`) und `:598` (`IconButton`) → `AppIconButton`.
8. **P2** `_RecipeListTile` (`recipe_cards.dart:4–70`): Chevron `ink2` → `ink3` (`:65`), Abstände nach `ListRow`. Das Foto als führendes Element mit `rThumb` bleibt.
9. **P2** Nährwert-Kachel-Eyebrow 10,5 → 11 (`recipe_detail.dart:858`). Die Kandidaten-Nummer `recipe_import_sheet.dart:917` → `StepNumber(32)`.
10. **P3** `_SheetToggleRow` (`recipe_create_sheet.dart:1445`) → `ListRow(trailing: toggle)`. `_AddPhotoTile` (`:1666`) und `InkResponse` (`:1719`) → `IconBadge` mit `AppIconButton`. Der Zurück-Knopf im Detail (`recipe_detail.dart:437`) ist mit B3 automatisch rund; die Kopfzeile prüfen.

**Nicht anfassen:**

- Tab-Wurzel-Layout (Hero „Für heute Abend", Regale, Chip-Leiste);
- `RecipeGlyph`-Painter;
- Pick-Logik (`recipe_pick_actions.dart`);
- Foto-Lebenszyklus;
- `recipe_sections.dart` (gehört Agent 2).

### Agent 6: Speiseplan und Einkauf

**Besitzt:** `lib/src/screens/recipes/meal_plan_screen.dart`, `meal_plan_editor.dart`, `meal_plan_shopping.dart`, `meal_plan_week.dart`, nach dem Merge von week-plan dessen UI-Dateien, und `test/meal_plan*`, `test/shopping*`.

1. **P1** `_ShoppingEmpty` (`meal_plan_shopping.dart:9–59`) → `CalmState(card: true)`. Key `shopping-empty-plan` bleibt auf der Aktion.
2. **P1** `_ServingsStepper` und `_ServingsStepButton` (`meal_plan_editor.dart:419/557`) → `AppStepper`.
3. **P1** Eyebrow 9,5 → mindestens 11 (`meal_plan_editor.dart:409`). `Icons.check_circle_outline` (Filled-Stil, `:130`) → `AppIcons.checkCircle`.
4. **P1** Icons → `AppIcons` (`meal_plan_screen.dart:202/776`, `meal_plan_shopping.dart:31`).
5. **P2** `_RoundAddButton` (`meal_plan_week.dart:434`) → `AppIconButton(accent)`.
6. **P2** `_EatToggle` (`meal_plan_week.dart:366`) → `AppIconButton(selected:)` mit `AppIcons.checkCircle`, Fill 1 bei gegessen. Semantik `toggled`.
7. **P2** `_PlanMealRow` und `_MealRow` (`meal_plan_week.dart:218/485`, Kachel 30 bei `:42`) → `IconBadge.sm` und `ListRow`-Abstände.
8. **P2** `_PantryToggle` (`meal_plan_shopping.dart:629`) → Disclosure-Zeile: `ListRow` mit `AppIcons.expandMore`, der in `kMotionValue` dreht, und `Semantics(expanded:)`.
9. **P2** `_EmptyRecipesNote` und `_EmptyRecipeLink` (`meal_plan_shopping.dart:700/747`) → `SignalNote` mit `EatovaTextAction`.
10. **P3** Wochen-Zusammenfassung: Zahlen in Figtree mit `tabular: true`; Sektionsköpfe → `SectionHeading`.

**Nicht anfassen:**

- den Bon: DM Mono, Zackenrand, Stempel, Haken bleiben an Ort und Stelle;
- Wochen- und Check-Logik;
- `eatPlannedMeal`-Weg.

### Agent 7: Training mit Player

**Besitzt:** `lib/src/screens/training/**` inklusive `player/`, nach dem Merge des training-Branch dessen UI-Dateien, und `test/training/**`, `test/training_*`.

1. **P1** Nummern: `TrainingExerciseList` (`training_exercise_list.dart:17–50`, „01" in `ink2`) und der Editor-Kopf (`training_plan_editor.dart:789`, „01" in `accentText`) → `StepNumber`. Die Messlogik für die Spaltenbreite entfällt.
2. **P1** Rohe `IconButton` → `AppIconButton`: `player_exercise_card.dart:124/167`, `training_log_editor.dart:949/1117`.
3. **P1** `TrainingRoundButton` (`training_overview_widgets.dart:568–620`, 54 px `surf2`, roher Spinner bei `:606`) → `AppIconButton(large, neutral, busy:)`. Der Klassenname bleibt als Wrapper.
4. **P1** Eyebrows 9,5 und 10,5 → mindestens 11 (`training_log_editor.dart:896`, `player_exercise_card.dart:416`).
5. **P2** Finish im Player-Kopf (`player_header.dart:57`, ein `FilledButton`, der eine Soft-Pill imitiert) → `SoftPillButton(accent)`. Key `training-timer-finish` bleibt. Keine vertikale Polsterung, damit der kompakte Kopf bei großem Text nicht wächst.
6. **P2** `player_set_row.dart:156` (`TextButton`) und `training_plan_picker.dart:272` (`TextButton`) → `EatovaTextAction`.
7. **P2** `_SuggestionPill` (`training_log_fields.dart:196`) → `FilterChipPill(sm)`. `_AlertsOffChip` (`player_rest_bar.dart:412`) bleibt tippbar und wird `SoftPillButton(neutral, compact)` mit `AppIcons.notificationsOff`. `_DoneToggle` (`training_log_fields.dart:231`) → `AppIconButton(selected:)`.
8. **P2** Icons → `AppIcons`:
   - Pokal `training_overview_widgets.dart:1339/1393`, `training_exercise_history_screen.dart:136`;
   - `training_exercise_list.dart:101`;
   - `training_screen.dart:450`, `training_plan_editor.dart:386`, `training_player_screen.dart:510`.
9. **P2** Zeilen: `_RecentRow` (`training_overview_widgets.dart:1171`), `_HistoryRow` (`training_history_screen.dart:153`) und `_ProgressRow` (`training_exercise_history_screen.dart:57`) → `ListRow`-Anatomie, Chevron 22 → 20.
10. **P3** `PlayerSetButton` (`player_set_row.dart:338`, ✓ 56): Die Zustände an `AppIconButton(large)` angleichen. Aktiv ist lit, also die eine Aktion der Ansicht; inaktiv sichtbar deaktiviert. Die Ledger-Logik bleibt.

**Nicht anfassen:**

- Player-Ablauf, Timer, Rest-Bar-Geometrie (40-%-Kappe), Benachrichtigungen, Keep-Awake;
- Studio-Artwork und Duotone;
- Plan- und Session-Controller.

### Agent 8: Coach

**Besitzt:** `lib/src/screens/coach/**` und `test/coach*`, `test/coach/**`.

1. **P1** `_StepperRow` und `_StepButton` (`coach_training_brief.dart:885/1025`) → `AppStepper`.
2. **P1** Composer: `_SendButton` (`coach_composer.dart:640`; lit, sobald Text da ist), `_MicButton` (`:467`, `accent`, beim Zuhören `selected`) und `_AttachTile` (`:707`, `IconTile` 36 bei `:732`) → `AppIconButton` und `IconBadge`. Composer-Höhe und Keys bleiben.
3. **P1** Icons → `AppIcons`:
   - `coach_chat_screen.dart:1567/1577`;
   - `coach_recipe.dart:55/124/291/424/434/450`;
   - `coach_training_brief.dart:366/496`.

   Sterne in `coach_composer.dart:169/867` und `coach_chat_screen.dart:1769`: Der Coach trägt seit 2026-09-07 das Gesprächs-Symbol. Danach richtet sich die Owner-Entscheidung.
4. **P1** `_ErrorBanner` (`coach_message_list.dart:608`) → `SignalNote(boxed: true, tone: danger, action: Retry)`.
5. **P2** `coach_sessions.dart:171` (`IconButton` Löschen) → `AppIconButton(plain)` mit 48-px-Ziel. `_SessionTile` (`:107`, `IconTile` 32 bei `:140`) → `ListRow` mit `IconBadge.sm`.
6. **P2** `_TryChip` (`coach_hero.dart:439`) → `FilterChipPill`, ohne Auswahlzustand, als Vorschlag. `_CardPill` (`:320`) → `StatusPill`. `_DictationLanguagePill` (`coach_composer.dart:582`) → `FilterChipPill(sm)`.
7. **P2** Rezept-Karte im Chat: Zutaten und Schritte laufen über `RecipeIngredientLines` und `RecipePreparationSteps` (`coach_recipe.dart:426/436`) und übernehmen damit B8. Die Abstände der Kopf-Kacheln → `IconBadge.sm`.
8. **P2** Die `GestureDetector` in `coach_message_list.dart:90/525` und `coach_recipe.dart:149` prüfen: Wo eine Aktion dahinter steckt, braucht es `Semantics(button:)` und `PressScale`.
9. **P3** Session-Liste und Info-Sheet: `SectionHeading` und `ListSection`.
10. **P3** Zahlen (Quota, Wochen-Brief) in Figtree mit `tabular: true`.

**Nicht anfassen:**

- Orb (`coach_orb.dart`), Nachrichtenblasen-Layout und Stream-Logik;
- KI-Offenlegungstexte (`coach-ai-note`) und Quota-Logik;
- Rezept-Bestätigung: nichts wird vor einer expliziten Bestätigung geschrieben.

### Agent 9: Profil, Einstellungen, Premium, Abo

**Besitzt:**

- `lib/src/screens/profile_screen.dart`, `lib/src/screens/settings/**`, `lib/src/screens/premium/**`, `lib/src/widgets/profile/**`;
- `test/settings*`, `test/profile*`, `test/premium*`, `test/subscription/**`, `test/widgets/profile_*`, `test/account_*`.

1. **P1** `SettingsStudioGroup`, `SettingsStudioRow` und `SettingsRowTile` (`settings_studio_widgets.dart:27/131/100`) sowie `SettingsGlyphTile` (`settings_controls.dart:243`) → Wrapper auf `ListSection`, `ListRow` und `IconBadge.md`. Klassennamen und Keys bleiben. Der Sektionskopf geht von Display 19 auf `section` 17.
2. **P1** `goals_screen.dart:768–1110`: Der Mix aus Studio-Gruppe und `SettingsRow` wird einheitlich `ListRow`. `_tile(...)` → `IconBadge.md`. `directions_walk_rounded` (`:853`) → `StepsIcon`.
3. **P1** Chevron-Regel:
   - Abmelden (`settings_screen.dart:612–614`) und Löschen (`:633`) ohne Chevron;
   - Rechtliches (`:538–550`) → `external`;
   - nur navigierende Zeilen behalten `›`.
4. **P1** Icons → `AppIcons`:
   - `settings_screen.dart:277–280/337/347/371/442/484/497/529/538/544/550/557/568/614/633/793–811/1126`;
   - `goals_screen.dart:774/784/802/865/1107/1169`;
   - `settings_plan_hero.dart:144/145/225`, `settings_ai_data.dart:57/110`, `settings_reminder_row.dart:120/174/265`;
   - `profile_screen.dart:146/195`;
   - `food_preferences_sheet.dart:61/69/205–207/339`;
   - `profile_widgets_body.dart:48`, `profile_widgets_hero.dart:428`, `subscription_card.dart:384`.
5. **P1** Eyebrows 9,5 und 10,5 → mindestens 11 (`account_change_sheets.dart:748`, `profile_widgets_hero.dart:566`).
6. **P2** Picker-Sheets (`settings_pickers.dart:147/187`): `SettingsGroup` und `SettingsRow` → `ListSection` und `ListRow` mit `check` als Trailing.
7. **P2** Profil-Pills: `_IdentityPill` (`profile_widgets_hero.dart:196`), `_DeltaPill` (`profile_widgets_body.dart:943`) und `_ZonePill` (`:1102`) → `StatusPill`.
8. **P2** Profil-Aktionen:
   - `_CardActionButton` (`profile_widgets_body.dart:1326`) und `_CompactButton` (`profile_widgets_actions.dart:417`) → `SoftPillButton(compact)`;
   - `TextButton` (`profile_widgets_actions.dart:325/351`) → `EatovaTextAction`;
   - `favorite_border_rounded` (`:115`) → `AppIcons.favorite` mit Fill-Zustand;
   - `directions_walk` (`:274`, `profile_widgets_hero.dart:61`) → `StepsIcon`.
9. **P2** `_PreferenceRow` (`food_preferences_sheet.dart:96`) → `ListRow`.
10. **P3** Paywall und Abo (#174): **nur** die Icons (`paywall_sections.dart:668/1466/1490`). Die Ledger-Zeilen bleiben, ebenso Kauf-Fuß, Testzeitraum, Texte und Layout.

**Nicht anfassen:**

- Paywall- und Abo-Karten-Design, Sign-out-Karte;
- `SecureScreenGuard`;
- Rechtstexte sowie Store- und Legal-Regeln aus `PREMIUM.md` 1.2 und 4.3;
- die Segment-Pille `_SettingsChoicePill` (bleibt das Segment-Control);
- Kontolöschung und Re-Auth-Abläufe.

### Agent 10: Onboarding, Auth, Trends, gemeinsame Sheets und Snackbar

**Besitzt:**

- `lib/src/screens/onboarding_screen.dart`, `lib/src/screens/onboarding/**`;
- `lib/src/screens/auth_screen.dart`, `auth_code_screen.dart`, `lib/src/widgets/auth/**`;
- `lib/src/screens/trends_screen.dart`, `lib/src/widgets/shared/**`, `lib/src/widgets/common/app_snack.dart`;
- `test/auth*`, `test/onboarding*`, `test/trends/**`, `test/ai_consent/**`, `test/widgets/shared/**`, `test/app_snack_test.dart`, `test/design/onboarding_capture_test.dart`, `test/design/boot_error_capture_test.dart`.

1. **P1** **A11y-Fix Toast** (`app_snack.dart:363–399`): `_AutoDismiss` lässt einen Toast **mit Aktion** stehen, solange `MediaQuery.accessibleNavigationOf(context)` wahr ist. So verhält sich Flutters eigene SnackBar (`snack_bar.dart:227`). Dazu genau ein Regressionstest in `test/app_snack_test.dart`, der ohne den Fix rot ist. Die Ton-Glyphen (`:35–40`) → `AppIcons`.
2. **P1** `AuthPrimaryButton` (`auth_controls.dart:482–516`) → `PrimaryActionButton(busy: loading)`. `buttonKey`, `label` und die Semantik „deaktiviert während des Ladens" bleiben. Die Auth-Tests prüfen.
3. **P1** `_GoogleButton` (`auth_screen.dart:442`): Der rohe Spinner wird `AppSpinner(color: inkMuted)`. Die Google-Marke bleibt unverändert (Branding).
4. **P1** Onboarding-Stepper `_StepperButton` (`onboarding_controls.dart:434–520`) → `AppStepper`. Keys und die Labels `onboardingStepDown/UpSemanticLabel` bleiben.
5. **P1** `export_sections.dart:291` (`expand_less/more` Filled) und `:348–360` (`IconButton` mit Filled-Chevrons) → `AppIconButton(plain)` mit `AppIcons`. `:314/322` → `AppIcons`.
6. **P2** Trends: `_EmptyCard` (`trends_screen.dart:1529`) und `_ErrorCard` (`:1594`) → `CalmState(card: true)`. Der Kopf (`:213`) wird mit B3 automatisch rund. Die Eyebrows (`:879/939`) kommen durch den neuen Default auf 11; die Diagramm-Beschriftung danach prüfen.
7. **P2** Onboarding: `onboarding_plan_step.dart:761` (`SettingsRow`) → `ListRow`. Icons `:180/430/575/768`, `onboarding_question_steps.dart:346/392–394/441` → `AppIcons`.
8. **P2** Export-Sheet: `data_export_sheet.dart:249` (nacktes 28-px-Icon) → `IconBadge.lg`. `_CopyButton` und `_ShareFileButton` (`:405/424`) → `SoftPillButton`.
9. **P2** Gemeinsame Sheets: `ai_consent_sheet.dart:131/132`, `ai_report_sheet.dart:53/172` und `plan_limit_notice.dart:253` → `AppIcons` und `IconBadge`. Die Sterne folgen der Owner-Entscheidung.
10. **P3** `auth_code_screen.dart:927` → `AppIcons.markEmailUnread`. Die 8-stelligen Code-Zellen bleiben.

**Nicht anfassen:**

- Willkommens-Animation und Splash (`welcome_screen.dart`, Marken-Fläche in beiden Modi);
- Auth-Logik, Enumeration-Schutz und neutrale Texte;
- Google-„G";
- Diagramm-Rendering in Trends;
- Toast-Dauern (Owner-Frage, siehe unten).

---

## e) Prüfweg

### Vorher und nachher aufnehmen

Die Harness ist `test/support/design_capture.dart`: 390 × 844 logisch, DPR 2, Safe Area 47/34, echte gebündelte Fonts, echte Schatten.

1. **Vor jeder Änderung** im eigenen Worktree die alten Szenen holen. Die Capture-Suites haben am 2026-10-21 den Testlauf verlassen und liegen in `7a05b818`:

   ```bash
   git show 7a05b818:test/design/<suite>_capture_test.dart > test/design/<suite>_capture_test.dart
   ```

   | Agent | Suites |
   |---|---|
   | 3 | `today_redesign`, `energy_check` |
   | 4 | `food_redesign`, `food_states`, `add_items_polish`, `add_sheet_polish`, `meal_describe`, `meal_sheets`, `slots_polish` |
   | 5 | `recipes_redesign`, `recipes_lists`, `recipe_create`, `recipe_import` |
   | 6 | `meal_plan` |
   | 7 | `training_redesign`, `training_player`, `training_editors` |
   | 8 | `coach_redesign`, `coach_cards` |
   | 9 | `profile_polish`, `settings_polish`, dazu der aktuelle `test/design/paywall_capture_test.dart` |
   | 10 | `auth_polish`, `misc_sheets`, `feedback_states`, `feedback_surfaces`, `leftovers_polish`, dazu die aktuellen `onboarding_capture_test.dart` und `boot_error_capture_test.dart` |
   | 2 | `dark_redesign` (alle Tabs), `soft_controls_test.dart`, `dialogs_capture_test.dart` |

   Kompiliert eine alte Suite nicht mehr (APIs haben sich geändert), wird sie im Worktree minimal angepasst oder als Scratch-Test mit `captureDesignShot` neu geschrieben.
2. **Aufnehmen**, dunkel und hell. Volle Pfade benutzen, nie `pub get`:

   ```bash
   C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test test/design/<suite>_capture_test.dart \
     --dart-define=DARK_REDESIGN_CAPTURE=true \
     --dart-define=SUPABASE_URL=https://ci.invalid --dart-define=SUPABASE_ANON_KEY=ci-dummy-key
   # hell: zusätzlich --dart-define=DESIGN_CAPTURE_BRIGHTNESS=light  (→ build/light-redesign/)
   ```

   Die PNGs landen in `build/dark-redesign/` und werden nach `build/ui-polish/<agent>/before/` kopiert. Nach der Umsetzung dieselben Läufe nach `build/ui-polish/<agent>/after/`. Vorher- und Nachher-Bild heißen gleich. Zusätzlich je Screen **eine** Aufnahme bei 320 × 568 mit Textskalierung 2,0 (`tester.view.physicalSize` und `MediaQuery`-Textscaler im Scratch-Test).
3. **Captures sind Belege, keine Tests** (`CONTRIBUTING.md:175–178`). Wiederhergestellte Suites werden **nicht** committet. Ausnahme ist eine Szene, die kein anderer Test und auch nicht der Layout-Sweep erreicht.
4. **Agent 2 zusätzlich:** Release-Build-Messung und Achsen-Screenshot auf Emulator oder Gerät (Abschnitt c). Dafür muss `loadDesignFonts` den Symbols-Font laden, sonst zeigen alle Aufnahmen Kästchen.

### Verträge, die grün bleiben

- `flutter analyze --fatal-infos --fatal-warnings`: Infos sind fatal.
- `test/theme/app_tokens_test.dart`: Paletten, Kontrast-Rollen in beiden Modi, Form-Skala, Typo-Presets. Neue Tokens sind additiv; vorhandene Werte bleiben.
- `test/theme/` insgesamt: `auswahl_sprache_*`, `review0829_selection_contrast_test.dart`, `hell_modus_audit_test.dart`, `fixwelle_p9_snack_tone_contrast_test.dart`, `macro_tile_and_dock_contrast_test.dart`, `light_glow_test.dart`.
- `test/repo_rules_test.dart`: Token-Disziplin, kein Helligkeits-Abzweig, Überschriften nur über `HeadingSemantics`, Hartkodierungs-Wächter, ARB-Parität, neu die Icon-Regel.
- `test/a11y_controls_test.dart`, `test/a11y_headings_test.dart` (Sprungmarken je Screen samt Rang und Reihenfolge), `test/a11y_reduced_motion_test.dart`, `test/motion_media_query_test.dart`.
- `test/text_scale_stress_test.dart` und `test/responsive/app_layout_sweep_test.dart`: Overflow-Freiheit bis 2,0×, schmale Telefone, große Fenster.
- `test/icon_family_test.dart`: Die eigenen Glyphen bleiben unverändert.
- `test/widgets/design/*` (unter anderem `toggle_tap_target_test.dart`, `sheet_handle_dismiss_test.dart`), `test/design/decision_card_motion_test.dart`, `test/design/soft_controls_test.dart`.
- Die Flow-Tests der eigenen Areas (`test/flows/**`). Erster Viewport auf Today (`today_first_viewport_test.dart`).
- **Vor der Abgabe:** volle Suite mit Dummy-Defines und `--coverage`. Die Coverage-Untergrenze liegt bei 95 %; nach dem Ersetzen von Widgets die Diff-Coverage Zeile für Zeile prüfen.

  ```bash
  flutter test --coverage --dart-define=SUPABASE_URL=https://ci.invalid --dart-define=SUPABASE_ANON_KEY=ci-dummy-key
  ```

- **Tests:** wenige, schneidende (`CONTRIBUTING.md › Writing tests`). Kein Pixel-, Radius- oder Farb-Pin, außer er ist die Anforderung. Für reine Umstylings gibt es keine neuen Tests. Bestehende Finder werden mechanisch angepasst. Die Testanzahl soll nicht wachsen (Owner, 2026-10-21).

---

## f) Was bewusst nicht geändert wird

- **Paletten-Werte, Radius-Skala, Schriften und `kPrimaryButtonHeight`/`kButtonMinHeight`.** Die Basis bekommt nur neue, additive Tokens.
- **Tab-Wurzeln aus `Design.html`:** Layout von Today (Bogen-Karte, Tagesstreifen, Makro-Kacheln), Food (Tag-Pille, Diary-Karten, Dock), Rezepte (Hero, Regale), Training (Woche, nächstes Workout) und Coach (Orb, Composer). Dazu die Glas-Tab-Bar und ihre Bewegung.
- **Die eigenen Glyph-Painter** (`AppIcon`, `SlotIconTile`, `FoodGlyph`, `RecipeGlyph`, `TodayGlyph`, `TrainingWorkoutGlyph`, Exit-Glyph). Sie werden nicht neu gezeichnet und in dieser Runde nicht zusammengelegt, obwohl sich Kalender, Plus, Suche und Chevron in drei Sets doppeln. Neue Painter-Sets kommen nicht hinzu.
- **#174:** Entscheidungskarte, Sign-out-Karte, Paywall, Abo-Karte, `castLight`, Federn, Fokus ohne Ring. Nur Icons werden migriert.
- **Eingabefelder:** randlos, weich gefüllt, Fokus über die Füllung.
- **Die Karten-Haarlinie im Fluss (Ebene 1)** und die Haarlinie der Snackbar. Beide sind begründet. „App-wide card rims" stehen im #174-Handoff als bewusst offen.
- **Die eigene Anzeige-Modus-Einstellung** (System, Hell, Dunkel). HIG `dark-mode.md › Best practices` rät von einem App-eigenen Schalter ab, aber der Owner hat ihn am 2026-10-04 entschieden.
- **Plattform-Adaption:** Android und iOS behalten ein Markendesign. Es gibt keine Cupertino-Widgets; System-Verhalten (Zurück-Wisch, Übergänge) bleibt, wie es ist.
- **Shimmer, Ripples, neue Animationen** jenseits von B12; neue Haptik-Anlässe.
- **ARB-Texte und `ValueKey`s.** Ausnahmen sind die neuen a11y-Keys; jede Umbenennung braucht eine Owner-Freigabe.
- **Bon-Ästhetik** des Einkaufs, Studio-Artwork des Trainings und die Google-Marke.
- **Logik, Store, Services, Backend, Datenflüsse und Quota.** Die einzige Verhaltensänderung ist der Toast-Fix für Screenreader (Agent 10).

---

## Offene Punkte für den Owner

1. **Neue Abhängigkeit `material_symbols_icons`** (Apache-2.0, nur Rounded genutzt): ja oder nein? Bei Nein gilt Fallback B; die Screens bleiben gleich, weil sie nur `AppIcons` kennen. Die Freigabe ist an die Messung in Abschnitt c gebunden (Release-Zuwachs ≤ 300 kB).
2. **Funkel-Sterne (`auto_awesome`, 15×):**
   - Empfehlung: nur als KI-Herkunftszeichen direkt neben dem Wort „KI" (Offenlegung, Consent, KI-Schätzung); überall sonst ein Glyph der Aufgabe (Kamera, Notiz, Dokument), im Coach das Gesprächs-Symbol.
   - Alternative: ganz entfernen, konsequent nach dem Review vom 2026-09-07 und #174.
3. **Nummern in Formular-Abschnitten** (Rezept- und Plan-Editor, „01, 02…"): als `StepNumber` behalten (Empfehlung, weil konsistent) oder streichen, weil es keine echte Folge ist.
4. **Toast mit Undo nach 2,2 s:** Material empfiehlt für Snackbars mit Aktion deutlich längere Standzeiten. Empfehlung: 4 s für Toasts mit Aktion. Der Screenreader-Fix kommt unabhängig davon.
5. **Startzeitpunkt der UI-Runde:** nach dem Merge der zehn `build/2026-11-01-*`-Branches (empfohlen) oder parallel mit Rebase-Pflicht.

---

## Quellen

- Apple HIG (Seiten im `apple-design`-Skill, Stand 2026):
  - [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) (Best practices, Style, Mobile);
  - [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables);
  - [Icons](https://developer.apple.com/design/human-interface-guidelines/icons);
  - [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) (Design variants, Weights and scales);
  - [Typography](https://developer.apple.com/design/human-interface-guidelines/typography);
  - [Layout](https://developer.apple.com/design/human-interface-guidelines/layout);
  - [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility);
  - [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode);
  - [Motion](https://developer.apple.com/design/human-interface-guidelines/motion);
  - [Loading](https://developer.apple.com/design/human-interface-guidelines/loading);
  - [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics).
- Material 3 über die Flutter-SDK-Defaults: `m3.material.io` lädt nur per JavaScript und war nicht abrufbar. Die Werte stammen aus Flutter 3.47.2, generiert aus den M3-Tokens:
  - `packages/flutter/lib/src/material/list_tile.dart` (`_LisTileDefaultsM3`: Einzug 16/24, `minLeadingWidth 24`, Höhen 56/72/88);
  - `motion.dart` (`Durations.short1` 50 ms bis `extralong4` 1000 ms; `Easing.emphasizedDecelerate` = Cubic(0.05, 0.7, 0.1, 1.0));
  - `filled_button.dart` (Mindestgröße 64 × 40, Icon 18);
  - `widgets/icon.dart` (`fill`, `weight`, `grade`, `opticalSize`);
  - `snack_bar.dart:227` (kein Timeout bei `accessibleNavigation`).
- Material Components Android, [Buttons-Doku](https://github.com/material-components/material-components-android/blob/master/docs/components/CommonButton.md): Hierarchie elevated > filled > tonal > outlined > text, fünf Größen, Form-Morph beim Druck.
- [Material Symbols Guide (Google Fonts)](https://developers.google.com/fonts/docs/material_symbols): Grad −25 für helle Symbole auf dunklem Grund.
- [Flutter: Accessibility testing](https://docs.flutter.dev/ui/accessibility/accessibility-testing): `androidTapTargetGuideline` 48 × 48, `iOSTapTargetGuideline` 44 × 44, `labeledTapTargetGuideline`, `textContrastGuideline`.
- NN/g: [Skeleton Screens 101](https://www.nngroup.com/articles/skeleton-screens/), [Designing Empty States](https://www.nngroup.com/articles/empty-state-interface-design/).
- Linear: [How we redesigned the Linear UI](https://linear.app/now/how-we-redesigned-the-linear-ui) (weniger visuelles Rauschen, ausgerichtete Icons und Labels).
- Pakete:
  - [material_symbols_icons](https://pub.dev/packages/material_symbols_icons) mit [README und Größen](https://github.com/timmaffett/material_symbols_icons) und [forceCompileTimeTreeShaking](https://pub.dev/documentation/material_symbols_icons/latest/symbols/Symbols/forceCompileTimeTreeShaking.html);
  - [lucide_icons_flutter](https://pub.dev/packages/lucide_icons_flutter);
  - [phosphor_flutter](https://pub.dev/packages/phosphor_flutter);
  - Abbildbarkeit geprüft gegen `lib/symbols.dart` 4.2960.0 (176 von 178).
- Beispiele hochwertiger Apps (Things, Apple Fitness, MacroFactor, Hevy, Linear): Muster wie eine leise Sekundärsprache, gruppierte runde Listen, tabellarische Zahlen und ein dominanter Satz-Haken. Das ist **Urteil aus Kenntnis der Apps, nicht in dieser Recherche verifiziert**; die Regeln oben stützen sich auf die verlinkten Quellen.
- Repo: `docs/DESIGN_REFACTOR.md` §3–6, `docs/ICON-FAMILY-2026-09-14.md`, `docs/DESIGN-REVIEW-2026-09-07.md`, `docs/PROJECT_HANDOFF.md` (Abschnitt „Decision cards, buttons, paywall…", 2026-10-25), `docs/FEATURES.md` („Current visual contracts"), `CONTRIBUTING.md` („Writing tests").

---

## Anhang A: Vollständige Icon-Abbildung für `AppIcons`

Erzeugt aus allen 690 `Icons.*`-Referenzen in `lib/` (`138f0046`) und geprüft gegen `material_symbols_icons` 4.2960.0. Spalte 3 zeigt die heutigen Namen mit Häufigkeit.

**Fill-Regel:** Fill 1 nur für einen „an"-Zustand (Favorit gesetzt, gespeichert, gegessen oder erledigt, laufende Medien-Steuerung), sonst 0.

Semantische Umbenennungen sind erlaubt, wo sie eindeutig sind: `monitorWeight` → `weight`, `iosShare` → `share`, `soupKitchen` → `cook`, `restaurant` → `meal`. Agent 2 entscheidet sie einmal und hält die Tabelle in seinem Bericht aktuell.

| `AppIcons` | Symbols | heute |
|---|---|---|
| `AppIcons.check` | `Symbols.check_rounded` | check_rounded (37) |
| `AppIcons.error` | `Symbols.error_rounded` | error_outline_rounded (37) |
| `AppIcons.checkCircle` | `Symbols.check_circle_rounded` | check_circle_rounded (28), check_circle_outline_rounded (6), check_circle_outline (1), task_alt_rounded (1) |
| `AppIcons.delete` | `Symbols.delete_rounded` | delete_outline_rounded (29) |
| `AppIcons.add` | `Symbols.add_rounded` | add_rounded (26) |
| `AppIcons.edit` | `Symbols.edit_rounded` | edit_outlined (16), edit_rounded (7), drive_file_rename_outline_rounded (1) |
| `AppIcons.info` | `Symbols.info_rounded` | info_outline_rounded (21) |
| `AppIcons.refresh` | `Symbols.refresh_rounded` | refresh_rounded (20) |
| `AppIcons.chevronRight` | `Symbols.chevron_right_rounded` | chevron_right_rounded (19), chevron_right (1) |
| `AppIcons.aiMark` | `Symbols.auto_awesome_rounded` | auto_awesome_rounded (11), auto_awesome_outlined (4), **Owner-Entscheidung** |
| `AppIcons.tune` | `Symbols.tune_rounded` | tune_rounded (14) |
| `AppIcons.cloudOff` | `Symbols.cloud_off_rounded` | cloud_off_rounded (12), cloud_off_outlined (2) |
| `AppIcons.history` | `Symbols.history_rounded` | history_rounded (12) |
| `AppIcons.monitorWeight` | `Symbols.monitor_weight_rounded` | monitor_weight_outlined (12) |
| `AppIcons.favorite` | `Symbols.favorite_rounded` | favorite_outline_rounded (5), favorite_rounded (5), favorite_border_rounded (2) |
| `AppIcons.close` | `Symbols.close_rounded` | close_rounded (11) |
| `AppIcons.arrowForward` | `Symbols.arrow_forward_rounded` | arrow_forward_rounded (10) |
| `AppIcons.expandMore` | `Symbols.expand_more_rounded` | expand_more_rounded (9), expand_more (1) |
| `AppIcons.openInNew` | `Symbols.open_in_new_rounded` | open_in_new_rounded (9) |
| `AppIcons.remove` | `Symbols.remove_rounded` | remove_rounded (9) |
| `AppIcons.restaurant` | `Symbols.restaurant_rounded` | restaurant_rounded (9) |
| `AppIcons.schedule` | `Symbols.schedule_rounded` | schedule_rounded (9) |
| `AppIcons.flag` | `Symbols.flag_rounded` | flag_outlined (5), flag_rounded (4) |
| `AppIcons.chevronLeft` | `Symbols.chevron_left_rounded` | chevron_left_rounded (6), chevron_left (1) |
| `AppIcons.chatBubble` | `Symbols.chat_bubble_rounded` | chat_bubble_outline_rounded (6) |
| `AppIcons.mic` | `Symbols.mic_none_rounded` | mic_none_rounded (6) |
| `AppIcons.flame` | `Symbols.local_fire_department_rounded` | local_fire_department_rounded (4), local_fire_department_outlined (2) |
| `AppIcons.calendar` | `Symbols.calendar_month_rounded` | calendar_month_rounded (3), calendar_today_rounded (2), today_rounded (1) |
| `AppIcons.editNote` | `Symbols.edit_note_rounded` | edit_note_rounded (5) |
| `AppIcons.lock` | `Symbols.lock_rounded` | lock_outline_rounded (5) |
| `AppIcons.logout` | `Symbols.logout_rounded` | logout_rounded (5) |
| `AppIcons.moreHoriz` | `Symbols.more_horiz_rounded` | more_horiz_rounded (5) |
| `AppIcons.person` | `Symbols.person_rounded` | person_outline_rounded (5) |
| `AppIcons.restore` | `Symbols.restore_rounded` | restore_rounded (5) |
| `AppIcons.settings` | `Symbols.settings_rounded` | settings_outlined (5) |
| `AppIcons.bookmarkAdded` | `Symbols.bookmark_added_rounded` | bookmark_added_rounded (4), bookmark_added_outlined (1) |
| `AppIcons.expandLess` | `Symbols.expand_less_rounded` | expand_less_rounded (4), expand_less (1) |
| `AppIcons.copy` | `Symbols.content_copy_rounded` | content_copy_rounded (3), copy_outlined (1), copy_rounded (1) |
| `AppIcons.trophy` | `Symbols.emoji_events_rounded` | emoji_events_outlined (3), emoji_events_rounded (2) |
| `AppIcons.healthAndSafety` | `Symbols.health_and_safety_rounded` | health_and_safety_outlined (4) |
| `AppIcons.insights` | `Symbols.insights_rounded` | insights_rounded (4) |
| `AppIcons.iosShare` | `Symbols.ios_share_rounded` | ios_share_rounded (4) |
| `AppIcons.notificationsOff` | `Symbols.notifications_off_rounded` | notifications_off_outlined (4) |
| `AppIcons.playArrow` | `Symbols.play_arrow_rounded` | play_arrow_rounded (4) |
| `AppIcons.searchOff` | `Symbols.search_off_rounded` | search_off_rounded (4) |
| `AppIcons.search` | `Symbols.search_rounded` | search_rounded (4) |
| `AppIcons.shoppingBasket` | `Symbols.shopping_basket_rounded` | shopping_basket_outlined (4) |
| `AppIcons.trendingDown` | `Symbols.trending_down_rounded` | trending_down_rounded (4) |
| `AppIcons.trendingUp` | `Symbols.trending_up_rounded` | trending_up_rounded (4) |
| `AppIcons.warning` | `Symbols.warning_amber_rounded` | warning_amber_rounded (4) |
| `AppIcons.bookmarkAdd` | `Symbols.bookmark_add_rounded` | bookmark_add_outlined (3), bookmark_add_rounded (1) |
| `AppIcons.calculate` | `Symbols.calculate_rounded` | calculate_outlined (3), calculate_rounded (1) |
| `AppIcons.alternateEmail` | `Symbols.alternate_email_rounded` | alternate_email_rounded (3) |
| (kein IconData) | **`StepsIcon()`** | directions_walk_rounded (3) |
| `AppIcons.menuBook` | `Symbols.menu_book_rounded` | menu_book_rounded (3) |
| `AppIcons.notificationsActive` | `Symbols.notifications_active_rounded` | notifications_active_outlined (3) |
| `AppIcons.notifications` | `Symbols.notifications_none_rounded` | notifications_none_rounded (3) |
| `AppIcons.photoLibrary` | `Symbols.photo_library_rounded` | photo_library_outlined (3) |
| `AppIcons.soupKitchen` | `Symbols.soup_kitchen_rounded` | soup_kitchen_outlined (3) |
| `AppIcons.syncProblem` | `Symbols.sync_problem_rounded` | sync_problem_rounded (3) |
| `AppIcons.trendingFlat` | `Symbols.trending_flat_rounded` | trending_flat_rounded (3) |
| `AppIcons.image` | `Symbols.image_rounded` | image_outlined (2), photo_outlined (1) |
| `AppIcons.accessibilityNew` | `Symbols.accessibility_new_rounded` | accessibility_new_rounded (2) |
| `AppIcons.arrowUpward` | `Symbols.arrow_upward_rounded` | arrow_upward_rounded (2) |
| `AppIcons.cloudDone` | `Symbols.cloud_done_rounded` | cloud_done_outlined (2) |
| `AppIcons.eco` | `Symbols.eco_rounded` | eco_outlined (2) |
| `AppIcons.factCheck` | `Symbols.fact_check_rounded` | fact_check_outlined (2) |
| `AppIcons.female` | `Symbols.female_rounded` | female_rounded (2) |
| `AppIcons.fitnessCenter` | `Symbols.fitness_center_rounded` | fitness_center_rounded (2) |
| `AppIcons.flashOff` | `Symbols.flash_off_rounded` | flash_off_rounded (2) |
| `AppIcons.flashOn` | `Symbols.flash_on_rounded` | flash_on_rounded (2) |
| `AppIcons.linkOff` | `Symbols.link_off_rounded` | link_off_rounded (2) |
| `AppIcons.lockReset` | `Symbols.lock_reset_rounded` | lock_reset_rounded (2) |
| `AppIcons.mail` | `Symbols.mail_rounded` | mail_outline_rounded (2) |
| `AppIcons.male` | `Symbols.male_rounded` | male_rounded (2) |
| `AppIcons.noPhotography` | `Symbols.no_photography_rounded` | no_photography_outlined (2) |
| `AppIcons.notes` | `Symbols.notes_rounded` | notes_rounded (2) |
| `AppIcons.pause` | `Symbols.pause_rounded` | pause_rounded (2) |
| `AppIcons.photoCamera` | `Symbols.photo_camera_rounded` | photo_camera_outlined (2) |
| `AppIcons.restaurantMenu` | `Symbols.restaurant_menu_rounded` | restaurant_menu_rounded (2) |
| `AppIcons.setMeal` | `Symbols.set_meal_rounded` | set_meal_outlined (2) |
| `AppIcons.shield` | `Symbols.shield_rounded` | shield_outlined (2) |
| `AppIcons.showChart` | `Symbols.show_chart_rounded` | show_chart_rounded (2) |
| `AppIcons.skipNext` | `Symbols.skip_next_rounded` | skip_next_rounded (2) |
| `AppIcons.spa` | `Symbols.spa_rounded` | spa_outlined (2) |
| `AppIcons.storefront` | `Symbols.storefront_rounded` | storefront_outlined (2) |
| `AppIcons.translate` | `Symbols.translate_rounded` | translate_rounded (2) |
| `AppIcons.visibility` | `Symbols.visibility_rounded` | visibility_outlined (1), visibility_rounded (1) |
| `AppIcons.addAPhoto` | `Symbols.add_a_photo_rounded` | add_a_photo_outlined (1) |
| `AppIcons.arrowBack` | `Symbols.arrow_back_rounded` | arrow_back_rounded (1) |
| `AppIcons.arrowDownward` | `Symbols.arrow_downward_rounded` | arrow_downward_rounded (1) |
| `AppIcons.arrowOutward` | `Symbols.arrow_outward_rounded` | arrow_outward_rounded (1) |
| `AppIcons.autorenew` | `Symbols.autorenew_rounded` | autorenew_rounded (1) |
| `AppIcons.balance` | `Symbols.balance_rounded` | balance_rounded (1) |
| `AppIcons.cake` | `Symbols.cake_rounded` | cake_outlined (1) |
| `AppIcons.cloudSync` | `Symbols.cloud_sync_rounded` | cloud_sync_outlined (1) |
| `AppIcons.cloudUpload` | `Symbols.cloud_upload_rounded` | cloud_upload_outlined (1) |
| `AppIcons.contentPaste` | `Symbols.content_paste_rounded` | content_paste_rounded (1) |
| `AppIcons.contrast` | `Symbols.contrast_rounded` | contrast_rounded (1) |
| `AppIcons.description` | `Symbols.description_rounded` | description_outlined (1) |
| `AppIcons.doneAll` | `Symbols.done_all_rounded` | done_all_rounded (1) |
| `AppIcons.donutSmall` | `Symbols.donut_small_rounded` | donut_small_rounded (1) |
| `AppIcons.editOff` | `Symbols.edit_off_rounded` | edit_off_rounded (1) |
| `AppIcons.eventAvailable` | `Symbols.event_available_rounded` | event_available_outlined (1) |
| `AppIcons.eventNote` | `Symbols.event_note_rounded` | event_note_outlined (1) |
| `AppIcons.fileDownload` | `Symbols.file_download_rounded` | file_download_outlined (1) |
| `AppIcons.folderCopy` | `Symbols.folder_copy_rounded` | folder_copy_outlined (1) |
| `AppIcons.formatListNumbered` | `Symbols.format_list_numbered_rounded` | format_list_numbered_rounded (1) |
| `AppIcons.forum` | `Symbols.forum_rounded` | forum_outlined (1) |
| `AppIcons.gridOn` | `Symbols.grid_on_rounded` | grid_on_outlined (1) |
| `AppIcons.height` | `Symbols.height_rounded` | height_rounded (1) |
| `AppIcons.hideImage` | `Symbols.hide_image_rounded` | hide_image_outlined (1) |
| `AppIcons.historyToggleOff` | `Symbols.history_toggle_off_rounded` | history_toggle_off_rounded (1) |
| `AppIcons.hourglassEmpty` | `Symbols.hourglass_empty_rounded` | hourglass_empty_rounded (1) |
| `AppIcons.hourglassTop` | `Symbols.hourglass_top_rounded` | hourglass_top_rounded (1) |
| `AppIcons.imageNotSupported` | `Symbols.image_not_supported_rounded` | image_not_supported_outlined (1) |
| `AppIcons.imageSearch` | `Symbols.image_search_rounded` | image_search_rounded (1) |
| `AppIcons.key` | `Symbols.key_rounded` | key_rounded (1) |
| `AppIcons.keyboardAlt` | `Symbols.keyboard_alt_rounded` | keyboard_alt_outlined (1) |
| `AppIcons.keyboard` | `Symbols.keyboard_rounded` | keyboard_rounded (1) |
| `AppIcons.lightbulb` | `Symbols.lightbulb_rounded` | lightbulb_outline_rounded (1) |
| `AppIcons.link` | `Symbols.link_rounded` | link_rounded (1) |
| `AppIcons.lockClock` | `Symbols.lock_clock_rounded` | lock_clock_rounded (1) |
| `AppIcons.manageAccounts` | `Symbols.manage_accounts_rounded` | manage_accounts_outlined (1) |
| `AppIcons.manageSearch` | `Symbols.manage_search_rounded` | manage_search_rounded (1) |
| `AppIcons.markEmailRead` | `Symbols.mark_email_read_rounded` | mark_email_read_rounded (1) |
| `AppIcons.markEmailUnread` | `Symbols.mark_email_unread_rounded` | mark_email_unread_outlined (1) |
| `AppIcons.noFood` | `Symbols.no_food_rounded` | no_food_outlined (1) |
| `AppIcons.northEast` | `Symbols.north_east_rounded` | north_east_rounded (1) |
| `AppIcons.pauseCircle` | `Symbols.pause_circle_rounded` | pause_circle_outline_rounded (1) |
| `AppIcons.phoneAndroid` | `Symbols.phone_android_rounded` | phone_android_rounded (1) |
| `AppIcons.playlistAddCheck` | `Symbols.playlist_add_check_rounded` | playlist_add_check_rounded (1) |
| `AppIcons.playlistRemove` | `Symbols.playlist_remove_rounded` | playlist_remove_rounded (1) |
| `AppIcons.priorityHigh` | `Symbols.priority_high_rounded` | priority_high_rounded (1) |
| `AppIcons.queryStats` | `Symbols.query_stats_rounded` | query_stats_rounded (1) |
| `AppIcons.redo` | `Symbols.redo_rounded` | redo_rounded (1) |
| `AppIcons.removeCircle` | `Symbols.remove_circle_rounded` | remove_circle_outline_rounded (1) |
| `AppIcons.replay` | `Symbols.replay_rounded` | replay_rounded (1) |
| `AppIcons.restartAlt` | `Symbols.restart_alt_rounded` | restart_alt_rounded (1) |
| `AppIcons.science` | `Symbols.science_rounded` | science_outlined (1) |
| `AppIcons.sort` | `Symbols.sort_rounded` | sort_rounded (1) |
| `AppIcons.speed` | `Symbols.speed_rounded` | speed_rounded (1) |
| `AppIcons.stop` | `Symbols.stop_rounded` | stop_rounded (1) |
| `AppIcons.straighten` | `Symbols.straighten_rounded` | straighten_rounded (1) |
| `AppIcons.swapHoriz` | `Symbols.swap_horiz_rounded` | swap_horiz_rounded (1) |
| `AppIcons.sync` | `Symbols.sync_rounded` | sync_rounded (1) |
| `AppIcons.tableRows` | `Symbols.table_rows_rounded` | table_rows_outlined (1) |
| `AppIcons.thumbDownAlt` | `Symbols.thumb_down_alt_rounded` | thumb_down_alt_outlined (1) |
| `AppIcons.timer` | `Symbols.timer_rounded` | timer_outlined (1) |
| `AppIcons.undo` | `Symbols.undo_rounded` | undo_rounded (1) |
| `AppIcons.visibilityOff` | `Symbols.visibility_off_rounded` | visibility_off_rounded (1) |
| `AppIcons.warehouse` | `Symbols.warehouse_rounded` | warehouse_rounded (1) |
| `AppIcons.workspacePremium` | `Symbols.workspace_premium_rounded` | workspace_premium_outlined (1) |

Hinweis: Bei `mic` (`mic_none`), `notifications` (`notifications_none`) und `warning` (`warning_amber`) ist der Symbols-Name die direkte Entsprechung. Mit FILL 0 sind `mic_rounded`, `notifications_rounded` und `warning_rounded` gleichwertig; Agent 2 wählt je Konzept einen Namen.
