# Eatova — Deep-Dive-Follow-up „von gut zu richtig gut" (Stand nach Welle-A/B-Ausführung)

**Datum:** 2026-06-04
**Methode:** 6 parallele Read-only-Audit-Agenten (Produkt/Retention, Architektur,
Daten/Sync/Backend, UX/A11y/Datenschutz, Tests, Performance/Plattform). Jeder der
41 Befunde wurde von einem unabhängigen Agenten **adversarial gegen den echten Code
verifiziert** (datei:zeile). 38 bestätigt, **3 verworfen** (s. u.). Keine
Code-Änderung in diesem Durchlauf — Diagnose + priorisierter Ausführungsplan.
Aufbauend auf `2026-06-02-app-review-and-roadmap.md`, dessen Wellen größtenteils
bereits umgesetzt sind.

## Gesamturteil

Eatova ist **echt „gut"** — die 2026-06-02-Wellen haben verifizierbar gewirkt:
der AI-Coach bekommt jetzt sicheren User-Kontext (data-not-instructions,
Control-Char-Strip, 600-Zeichen-Cap), DSGVO-Account-Löschung ist end-to-end
verdrahtet, optimistische Writes für Mahlzeiten/Gewicht/Koffein/Schlaf haben
Rollback + Lifecycle-Flush, die geld-/zahlenrelevanten Pfade (Parser, Portions-Mathe,
Makro-Split, Streak, JSONB-Roundtrip) haben echte Unit-Tests, und die 60-FPS-Härtung
(RepaintBoundaries, Decode-Sizing, OFF-Mirror-Kill-Switch) hält.

Die Lücke „gut → richtig gut" konzentriert sich jetzt auf **vier Stellen**:
1. **Null Retention-Aktivierungsfläche** — es gibt nirgends ein Notification-Paket;
   jeder Retention-Asset (Streak, Reminder, Ziele), den die App bereits trackt, ist
   unsichtbar, sobald die App zu ist.
2. **Stille Daten-Integritäts-Löcher** — `lifetime_stats` clobbert über Geräte
   (absolute Upserts, keine Increment-RPC), die Tages-State-Fläche (Wasser/Schritte/
   Mood/Habits) hat **kein** Rollback und `DailyLogSync` schluckt Fehler, es gibt
   keinen durablen lokalen Cache (Offline-Cold-Boot kann echte Serverdaten mit
   78kg/178cm-Defaults überschreiben), und ein **bestätigter Makro-Bug** friert
   Protein/Carbs/Fat ein, wenn eine bereits geloggte Portion neu skaliert wird.
3. **Zwei App-Store/DSGVO-Blocker halbfertig** — Datenschutzerklärung nach dem Login
   nicht erreichbar (verifiziert: 0 Links in Profil/Settings); Reduced-Motion nur an
   1 von ~40 Stellen respektiert.
4. **Architektur-Decke** — ein 1109-LOC-God-State mit 39 Feldern, 40-Parameter-
   Prop-Drilling-Dashboard und **keiner** Store-Naht blockiert aktiv die Daten-Fixes.

Der Kern ist ehrlich und gut getestet; offen ist: die App **sticky** machen, die
Tages-State-Writes so sicher wie die Mahlzeiten-Writes, und die zwei harten
Store-Blocker schließen.

---

## Roadmap-Scorecard (gegenüber 2026-06-02)

**DONE (verifiziert):** Coach-mit-User-Kontext · DSGVO-Account-Löschung (RPC+UI+
Auth-Guard-Migration) · optimistischer Rollback + Lifecycle-Flush (Mahlzeiten/
Gewicht/Koffein/Schlaf) · P0-2 Chat-Session-Regrants · 60-FPS-Härtung · Decode-Sizing
· OFF-Mirror-Kill-Switch · Haptik über Coach hinaus · Swipe-Delete-Undo · textScaler-
1.3×-Clamp + Kalorienring-FittedBox · Money-Path-Unit-Tests · `meal_totals.dart`-
Extraktion + Tests.

