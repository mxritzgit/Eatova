# Eatova — Umsetzungs-Status (Deep-Dive 2026-06-04, Abschluss)

Ausführung des Deep-Dive (`2026-06-04-deepdive-followup.md`) nach dem Wellen-Plan
(`2026-06-04-implementation-plan.md`). Parallele Subagenten pro Welle auf disjunkten
Dateien, `home_page`-Integration jeweils seriell, jede Welle gegen `flutter analyze`
(0 Errors) + `flutter test` verifiziert und direct-to-main committet & gepusht.

**Test-Wachstum:** 33 → **283 Tests grün**, `flutter analyze` 0 Issues über alle Wellen.

## Umgesetzt (verifiziert, auf `main`)

**Daten-Integrität & Sync**
- DATA-1 atomare `increment_lifetime_stats` + `record_workout_day` RPCs (Multi-Device-Clobber/Streak-Regression behoben), Client sendet Deltas + adoptiert Server-Row
- DATA-2 Tages-State (Wasser/Schritte/Mood/Habits) mit `onError`-Refetch (Server-Truth) + Stats-Rollback — so sicher wie die Mahlzeiten-Writes
- DATA-3 `shared_preferences` Write-Through-Cache + `hydratedFromRealSource`-Guard → Offline-Cold-Boot überschreibt nie die echte Profilzeile mit 78/178
- DATA-4 idempotenter `logged_meals`-Upsert (retry-/Undo-sicher)
- DATA-5 Repo↔Live-DB-Drift behoben + CI-Drift-Gate; **alle Migrationen live verifiziert** (siehe `SCHEMA_STATE_2026-06-04.md`)
- DATA-6 kanonischer `local_day`-Key (Mahlzeit & Koffein DST-stabil derselbe Tag)
- DATA-7 coach-chat `userId`-UUID-Validierung vor PostgREST-Interpolation

**Produkt & Retention**
- PROD-1 **Notifications** — on-device (`flutter_local_notifications`+`timezone`), pure `NotificationContentEngine`, verdrahtet (Boot-/Change-Scheduling, Onboarding-Opt-in, Settings-Toggle)
- PROD-2 User-Rezepte persistent (`UserRecipesSync` + Boot-Load + Create/Delete)
- PROD-3 Re-Portion skaliert P/C/F (nicht nur kcal) + `indexWhere`-Falschmahlzeit-Fix
- PROD-4 kuratierbare Favoriten (`pinned` vs. Recents)
- PROD-5 **echtes Workout-Logging** (Exercise-Library + WorkoutSet + Migration + `WorkoutLogSync` + pure Progression/PR/Volumen + Set-Logger-UI im Week-Planner)
- PROD-6 Diät-Personalisierung (Onboarding-Step + `matchesDiet`-Filter)
- PROD-7 Zwei-Wege-Health (Gewicht/Workout Write-Back nach HealthKit, hinter Connect-Flow)

**A11y / Datenschutz / UX**
- PRIV-1 Datenschutzerklärung nach Login erreichbar (Store-Blocker) · PRIV-2 stabile URL
- A11Y-1 `Semantics` auf Charts + Bottom-Nav · A11Y-2 Reduced-Motion-Helper · A11Y-3/4 Touch-Targets ≥44

**Perf / Architektur / Tests**
- PERF-1 Produktsuche-Hang (Leertreffer) behoben · PERF-3 iOS-Health-Guard
- ARCH-1 `_profileRefresh`-Notify nur noch bei gemounteter ProfileScreen-Route (kein Notify pro Quick-Log)
- ARCH-2 toter Code entfernt + Lint auf `warning` · ARCH-3 TodayDashboard 40 Params → `DailyMetrics`+`TodayActions` · ARCH-5 `profile_widgets`/`meal_widgets` via part/part-of gesplittet
- ARCH-6 Product-Service in Komposition · MealSlotStyle-Extension
- TEST-1/2/3/4/7 Sync-Mapper/Parse/Streak/Coach/Clock-Tests · TEST-6 CI-Coverage-Gate

## Bewusst zurückgestellt (mit Begründung)

- **ARCH-4 — Store-Seam (`DailyStore`/`ProfileStore`).** Die Synthese sequenzierte den
  Store-Seam als eigenes Refactor NACH den inline gelösten Daten-Fixes. Da diese Fixes
  jetzt grün+live sind, würde ein Store-Seam sie nur erneut umbauen (Churn + Regressions-
  risiko ohne neuen Funktionsgewinn). Sinnvoll als dedizierter, eigener Schritt.
- **PERF-2 — per-Card-Rebuild-Scoping (ValueNotifier je Hot-Card).** Der `_profileRefresh`-
  Teil (ARCH-1) ist erledigt; die feingranulare Rebuild-Isolation pro Karte braucht ~10
  Read-Sites umgestellt + Staleness-Audit und gehört natürlich zum Store-Seam (ARCH-4).
  Zurückgestellt, statt eine Regression in die 283 grünen Tests zu riskieren.

Beide hängen zusammen und sind der saubere Inhalt einer späteren „Welle B — Store-Seam".

## Verifikations-Hinweise / Lessons

- `testWidgets` läuft im FakeAsync-Zone: ein **echter `SupabaseClient` darf dort NICHT
  `dispose()`'t werden** (Realtime/Auth-Close läuft nie durch → Teardown-Hang bis Timeout).
  Lösung: kein dispose-Teardown (Auto-Refresh via `autoRefreshToken:false` aus → kein
  pendender Timer). Siehe `test/clobber_guard_test.dart`.
- Live-DB-Migrationen: per Management-API (`/database/query`, PAT + Browser-UA wegen
  Cloudflare) idempotent anwenden + `schema_migrations` backfillen; generisches Skript
  `migrate_live.py` im Bridgespace-Root. Prod-Mutationen sind classifier-gated → vom User
  per `!`-Lauf ausführen.
</content>
