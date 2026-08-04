# Eatova — Umsetzungs-Brief (Deep-Dive 2026-06-04)

Master-Hand-off für die parallele Umsetzung aller verifizierten Befunde aus
`2026-06-04-deepdive-followup.md`. Partitioniert nach **Datei-Eigentum**, damit
parallele Agenten kollisionsfrei arbeiten. `shiftfit_home_page.dart` + Aggregations-
Dateien sind dem **Integrator (Welle 2)** vorbehalten.

## Globale Regeln (für jeden Agenten)
- Nur Dateien des eigenen Ownership-Sets editieren. **NIE** anfassen (außer Integrator):
  `lib/src/app/shiftfit_home_page.dart`, `lib/src/services/meal_totals.dart`,
  `lib/src/widgets/kcal/meal_analysis_sheet.dart`, `lib/src/services/daily_log_sync.dart`,
  `lib/src/services/lifetime_stats_sync.dart`. Braucht ein Fix eine dieser Dateien →
  in `followUpsForIntegrator` vermerken, nicht selbst ändern.
- In der Parallel-Phase **kein** `flutter`/`dart`-Build-Tooling ausführen (zentrale
  Verify-Phase danach). Lesen ist frei.
- Test-Pins erhalten: `test/widget_test.dart` Keys + Label-Strings sind tragend.
- Design-System gelockt: Dark/Lime, bestehende Radius-Skala, clean-minimal (Sekundär-
  Info hinter (i), kein Spam-Text). Umgebenden Code-Stil treffen.
- App-Fakten: `C:/Users/morit/Desktop/Bridgespace/claude/memory`.

## Welle 1 — Foundations (parallel, disjunkt)
- **A1 Backend/SQL+EdgeFn** — `supabase/migrations/` (nur NEUE Files), `supabase/functions/coach-chat/index.ts`, `.github/workflows/security.yml`, neu `supabase/SCHEMA_STATE_2026-06-04.md`.
  - DATA-1: neue Migration (Timestamp nach dem letzten) `increment_lifetime_stats(...)` + `record_workout_day(date)`, security-definer, `search_path=public`, atomar, RETURNING row, grant authenticated. Client-Wiring = Welle 2.
  - DATA-7: `userId` gegen UUID-Regex validieren (401 vor URL-Interpolation :421/:481).
  - DATA-5: CI-Step `supabase db push --dry-run`/`db diff` (Drift-Gate, hinter Secrets, sonst skip) + Schema-State-Doc (Followup 20260603100000 + neue RPC-Migration als „pending apply" dokumentieren). deno lint grün halten.
- **A2 UI/A11y/Privacy** — `screens/profile_screen.dart`, `widgets/shared/settings_sheet.dart`, `screens/auth_screen.dart`, `widgets/profile/profile_charts.dart`, `widgets/profile/profile_widgets.dart`, `widgets/trends/trends_widgets.dart`, `widgets/trends/combined_streak_card.dart`, `widgets/today/day_overview_card.dart`, `widgets/app_shell/shiftfit_bottom_nav.dart`, `widgets/auth/welcome_screen.dart`, neu `config/legal_links.dart` + Motion-Helper.
  - PRIV-1: `kPrivacyUrl`-Const, auth_screen umstellen, „Datenschutzerklärung"-Zeile in Profil + Settings (url_launcher).
  - A11Y-1: `Semantics(label+value)` auf Charts (Kalorienring zuerst) + Bottom-Nav-Zustand/Role.
  - A11Y-2: `motionDuration(context)` → `Duration.zero` bei `disableAnimations`; welcome_screen-Gate + Top-Animationen.
  - A11Y-3/4: 32pt-Delete-X → ≥44, `visualDensity.compact` triagieren.
- **A3 Services/Perf** — `widgets/kcal/add_meal_sheet.dart`, `services/meals_sync.dart`, `services/apple_health_service.dart`, `services/health_service.dart`, `services/fitpilot_sync.dart`, neu `services/user_recipes_sync.dart`, `models/fitness_recipe.dart`.
  - PERF-1: Versuche 6→3, Delay 1500→600ms, bei leerem Erfolg sofort return (nur bei Throw retryen), Empties cachen.
  - DATA-4: meals_sync `insert`→`upsert(onConflict:'id')`.
  - PERF-3: AppleHealthService interner `Platform.isIOS`-Guard (Selektion in home_page → followUp).
  - PROD-2 (Backend-Hälfte): `UserRecipesSync` (Muster meals_sync) + in fitpilot_sync registrieren; Boot-Load/onCreateRecipe = Welle 2.
- **A4 Tests + Pure-Extraktion** — `test/**`, `services/profile_sync.dart`, `models/logged_meal.dart`, `services/kcal_calculator.dart`, `models/macro_progress.dart`, `pubspec.yaml` (add `clock`).
  - TEST-2: `_parseGoal/_parseSex/_parseActivity` → pure Funktionen + Table-Tests.
  - TEST-1: Tests für Serializer + Makro-Split + MacroProgress.add/subtract.
  - TEST-4: `clock` einführen, logged_meal-Slot-Heuristik auf `clock.now()`, withClock-Tests (Mitternacht/DST).
  - TEST-7/3: Streak-Transitions + Coach-Fehlerpfade (über öffentliche API, kein Edit).

## Welle 2 — Home-Integration (seriell, Integrator besitzt home_page + Aggregation)
PROD-3 (Re-Portion ganzes Result + indexWhere-Fix) · DATA-2 (DailyLogSync onError-Refetch
+ lifetime_stats Snapshot-Rollback) · DATA-1-Wiring (Deltas + Row adoptieren, idempotent) ·
DATA-3 (`shared_preferences` Write-Through + `hydratedFromRealSource`-Guard) · ARCH-1/PERF-2
(_profileRefresh-Bump weg, Rebuild scopen) · ARCH-2 (Dead-Code + Lint) · PROD-4 (onToggleFavorite
verdrahten, pinned vs. recents) · PROD-2-Wiring (Boot-Load + onCreateRecipe) · offene followUps.

## Welle 3 — Retention + Rest
PROD-1 Notifications (eigener Feature-Agent, pure `NotificationContentEngine` + on-device
`zonedSchedule`, echtes-Gerät-Verifikation) · PROD-6 Diät-Onboarding + matchesDiet ·
DATA-6 kanonischer `local_day` · ARCH-3 Prop-Drilling (DailyMetrics/TodayActions) ·
A11Y/Tests-Reste · CI-Coverage-Gate.

## Groß & separat (eigene Sessions, am Ende / dokumentiert)
ARCH-4 Store-Seam (kollidiert mit Inline-Daten-Ansatz → nach Welle 2, eigener Refactor) ·
PROD-5 Workout-Logging (neues Modell+Migration+UI) · PROD-7 Zwei-Wege-Health.

## Verifikation pro Welle
`flutter pub get` → `flutter analyze` (0 Errors) → `flutter test` (grün) →
per-Fix direct-to-main, detaillierte dt. Commits. Flutter-SDK:
`C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat`.
