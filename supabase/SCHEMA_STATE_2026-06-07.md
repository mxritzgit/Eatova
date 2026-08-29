# Migration-Drift — was der CI-Job meint und was zu tun ist

> Diese Seite hat der Fehlertext des Jobs `supabase-migration-drift` im Blick
> (`.github/workflows/security.yml`); er verweist namentlich hierher. Sie
> beschreibt **den Abgleich**, nicht das Schema.
>
> **Der Schema-Bestand steht in [`SCHEMA_STATE.md`](SCHEMA_STATE.md)** —
> Tabellen, RLS, Policies, Rechte und Funktionen als Endzustand aller
> Migrationen, **erzeugt** aus `supabase/migrations/` und von
> `test/migrations/schema_state_doc_test.dart` gegen den Replay geprüft.

## Warum diese Seite nicht mehr das Schema führt

Bis zum 2026-08-29 stand hier eine von Hand gepflegte Tabelle des
„verifizierten Live-Zustands". Sie war zuletzt **sechzehn Migrationen alt**:
`workout_sets`, `weekly_plans` und `caffeine_entries` standen darin als live,
obwohl `20260803120000_drop_removed_feature_tables.sql` sie gedroppt hat, und
`record_workout_day(date)` als aufrufbar, obwohl `20260804120000` sie entfernt
hat (Befund P7-04). Niemand konnte das sehen: kein Test las die Datei.

Ein Dokument, das wieder veralten kann, veraltet auch. Der Bestand wird
deshalb erzeugt, nicht gepflegt — neu erzeugen mit:

```
SCHEMA_STATE_SCHREIBEN=1 flutter test test/migrations/schema_state_doc_test.dart
```

Fehlt der Schritt nach einer neuen Migration, wird genau ein Test rot und nennt
diesen Befehl.

## Was der Drift-Job prüft

Job **`supabase-migration-drift`** in `.github/workflows/security.yml`:

- Läuft nur mit den Repo-Secrets `SUPABASE_ACCESS_TOKEN` **und**
  `SUPABASE_PROJECT_REF` — und bewusst **nicht** bei `pull_request`: der PAT ist
  kontoweit und der Endpunkt führt beliebiges SQL auf der Produktivdatenbank
  aus, während die Workflow-Datei bei `pull_request` aus dem PR-Head stammt.
  Der Abgleich läuft beim Push auf `main` (also direkt nach dem Merge) und
  wöchentlich per `schedule`.
- Er fragt die Live-Historie über die **Management-API** ab
  (`POST /v1/projects/{ref}/database/query` auf
  `supabase_migrations.schema_migrations`, mit Browser-User-Agent wegen
  Cloudflare 1010) und vergleicht sie gegen die Dateinamen in
  `supabase/migrations/`.
- **Fehlt eine Repo-Migration in der Historie, failt der Job.** Das heißt: die
  Live-DB kennt eine Änderung nicht, die im Repo steht.

Bewusst **kein** `supabase db push --dry-run`: das bräuchte ein zusätzliches
`SUPABASE_DB_PASSWORD`-Secret und einen DB-Login; der Management-API-Weg kommt
mit dem ohnehin nötigen PAT aus.

## Wenn der Job failt

Der Fehlertext nennt die nicht registrierten Dateinamen. Beide Schritte
gehören zusammen:

1. **Anwenden** — den Inhalt der genannten Migration(en) in Dateinamen-
   Reihenfolge ausführen, entweder mit `supabase db push` oder über die
   Management-API (`POST /v1/projects/{ref}/database/query`). Alle Migrationen
   dieses Repos sind idempotent geschrieben (`if not exists`,
   `drop … if exists`, `pg_constraint`-Proben), ein zweiter Lauf ist also
   folgenlos.
2. **Historie nachziehen** — den Versionsstempel in
   `supabase_migrations.schema_migrations` eintragen, sonst failt der Job
   weiter, obwohl die Änderung live ist.

Vor jeder Diagnose gilt der Grundsatz aus der Verifikation vom 2026-06-07:
**Live-Zustand immer gegen den echten Pfad prüfen** (Katalog-Query über die
Management-API), nie gegen Annahmen.

## Offener Punkt (unverändert seit 2026-06-07)

**Repo-Secret `SUPABASE_ACCESS_TOKEN` setzen, um den Gate-Job scharf zu
schalten.** Der Trade-off bleibt bewusst offen: der `sbp_`-PAT ist
**kontoweit** (DDL auf jedem Projekt des Accounts) und lässt sich von Supabase
nicht projekt-scoped ausstellen. In einem öffentlichen Repo ist das ein realer
Blast-Radius, sollte er je aus den Actions-Secrets exfiltriert werden (nur über
Push/Workflow-Änderung auf `main` möglich — Fork-PRs bekommen das Secret
nicht). Die Härtung dazu ist ein Repo-Schritt, kein Code-Schritt: Environment
`supabase-drift` mit Branch-Policy `main` anlegen, beide Secrets dorthin
verschieben, Token rotieren, dann `environment:` im Job
`supabase-migration-drift-live` einkommentieren.

Ohne das Secret bleibt der Job ein sauberer Skip; die Drift-Prüfung läuft dann
manuell/lokal über die Management-API — so wie am 2026-06-07, als
`supabase_migrations.schema_migrations` lückenlos alle damaligen 19
Repo-Versionen von `20260516150000` bis `20260604160000` enthielt.
