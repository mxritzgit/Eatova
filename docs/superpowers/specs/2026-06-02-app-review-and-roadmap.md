# Eatova — Komplett-Review & Roadmap „von gut zu richtig gut"

**Datum:** 2026-06-02
**Methode:** 6 parallele Read-only-Review-Agenten (Architektur, Produkt, UX/A11y,
Tests, Security, Backend/Sync), jeder Befund gegen den echten Code verifiziert
(datei:zeile). Keine Code-Änderung in diesem Durchlauf — reine Diagnose + Plan.

## Gesamturteil

Eatova ist **handwerklich überraschend stark** für seine Größe (~28,5k Dart-Z.):
- **Backend-Security ist exzellent** — RLS lückenlos auf allen User-Tabellen, Edge
  Functions mit JWT-Auth + atomarem Quota-RPC + striktem CORS/CSP, keine echten
  Secrets in 137 Commits (nur der by-design-public Anon-Key).
- **Sync-Fassade & Service-Schicht sind sauber** (einheitliches try/catch/rethrow,
  Dependency-Injection durchgängig, Fehler seit `_reportSyncError` sichtbar).
- **Solide Produkt-Substanz**: echte 30-Tage-History, durabler Streak,
  Mifflin-St-Jeor-Onboarding, starke Food-Pipeline (Foto-KI + Barcode + OFF-Suche +
  Slots + Verlauf), AI-Coach.

Die Lücken sind **fast keine Bugs**, sondern: (1) zwei Repo-Reproduzierbarkeits-
Risiken, (2) fehlende Produkt-Tiefe, (3) Accessibility & Datenschutz (auch
App-Store-/DSGVO-relevant), (4) dünne Test-Abdeckung der Logik-/Sync-Schicht.

---

## 🔴 P0 — Korrektheit & Reproduzierbarkeit (ZUERST, klein)

**1. `profiles.weight_goal` fehlt in ALLEN Migrationen, wird aber gelesen & geschrieben.**
`profile_sync.dart:22` (load) + `:77` (save-Payload `weight_goal`). Kein Migrations-
File legt die Spalte an (`grep weight_goal supabase/` = 0). `save()` nutzt
`.upsert().select().single()` → bei unbekannter Spalte **PostgrestException**, nicht
stiller No-Op. Heißt: entweder läuft die Live-App nur, weil die Spalte **out-of-band**
ergänzt wurde (→ Repo nicht reproduzierbar, frische DB ⇒ Onboarding-Loop + Profil
synct nie), oder Profil-Save ist kaputt.
→ **Gegen Live-DB verifizieren** (war hier auto-mode-blockiert). Falls fehlt:
Migration `add column if not exists weight_goal text not null default 'maintain'` +
CHECK. Aufwand: S.

**2. Chat-Session-RPC-Grants nach Hardening-Migration vermutlich entzogen.**
`20260517170000_chat_sessions.sql` grantet `execute` an `authenticated` für
`list/create/rename/delete/ensure_default_chat_session`; `20260517220000_security_
hardening.sql:23/36` macht `revoke execute on all functions … from authenticated` +
default-privileges-revoke, **ohne** Neu-Grant. Der Client ruft genau diese RPCs als
`authenticated` (`coach_chat_service.dart:29,49,66,86,102`) → erwartbar `42501`.
Fail-closed (kein Leak), aber Chat-Liste wäre kaputt — oder die Migration wurde nicht
wie im Repo angewandt.
→ **Gegen Live-DB verifizieren** (`has_function_privilege('authenticated',
'public.list_chat_sessions()','execute')`). Fehlende Grants nachziehen. Aufwand: S.