**PARTIAL:** Portions-Skalierung (Analyse-Zeit skaliert P/C/F, aber Re-Scale einer
geloggten Portion friert Makros ein → jetzt **bestätigter Bug**) · persistente
User-Rezepte (Tabelle+RLS da, Client-Wiring bewusst weggelassen → Erfolgs-Toast lügt)
· Reduced-Motion (1/~40 Stellen) · In-App-Datenschutz (nur pre-Login, post-Login
unerreichbar) · Sync-Klassen-Coverage (nur freie Serializer getestet, 0 Klassen-Tests)
· P0-1 weight_goal-Migration (In-Repo-Fix da, Live-DB-Drift unverifiziert).

**OPEN:** Notifications (Hebel #1, null Infra) · echtes Workout-Logging (5 statische
Templates) · `lifetime_stats`-Increment-RPC · durabler lokaler Cache · `logged_meals`-
Idempotenz · Tages-State-Rollback · State-Mgmt-Naht · Prop-Drilling · Diät-Onboarding ·
Monetarisierung · Zwei-Wege-Health-Sync · Gamification-Tiefe · globales
`unused_element/field`-Ignore (versteckt frischen toten Code) · CI-Coverage-Gate ·
**Security-Followup-Migration NOCH NICHT auf Live-DB angewandt**.

---

## ✅ Verifiziert verworfen (Ehrlichkeit der Methode)

- **PROD-8 (Gamification/Export):** Teils falsch — es gibt **doch** ein
  `AchievementsGrid` (6 Badges, profile_widgets.dart:1551-1664) + `WeeklyChallengeCard`.
  Real bleibt nur: kein Celebration-Moment beim Unlock, `longestStreak` wird nirgends
  in der UI gelesen, kein Wochen-Recap, Export weiterhin Clipboard-only.
- **UX-1 (Favoriten-Delete ohne Undo):** Falsch — `_removeFavorite`
  (shiftfit_home_page.dart:757-772) hat bereits `_showUndoSnackBar` + `_restoreFavorite`
  + `_syncWithRollback`. Konsistent mit Swipe-Delete. Nichts zu tun.
- **TEST-5 (Zeitzonen-Asymmetrie der Loader):** Falsche Prämisse — `DateTime.parse`
  einer date-only-Zeichenkette ohne `Z` liefert in Dart **lokal**, kein fehlendes
  `.toLocal()`. (Echte, kleinere DST-Kante steckt stattdessen in DATA-6.)

---

## 🎯 Top-Hebel (verifiziert, nach Impact-pro-Aufwand gerankt)

1. **Tages-State-Writes so sicher wie Mahlzeiten-Writes machen (DATA-2) + unangewandte
   Security-Migration anwenden & repo==live beweisen (DATA-5).** [M] Welle A hat
   Wasser/Schritte/Mood/Habits/Streak vom Rollback ausgeschlossen; `DailyLogSync._upsert`
   schluckt + ist `unawaited` → ein fehlgeschlagener Write ist unsichtbar, der nächste
   Cold-Boot überschreibt lokal mit stale remote. *daily_log_sync.dart:119/148-152;
   shiftfit_home_page.dart:441-516 umgehen `_syncWithRollback` (:285);
   20260603100000_security_hardening_followup.sql:2 „NOCH NICHT angewendet".*
2. **Bestätigter Makro-Bug: Re-Scale einer geloggten Portion friert P/C/F ein (PROD-3).**
   [S] kcal-Ring aktualisiert, Protein/Carbs/Fat bleiben eingefroren. *meal_totals.dart:45-47
   `copyResultWithKcal` kopiert original.protein/carbs/fat; meal_analysis_sheet.dart:139-142
   propagiert nur kcal-Delta; behebt nebenbei `indexWhere`-Falschmahlzeit-Bug
   shiftfit_home_page.dart:713-714.*