**3. Optimistic Writes ohne Rollback + kein lokaler Offline-Store.**
Durchgängig in `shiftfit_home_page.dart` (`_removeLoggedMeal:560`, `_addResultToDaily
Total:554`, `_logWeight:364`, `_logSleep:423`, `_addCaffeine:381` …): `setState` sofort
+ `…catchError(_reportSyncError)`. Schlägt der Write fehl, divergiert lokal vs. remote
(Boot überschreibt lokal mit remote, `:174`). Zusätzlich **kein** sqflite/hive/prefs →
App-Kill innerhalb der Debounce-Fenster (DailyLog 400 ms `:115`, Stats 600 ms `:282`,
kein `flush()` in `dispose`) verliert Wasser-/Schritt-/Mood-/Streak-Taps; Offline-Boot
zeigt **Defaults** (78 kg/178 cm), die einen folgenden Save echte Daten überschreiben
lassen können.
→ Minimal: optimistischen State bei `catchError` zurückrollen + `WidgetsBindingObserver`
`flush()` in `paused/detached`. Ideal: lokaler Cache als Source-of-Truth. Aufwand: M / L.

## 🟠 P0 — Zeitkritisch

**4. GCP-Free-Trial endet 2026-08-29 → OFF-Such-Mirror stirbt.**
`search_config.dart:7-11` (Meilisearch-Cloud-Run-URL hardcodiert). Degradation ist
gebaut (`FallbackProductService` fängt Fehler+leer → live OFF), aber **jede Suche
wartet erst ~14 s Mirror-Timeout** ab (6 s connect + 8 s read) bevor OFF greift.
→ Vor dem 29.08. Kill-Switch: leere `OFF_PROXY_URL` (per `--dart-define` überschreibbar)
oder Remote-Flag → direkt OFF statt Timeout. Aufwand: S.

---

## 🚀 Produkt: die größten „gut → richtig gut"-Hebel

**#1 — Push-/Scheduled-Notifications (P0, größter Hebel).** Es gibt **kein**
Notification-Paket (kein `flutter_local_notifications`/`workmanager`). Die
`SmartRemindersCard` ist rein in-App → wirkungslos, sobald die App zu ist. Eatova
trackt bereits alles (Wasser, Streak, Mahlzeiten, Schlaf, Trainingstag) — aber ohne
Push bricht der Streak still ab und der User vergisst zu loggen. **Der einzige Hebel,
der die vorhandene Daten-Tiefe in tägliche Nutzung übersetzt** und Streak/Gamification/
Coach überhaupt wirksam macht. Aufwand: L.

**#2 — AI-Coach mit User-Kontext (P1, kleiner Aufwand, riesige Wirkung).**
`coach-chat/index.ts` injiziert NULL Userdaten — der Call ist `[system, …history,
message]`. Der „personal Coach" kennt weder Profil noch Restmakros, Gewicht, geloggte
Mahlzeiten oder Streak. Er kann nicht sagen „dir fehlen heute 38 g Protein". Profil +
Tagesbilanz in den System-Prompt geben = sofortiger Qualitätssprung. Aufwand: M.

**#3 — Echtes Workout-Logging (P0/P1).** `WeekPlannerScreen` ist ein Label-pro-Tag;
`ShiftFitPlan.from()` liefert **5 statische** Templates über 3 Dropdowns. Keine
Übungs-DB, kein Sätze/Wdh/Gewicht-Logging, keine Progression. Der „Fitness"-Teil der
„Fitness+Nutrition"-App ist faktisch ein Ratgeber, kein Tracker. Aufwand: L.

**Weitere Produkt-Lücken (priorisiert):**
- **P0** Voller Datenexport/Backup (File/Share, ganze History) — heute nur Clipboard-
  Session-Snapshot (`profile_screen.dart _ExportSheet`). Auch DSGVO Art. 20. S–M.
- **P0** Portion/Serving-Skalierung mit proportionalen Makros — heute nur kcal-Delta
  (`shiftfit_home_page.dart:573`). M.
- **P1** Kuratierbare Favoriten/Meal-Templates — „Favoriten" sind aktuell auto-letzte-5
  (`_rememberFavorite:605`); `onToggleFavorite`-Herz nie verdrahtet. S–M.