3. **Datenschutzerklärung nach Login unerreichbar — Apple 5.1.1(i)/Play/DSGVO Art.13 (PRIV-1).**
   [S] ~15 Zeilen. *auth_screen.dart:887 einzige PRIVACY.md-Uri; 0 Treffer in
   profile_screen/settings_sheet; auth_gate.dart:79 zeigt AuthScreen nur bei user==null.*
4. **`lifetime_stats` Multi-Device-Clobber + Streak-Regression — atomare Increment-RPC (DATA-1).**
   [M] Absolute Upserts, last-writer-wins rollt die Streak der engagiertesten User zurück.
   *lifetime_stats_sync.dart:40; keine `increment_`-RPC in migrations; lifetime_stats.dart:87-115.*
5. **Notifications — Hebel #1, komplett abwesend (PROD-1/PERF-5).** [L] Jeder
   Retention-Asset ist inert sobald die App zu ist. `flutter_local_notifications` +
   `timezone`, SmartRemindersCard-Heuristiken in eine pure `NotificationContentEngine`
   extrahieren (Card + `zonedSchedule` teilen sie), Abend-Streak-at-risk-Nudge. Local-only
   → free-Apple-Team-Constraint bleibt. *pubspec.yaml Deps verifiziert; smart_reminders_card.dart:29.*
6. **Ungetestete Supabase-Row-Mapper + ProfileSync-Legacy-Goal-Migration (TEST-1/2).** [M]
   Sync-Klassengrenze 0% getestet; `_parseGoal` steuert ±550/±1100 kcal/Tag — falscher
   Branch verschiebt still jedes Tagesziel. Pure Funktionen extrahieren + Table-Tests
   (Muster: meal_totals.dart). *meals_sync.dart:46-69 vs Load :22-44; profile_sync.dart:109-127.*
7. **Produktsuche hängt 30s+ bei „nicht gefunden" — leere Treffer nicht retryen (PERF-1).** [S]
   Single schlimmster wahrgenommener Smoothness-Defekt, ~5 Zeilen. *add_meal_sheet.dart:115
   max 6 Versuche, :113-114 1500ms Delay, :263 Early-Return nur bei non-empty.*
8. **Dünne Store-Naht einziehen (ARCH-4) — die Voraussetzung, die die Daten-Roadmap entsperrt.** [L]
   Jeder Daten-Fix muss durch einen 1109-LOC-God-State mit 39 Feldern + 12 handgeschriebenen
   Rollback-Snippets. `DailyStore`/`ProfileStore` (ChangeNotifier, kein Framework) mit
   eingebautem Rollback; killt nebenbei den `_profileRefresh`-Bleed + Full-Tab-Rebuild
   (ARCH-1/PERF-2). *kein provider/riverpod/bloc/get_it; 39 Felder shiftfit_home_page.dart:77-117.*

---

## 📋 Detail-Befunde nach Dimension (verifiziert, datei:zeile)

### Produkt & Retention
- **PROD-1** [P0/L] Notifications fehlen komplett. *pubspec; smart_reminders_card.dart:29.*
- **PROD-2** [P1/M] User-Rezepte nie persistiert; Erfolgs-Toast lügt (Tabelle+RLS da,
  Client-Wiring weggelassen). *recipes_screen.dart:85-98; shiftfit_home_page.dart:1036-1057;
  20260530091000_user_recipes.sql:8-10.*