- **P1** Zwei-Wege Health-Sync — `HealthService.readSnapshot()` liest **nur** Schritte,
  read-only; kein Gewicht/Schlaf/Workout-Import, kein Write-Back. M–L.
- **P1** User-Rezepte persistent + Rezept→Einkaufsliste. M.
- **P1** Gewichts-Trend-Ziel mit Prognose („in X Wochen am Ziel"). S–M.
- **P2** Home-/Lock-Screen-Widgets; tiefere Gamification; Onboarding-Personalisierung
  (Diät/Allergien); Social/Sharing; Monetarisierung (aktuell **keine** vorhanden).

## ♿ Accessibility & Datenschutz (Quality + App-Store/DSGVO-Blocker)

- **P0** Kein `textScaler`-Clamp + **446 feste `fontSize`** → bei iOS-Großschrift bricht
  das Layout (Kalorienring-Ziffer nicht in FittedBox, Bottom-Nav fix). `shiftfit_app.dart:34`.
  Test-Harness schluckt Overflows → im Test unsichtbar. M.
- **P0** **Null `Semantics`** im ganzen `lib/` → Screenreader liest Toggles/Charts/
  Bottom-Nav-Zustand nicht (23 `CustomPaint` stumm). M.
- **P1** Touch-Targets < 44 (X-Buttons 32, (i) 28, ~15× `visualDensity.compact`). S–M.
- **P1** Kein Reduced-Motion-Respekt (82 Animationen, 0 `disableAnimations`-Check). S.
- **P1** **Keine Account-/Daten-Löschung** (DSGVO Art. 17; auch Apple 5.1.1-Blocker) —
  nur Sign-out, keine `delete_account`-RPC. M.
- **P1** **Keine Datenschutzerklärung / kein Consent** (Health-App!). M.
- ✅ **Kontrast erfüllt AA** (nachgerechnet: textPrimary 17.98:1, textMuted 5.99:1,
  lime 14.83:1) — **kein** Problem. Dark-only ist als bewusste Brand-Entscheidung ok.
- **P1** Haptik nur im Coach — Meal-Log/Habit-Toggle/Swipe-Delete/Plan-Haken stumm. S.
- **P1** Destruktive Aktionen inkonsistent: **Swipe-Delete im Verlauf feuert sofort
  ohne Undo** (`calories_overview_card.dart:959-961` — gerade neu gebaut!), Favoriten-
  Delete ohne Confirm; Chat-Delete & Meal-Komponente haben aber Confirm/Undo. → Undo
  vereinheitlichen (Theme hat `actionTextColor: lime`). S–M.

## 🧪 Tests & Zuverlässigkeit

4 Test-Dateien (~1175 Z.) / 28,5k App-Code. Struktur ist testbar (DI überall), wird
aber nicht genutzt. **Keine Coverage-Messung** in CI.
- **P0** Sync-Schicht 0 % getestet (meals/profile/daily_log/tracking/weekly_plan/
  lifetime_stats). JSONB-Roundtrip `mealResultTo/FromJson` (`meals_sync.dart:191-249`)
  ungetestet → Feld-Drift korrumpiert Food-History still.
- **P0** Foto-KI-Parser `fromEdgeFunction` (`meal_analysis_result.dart:96-173`) +
  `autoSplitItems`/Food-DB (`food_kcal_db.dart`) ungetestet → falsche kcal direkt im
  Tagesziel.
- **P0** Makro-Aufteilung (`kcal_calculator.dart:127-130`), `MacroProgress.add/subtract`,
  `adjustedToItems/Grams` ungetestet.
- **P1** Slot-Heuristik wall-clock-abhängig (`logged_meal.dart:27-36`) + Tests pinnen
  keine Zeit (`package:clock`/`withClock` fehlt) → Flakiness um Mitternacht/DST.
- **P1** Coach-Service-Fehlerpfade (429/Quota/leer) + `LifetimeStats.recordWorkoutDay`-
  Streak-Logik + `ProfileSync`-Legacy-Goal-Migration ungetestet.
- **P2** CI ohne `--coverage`/Gate; Overflow-Schlucken maskiert Layout-Bugs.

## 🗄 Backend/Sync (zusätzlich zu P0 oben)

- **P1** Multi-Device-Clobbering bei `lifetime_stats`: Client inkrementiert + upsertet
  absolute Werte (`lifetime_stats_sync.dart:40`) → zwei Geräte überschreiben sich,
  Streak springt zurück. → serverseitige atomare `increment_*`-RPC. M.
- **P1** `logged_meals`-Insert nicht idempotent (plain `insert`, Client-UUID schützt nur
  teilweise). S (im Outbox-Kontext).
- **P2** Zeitzonen gemischt (UTC-Timestamps vs. lokal-naive Tagesgrenzen) → Mahlzeit
  kann „falschem" Tag zufallen. M.
- **P2** `DailyLogSync._upsert` schluckt Fehler unsichtbar (einzige Sync-Klasse ohne
  `_reportSyncError`, weil Timer ohne Context). S.

## 🏗 Architektur (gezielt, kein Framework-Umbau nötig)

- **P1** God-Object `_ShiftFitHomePageState` (~30 State-Felder + Sync-Orchestrierung +
  Kcal/Makro-Aggregation + Router). `setState` ist überschrieben und tickt
  `_profileRefresh++` bei **jedem** setState → jeder Quick-Log rebuildet den ganzen Tab.
  → **Logik herausziehen** (Kcal/Makro/Streak/Favoriten-Dedup in pure, getestete
  Helfer), Rebuild-Granularität verbessern. **Kein** Riverpod/Bloc-Big-Bang nötig. L.
- **P1** Prop-Drilling: `TodayDashboard` bekommt ~46 Konstruktor-Felder. M.
- **P1** `_defaultProductService()` baut bei jedem Build einen neuen Service-Stack
  (`meal_analysis_screen.dart:52`). → einmal in der Komposition bauen. S.
- **P2** Slot→Farbe/Icon/Label 5–6× dupliziert (Icons bereits divergiert) → eine
  `extension MealSlotStyle on MealSlot`. S.
- **P2** `analysis_options.yaml:26-27` schaltet `unused_element/field` global ab →
  versteckt toten Code (z. B. `FavoritesCard` ~90 Z. nie gemountet; veralteter Kommentar).
- **P2** Makros als formatierte Strings im Modell → Reparsing-Schuld. M.

---

## Empfohlene Reihenfolge

**Welle A — Korrektheit & Repro (1 Sitzung, klein):** P0-1/2 gegen Live-DB verifizieren
(+ ggf. `weight_goal`-Migration & Chat-Grants), P0-3 Optimistic-Rollback + Lifecycle-
`flush()`, P0-4 OFF-Mirror-Kill-Switch (vor 29.08.), Swipe-Delete-Undo. → Schließt
stille Datenverlust-/Repro-Risiken.

**Welle B — Der „richtig gut"-Sprung:** (1) Coach-User-Kontext (klein, riesig),
(2) Notifications + Streak-Schutz (der Retention-Hebel), (3) Account-/Daten-Löschung +
Datenschutzerklärung (App-Store/DSGVO-Blocker). 

**Welle C — Tiefe & Robustheit:** echtes Workout-Logging, persistente User-Rezepte +
Einkaufsliste, Zwei-Wege-Health-Sync, Accessibility-Pass (textScaler/Semantics/Touch-
Targets/Haptik), Test-Coverage für Logik-+Sync-Schicht (+ CI-Coverage-Gate),
`lifetime_stats` serverseitige Increments.

**Welle D — Politur:** Slot-Style-Extension, God-Object-Logik herausziehen,
Datei-Splits (profile_widgets/meal_widgets/recipes), Makros numerisch im Modell.