- **PROD-3** [P1/S] Makro-Re-Scale-Bug (s. Top-Hebel #2).
- **PROD-4** [P1/M] Kuratierbare Favoriten nicht geliefert; `onToggleFavorite`-Herz unverdrahtet,
  bleibt auto-letzte-5. *shiftfit_home_page.dart:748-751; meal_widgets.dart:322/357.*
- **PROD-5** [P1/L] Workout-Seite = statischer Ratgeber, kein Sätze/Wdh/Gewicht/Progression.
  *shift_fit_plan.dart:33-141; week_planner_screen.dart:132-144.*
- **PROD-6** [P2/M] Keine Diät-Personalisierung; Rezept-Matching empfiehlt Diät-/Allergie-
  verletzende Mahlzeiten. *onboarding_screen.dart:36; recipes_screen.dart:65-72; fitness_recipe.dart:49-85.*
- **PROD-7** [P2/L] Health nur Schritte + read-only; kein Gewicht/Schlaf-Import, kein Write-Back.
  *health_service.dart:3-8; apple_health_service.dart:12-13.*

### Daten / Sync / Backend
- **DATA-1** [P1/M] Multi-Device-Clobber (s. Top-Hebel #4).
- **DATA-2** [P1/M] Tages-State ohne Rollback + DailyLogSync schluckt (s. Top-Hebel #1).
- **DATA-3** [P1/L] Kein durabler lokaler Cache; Offline-Cold-Boot-Defaults (78/178) können
  Server überschreiben; `_profileLoaded` nie als Save-Guard genutzt. *shiftfit_home_page.dart:174-250;
  profile_sync.dart:36-39; keine sqflite/hive/shared_preferences.*
- **DATA-4** [P1/S] `logged_meals`-Insert nicht idempotent; Delete→Undo-Race feuert 409 →
  Rollback droppt lokal. *meals_sync.dart:48 (plain insert vs upsertFavorite :138-149);
  shiftfit_home_page.dart:685-705/696.*
- **DATA-5** [P1/S] Repo↔Live-DB-Drift unverifiziert; Security-Followup unangewandt; ungeguardeter
  `delete_account` noch live. *20260602120000:6-7; 20260603100000:2; 20260602120200_delete_account_rpc.sql:10-19.*
- **DATA-6** [P2/M] Gemischte UTC/lokale Tagesgrenzen (Mahlzeiten: isSameDay(.toLocal); Koffein:
  UTC-Fenster aus naivem lokalen Mitternacht) → DST/Reise-Kante. *meals_sync.dart:51; tracking_sync.dart:58-66.*
- **DATA-7** [P2/S] coach-chat interpoliert JWT-`userId` ohne UUID-Re-Validierung in PostgREST-URLs
  (session_id wird validiert, userId nicht) → Defense-in-Depth-Lücke. *coach-chat/index.ts:567/421/481 vs :36-37/648.*

### Architektur & Code-Health
- **ARCH-1** [P1/M] `setState`-Override bumpt `_profileRefresh` bei JEDEM setState; einziger Consumer
  ist die gepushte ProfileScreen-Route → verschwendeter Notify + kein Rebuild-Scoping → Wasser-Tap
  rebuildet den ganzen Today-Tab. *shiftfit_home_page.dart:140-143/848.* (Korrektur: Notify-Pfad NICHT
  ersatzlos entfernen — hält die offene ProfileScreen mid-route lebendig; stattdessen Rebuild scopen.)
- **ARCH-2** [P2/S] `unused_element/field` global ignoriert versteckt frischen toten Code (`_addSteps`,
  `_resetWater`). *analysis_options.yaml:26-27.*
- **ARCH-3** [P1/M] TodayDashboard 40 Konstruktor-Felder. *today_dashboard.dart:72-113.*
- **ARCH-4** [L] Keine Store-Naht (s. Top-Hebel #8).
- **ARCH-5/6** [S–M] MealSlotStyle-Extension teilweise (divergenter Switch calories_overview_card.dart:717);
  `_defaultProductService()` baut bei jedem Build neuen Service-Stack. *meal_analysis_screen.dart:38/55-59.*

### UX / A11y / Datenschutz
- **PRIV-1** [P0/S] Datenschutz post-Login unerreichbar (s. Top-Hebel #3).
- **PRIV-2** [P1/S] PRIVACY.md hat keine stabile gehostete URL (per `--dart-define`).
- **A11Y-1** [P1/M] Praktisch null `Semantics`; ~21 `CustomPaint`-Charts + Bottom-Nav-Zustand für
  Screenreader stumm.
- **A11Y-2** [P1/S] Reduced-Motion nur an 1/~40 Stellen (z. B. welcome_screen 900ms-Gate ignoriert es).
- **A11Y-3/4** [S–M] Touch-Targets < 44 (Delete-X 32pt), diverse `visualDensity.compact`.

### Tests & Zuverlässigkeit
- **TEST-1/2** [P1/M] Sync-Row-Mapper + ProfileSync-Parse 0% getestet (s. Top-Hebel #6).
- **TEST-3** [P1] Coach-Service-Fehlerpfade (429/Quota/leer) ungetestet.
- **TEST-4** [P1] Slot-Heuristik wall-clock-abhängig, Tests pinnen Zeit nicht (`package:clock`).
- **TEST-6** [P2] CI ohne `--coverage`/Gate; Test-Harness schluckt Overflows (maskiert Layout-Bugs).
- **TEST-7** [P1] `lifetime_stats`-Streak-Transitions (gestern/heute/Lücke) ungetestet.

### Performance & Plattform
- **PERF-1** [S] Produktsuche-Hang bei leeren Treffern (s. Top-Hebel #7).
- **PERF-2** [M] Full-Tab-Rebuild bei jedem Quick-Log (gekoppelt an ARCH-1).
- **PERF-3** [S] `AppleHealthService` ohne `Platform.isIOS`-Gate (NoopHealthService existiert).
- **PERF-5** = PROD-1 (Notifications).
- **PERF-6** = ARCH-6 (Service-Stack pro Build).

---

## 🚀 Empfohlene Ausführung — Wellen, je mit passendem Workflow

### Welle 0 — Quick-Win-Hotfix-Sweep (Store-Blocker + Daten-Integrität)
**Ziel:** Die zwei harten Store-Blocker + den bestätigten Daten-Bug in einem kurzen,
high-confidence-Durchlauf VOR jeder größeren Feature-Arbeit. Billigste, höchste Hebel.
- PRIV-1: geteilte `kPrivacyUrl`-Const + „Datenschutzerklärung"-Zeile in About + Profil
- PROD-3: kcal-Delta-Re-Portion-Pfad durch ganzen skalierten `MealAnalysisResult` ersetzen
  (behebt eingefrorene Makros + `indexWhere`-Falschmahlzeit-Bug)
- PERF-1: leere Suchtreffer nicht retryen, Versuche 6→3 / Delay 1500→600ms, Empties cachen
- ARCH-2: `_addSteps`/`_resetWater`/`LifetimeStats.addSteps` löschen, Ignore→warning
- PERF-3: Ein-Zeilen-`Platform.isIOS`-Gate auf AppleHealthService
- PROD-2-Stopgap: User-Rezept-Erfolgs-Toast ehrlich machen, bis Persistenz kommt
> **Workflow:** Plan-first → **ein** sorgfältiger Agent + adversarial verify. Ein-Seiten-
> Brief mit jeder Fix-Stelle (datei:zeile), sequenziell in einer Sitzung (alle in 1-3
> Dateien lokalisiert), jeder Fix mit gezieltem Widget/Unit-Test (der Makro-Re-Scale-Test
> ist tragend), `flutter analyze` + `flutter test` nach jedem, per-Fix direct-to-main mit
> detaillierten dt. Commits. **Kein Fan-out** — überlappende Dateien (shiftfit_home_page.dart).

### Welle A — Daten-Sicherheit härten
**Ziel:** Tages-State so sicher wie Mahlzeiten + Multi-Device/Offline-Verlust stoppen.
- DATA-2: DailyLogSync `onError` → `loadForDate(today)`-Refetch bei Fehler (Server-Truth) +
  `_saveLifetimeStats`-Snapshot-Rollback
- DATA-1: atomare `increment_lifetime_stats` + `record_workout_day` security-definer-RPCs;
  Client sendet Deltas, adoptiert Row, idempotente Event-ID
- DATA-4: `insertLoggedMeal` → `upsert(onConflict:'id')` (Ein-Zeilen-Idempotenz)
- DATA-5: Security-Followup auf Live-DB anwenden, `db diff`-Artefakt committen, CI-`db push
  --dry-run`-Gate
- DATA-3: `shared_preferences`-Write-Through-Cache + `hydratedFromRealSource`-Guard
> **Workflow:** **TDD-first + adversarial verify gegen den echten Supabase-Pfad** (gehashte
> Config zur Laufzeit loggen, nie privates Harness). Failing-Tests ZUERST: Two-Device-Interleave
> für Increment-RPC, Stub-Throw-daily_logs (Snackbar + Revert), Duplicate-Insert (eine Row),
> Boot-mit-werfendem-ProfileSync (Save NICHT mit 78/178). RPC-Arbeit (DATA-1/5) ist ein
> SQL-Migration-Slice → **parallele Worktree** getrennt von Client-Slices (DATA-2/3/4),
> Reconverge beim Integrationstest.

### Welle B — Architektur-Naht (entsperrt alles Downstream)
**Ziel:** Store-Naht einziehen + Prop-Drilling/God-Object-Schuld abbauen, ohne Big-Bang.
- ARCH-4: `DailyStore` + `ProfileStore` (ChangeNotifier) mit eingebautem Rollback
- ARCH-1/PERF-2: `_profileRefresh`-Bump droppen (Notify scoped auf gemountete ProfileScreen);
  Hot-Metric-Cards in `ValueListenableBuilder`
- ARCH-3: TodayDashboards 40 Params in `DailyMetrics` + `TodayActions` Value-Objects
- ARCH-6/PERF-6: Product-Service in den Composition-Root (main.dart) heben
- TEST-1..4/7: pure Mapper/Parse-Funktionen extrahieren + Sync-/ProfileSync-/Coach-/Clock-Tests
> **Workflow:** Plan-first (writing-plans) → **subagent-driven-development** mit dem Analyzer
> als Sicherheitsnetz. Store-by-store (meals/daily zuerst, Mathe schon isoliert). Rebuild-Scoping
> mit DevTools „Track widget rebuilds" verifizieren (Evidence-before-Assertion). Test-Extraktion
> ist unabhängig → ideales **paralleles Worktree-Fan-out** (ein Agent pro Pure-Function-Suite).

### Welle C — Retention-Aktivierung (Notifications) + A11y/Privacy-Reste
**Ziel:** Tracked Data zur Tagesgewohnheit machen + halbfertige A11y/Privacy abschließen.
- PROD-1/PERF-5: `flutter_local_notifications` + `timezone`; SmartRemindersCard-Heuristiken
  in pure `NotificationContentEngine`; Abend-Streak-at-risk-Nudge; Onboarding-Permission + Settings
- A11Y-1: `Semantics(label+value)` auf Charts + Bottom-Nav (Start: Kalorienring + Nav)
- A11Y-2: geteilter `motionDuration`-Helper, welcome_screen-Gate unter reduce-motion killen
- A11Y-3/4: Bottom-Nav `maxLines`/FittedBox; 32pt-Delete-X auf 44pt
- PRIV-2: PRIVACY.md unter stabiler URL via `--dart-define`
- TEST-6: CI `flutter test --coverage` + lcov-Floor-Gate; Overflow-Exceptions de-swallowen
> **Workflow:** Notifications = plan-first → **ein** fokussierter Feature-Agent, TDD auf der
> puren Engine, dann **Scheduled-Fire auf echtem Gerät mit geschlossener App** verifizieren
> (nur ein echtes Gerät beweist Off-App-Verhalten). A11y/Privacy = unabhängige lokale Edits →
> **paralleles Fan-out** (ein Agent pro Datei-Cluster), jeweils mit CI-grep/Widget-Guard.

### Welle D — Produkt-Tiefe (optional, wenn Retention bewiesen)
**Ziel:** Tiefe dort, wo der Sog am größten ist — NACH dem Notifications-Loop-Beweis.
- PROD-4: `onToggleFavorite` verdrahten, gepinnte Favoriten von Auto-Recents trennen
- PROD-2: `UserRecipesSync` + FitPilotSync-Registrierung + Boot-Load + `onCreateRecipe`
- PROD-6: Diät/Allergie-Onboarding-Step + `matchesDiet`-Vorfilter
- PROD-5: minimales Übung/Satz/Wdh/Gewicht-Modell + last-time/PR pro Übung
- PROD-7: Zwei-Wege-Health-Sync (Write-Back von Gewicht/Workouts zuerst)
- ARCH-5: mechanische Datei-Splits via Barrel-Exports
> **Workflow:** brainstorming → writing-plans → TDD pro Feature-Slice; meist unabhängige
> additive Vertikalen → **Worktree-isoliertes paralleles Feature-Work** (ein Feature pro
> Worktree). Schwere Items (PROD-5/PROD-7) hinter ein Retention-Signal aus Welle C gaten.
> flutter-ui-ux-Skill + Windows-Headless-Screenshot-Verifikation für neue UI.

---

## Workflow-Gesamtempfehlung

**Strikter plan-first, wellen-sequenzierter Loop** — passend zu den dokumentierten
Präferenzen (Architektur-Plan vor Code, direct-to-main mit detaillierten dt. Commits,
gegen echten Pfad/Logs verifizieren, nie privates Harness/halluzinierte Tool-Outputs).

1. **PLAN-FIRST pro Welle** — Ein-Seiten-Brief mit jedem Item + adversarial-verifizierter
   datei:zeile + dem Test, der es beweist. Der Brief ist zugleich das Hand-off-Artefakt,
   falls Codex parallel läuft (Plan-Chat allein reicht nicht).
2. **NACH ABHÄNGIGKEIT sequenzieren, nicht nach Reiz:** Welle 0 (S-Effort, schließt 2
   Store-Rejections + Daten-Bug in Stunden) → Welle A (Daten-Sicherheit) → Welle B
   (Store-Naht, die den Rest strukturell entsperrt) → Welle C (Retention + A11y) → Welle D.
3. **Pattern an die Wellen-Form anpassen**, nicht ein Pattern für alles: TDD-first
   Single-Agent für lokalisierte Bug-/Safety-Fixes + Notification-Engine; Worktree-
   isoliertes Fan-out nur wo Dateien disjunkt sind (TEST-*-Suites, A11y-Edits, Welle-D-
   Vertikalen); Pipeline plan→implement→adversarial-verify für die Architektur-Refactors
   mit dem Analyzer als compile-checked Netz + DevTools-Rebuild-Tracking für Perf-Claims.
4. **An jedem Gate gegen Realität verifizieren:** `flutter analyze` + `flutter test` nach
   jeder Änderung, Security-Followup gegen Live-DB + `db diff`-Artefakt + CI-Dry-Run-Gate
   (DATA-5), Off-App-Notifications auf echtem Gerät mit geschlossener App beweisen.

**Rationale:** Der Code ist im Kern schon ehrlich und gut getestet — der Failure-Mode hier
ist nicht Fähigkeit, sondern **Sequenzierung**. Die L-Effort-Notification/Workout-Features
vor den S-Effort-Store-Blockern und der M-Effort-Store-Naht zu bauen, ließe Rejections live
und zwänge jeden Daten-Fix ein zweites Mal durch den God-State. Quick-Wins zuerst, dann die
Naht, dann Tiefe — jede Welle durch eine Real-Path-Verifikation gegated — ist der Workflow
mit der geringsten verschwendeten Bewegung.
