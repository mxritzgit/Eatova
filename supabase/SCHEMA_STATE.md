# Supabase Schema-State (erzeugt)

<!-- ERZEUGT aus supabase/migrations/ von
     test/migrations/schema_state_doc.dart.
     NICHT von Hand bearbeiten — schema_state_doc_test.dart
     vergleicht diese Datei gegen den Replay und wird rot. -->

Dies ist der **Endzustand aller Migrationen**, nicht der Inhalt
einer einzelnen: `lifetime_stats` verliert seine Schreib-Policies
in `20260811120000` wieder, `profiles` tauscht in `20260819100000`
das Tabellenrecht gegen Spalten-Grants. Nur das Ende der Kette
sagt, was die Datenbank wirklich durchsetzt.

**Neu erzeugen** (nach jeder neuen Migration):

```
SCHEMA_STATE_SCHREIBEN=1 \
  flutter test test/migrations/schema_state_doc_test.dart
```

**Was hier NICHT steht:** Spalten, Typen, Constraints, Indizes und
Trigger. Der Replay modelliert Tabellen, RLS, Policies, Rechte und
Funktionen — also die Zugriffsflaeche. Fuer Spalten und Constraints
ist die Migration selbst die Quelle; sie steht in jeder Zeile
unten dabei. Zwei Grenzen liegen deshalb ausserhalb dieser Tabellen:
die Zeilen*groessen* (`*_safe_ranges_check`, `20260517220000` und
`20260819140000`) und die Zeilen*zahl* je Nutzer
(`enforce_user_row_cap`-Trigger, `20260829120000`).

**Live-Abgleich:** ob die Live-DB diese Historie wirklich
angewendet hat, prueft der Job `supabase-migration-drift` in
`.github/workflows/security.yml`; die Bedienung steht in
`supabase/SCHEMA_STATE_2026-06-07.md`.

## Migrationen (36)

1. `20260516150000_create_profiles.sql`
2. `20260516160000_app_data_schema.sql`
3. `20260516180000_grants.sql`
4. `20260517100000_coach_chat.sql`
5. `20260517170000_chat_sessions.sql`
6. `20260517220000_security_hardening.sql`
7. `20260518000100_fix_edge_rate_limit_pgcrypto_search_path.sql`
8. `20260523000000_onboarding_fields.sql`
9. `20260530090000_streak_and_weekly_plan.sql`
10. `20260530091000_user_recipes.sql`
11. `20260602120000_profiles_weight_goal.sql`
12. `20260602120100_regrant_chat_session_rpcs.sql`
13. `20260602120200_delete_account_rpc.sql`
14. `20260603100000_security_hardening_followup.sql`
15. `20260604120000_lifetime_increment_rpcs.sql`
16. `20260604130000_favorite_meals_pinned.sql`
17. `20260604140000_profiles_diet_preference.sql`
18. `20260604150000_local_day_keys.sql`
19. `20260604160000_workout_logging.sql`
20. `20260609120000_chat_rpc_least_privilege.sql`
21. `20260802120000_least_privilege_trigger_functions.sql`
22. `20260803120000_drop_removed_feature_tables.sql`
23. `20260804120000_tracking_streak.sql`
24. `20260807090000_profiles_age_minimum_16.sql`
25. `20260808210000_chat_quota_honesty.sql`
26. `20260809120000_pin_function_execute_defaults.sql`
27. `20260811120000_lifetime_stats_integrity.sql`
28. `20260811130000_chat_message_size_limit.sql`
29. `20260813090000_chat_message_recipe.sql`
30. `20260814120000_audit_rls_guard.sql`
31. `20260815120000_delete_account_reauth.sql`
32. `20260818120000_profiles_email_sync.sql`
33. `20260819100000_profiles_column_grants.sql`
34. `20260819140000_user_recipes_limits.sql`
35. `20260828100000_profiles_manual_energy.sql`
36. `20260829120000_row_caps_and_hardening.sql`

## Tabellen in `public` (11)

| Tabelle | RLS | `authenticated` | `service_role` | Policies | angelegt in |
|---|---|---|---|---|---|
| `chat_messages` | an | `select` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 1 | `20260517100000_coach_chat.sql` |
| `chat_quota_usage` | an | `select` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 1 | `20260517100000_coach_chat.sql` |
| `chat_sessions` | an | `delete`, `insert`, `select`, `update` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 4 | `20260517170000_chat_sessions.sql` |
| `edge_rate_limits` | an | — | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 0 | `20260517220000_security_hardening.sql` |
| `favorite_meals` | an | `delete`, `insert`, `select`, `update` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 4 | `20260516160000_app_data_schema.sql` |
| `lifetime_stats` | an | `select` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 1 | `20260516160000_app_data_schema.sql` |
| `lifetime_stats_requests` | an | — | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 0 | `20260814120000_audit_rls_guard.sql` |
| `logged_meals` | an | `delete`, `insert`, `select`, `update` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 4 | `20260516160000_app_data_schema.sql` |
| `profiles` | an | `select` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 3 | `20260516150000_create_profiles.sql` |
| `user_recipes` | an | `delete`, `insert`, `select`, `update` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 4 | `20260530091000_user_recipes.sql` |
| `weight_log` | an | `delete`, `insert`, `select`, `update` | `delete`, `insert`, `references`, `select`, `trigger`, `truncate`, `update` | 4 | `20260516160000_app_data_schema.sql` |

Weitere Rollen (`anon`, `public`) halten auf keiner Tabelle ein
Recht — sonst stuende sie hier und der RLS-Waechter waere rot.

## Spalten-Grants

Ein Spalten-Grant ersetzt das Tabellenrecht: `authenticated`
schreibt nur die aufgezaehlten Spalten, alles andere scheitert
mit 42501.

| Tabelle | Rolle | Recht | Spalten | Namen |
|---|---|---|---|---|
| `profiles` | `authenticated` | `insert` | 18 | `activity_level`, `age_years`, `carbs_goal_g`, `daily_kcal_goal`, `daily_sleep_goal_minutes`, `daily_steps_goal`, `daily_water_goal_ml`, `diet_preference`, `fat_goal_g`, `height_cm`, `id`, `manual_energy`, `onboarding_completed`, `protein_goal_g`, `sex`, `target_weight_kg`, `weight_goal`, `weight_kg` |
| `profiles` | `authenticated` | `update` | 18 | `activity_level`, `age_years`, `carbs_goal_g`, `daily_kcal_goal`, `daily_sleep_goal_minutes`, `daily_steps_goal`, `daily_water_goal_ml`, `diet_preference`, `fat_goal_g`, `height_cm`, `id`, `manual_energy`, `onboarding_completed`, `protein_goal_g`, `sex`, `target_weight_kg`, `weight_goal`, `weight_kg` |

## Policies (26)

| Tabelle | Policy | Befehl | Rollen | USING | WITH CHECK | aus |
|---|---|---|---|---|---|---|
| `chat_messages` | `chat_messages_select_own` | `select` | `authenticated` | `auth.uid() = user_id` | — | `20260517100000_coach_chat.sql` |
| `chat_quota_usage` | `chat_quota_select_own` | `select` | `authenticated` | `auth.uid() = user_id` | — | `20260517100000_coach_chat.sql` |
| `chat_sessions` | `chat_sessions_delete_own` | `delete` | `authenticated` | `auth.uid() = user_id` | — | `20260517170000_chat_sessions.sql` |
| `chat_sessions` | `chat_sessions_insert_own` | `insert` | `authenticated` | — | `auth.uid() = user_id` | `20260517170000_chat_sessions.sql` |
| `chat_sessions` | `chat_sessions_select_own` | `select` | `authenticated` | `auth.uid() = user_id` | — | `20260517170000_chat_sessions.sql` |
| `chat_sessions` | `chat_sessions_update_own` | `update` | `authenticated` | `auth.uid() = user_id` | `auth.uid() = user_id` | `20260517170000_chat_sessions.sql` |
| `favorite_meals` | `favorite_meals_delete_own` | `delete` | `authenticated` | `user_id = auth.uid()` | — | `20260516160000_app_data_schema.sql` |
| `favorite_meals` | `favorite_meals_insert_own` | `insert` | `authenticated` | — | `user_id = auth.uid()` | `20260516160000_app_data_schema.sql` |
| `favorite_meals` | `favorite_meals_select_own` | `select` | `authenticated` | `user_id = auth.uid()` | — | `20260516160000_app_data_schema.sql` |
| `favorite_meals` | `favorite_meals_update_own` | `update` | `authenticated` | `user_id = auth.uid()` | `user_id = auth.uid()` | `20260516160000_app_data_schema.sql` |
| `lifetime_stats` | `lifetime_stats_select_own` | `select` | `authenticated` | `user_id = auth.uid()` | — | `20260516160000_app_data_schema.sql` |
| `logged_meals` | `logged_meals_delete_own` | `delete` | `authenticated` | `user_id = auth.uid()` | — | `20260516160000_app_data_schema.sql` |
| `logged_meals` | `logged_meals_insert_own` | `insert` | `authenticated` | — | `user_id = auth.uid()` | `20260516160000_app_data_schema.sql` |
| `logged_meals` | `logged_meals_select_own` | `select` | `authenticated` | `user_id = auth.uid()` | — | `20260516160000_app_data_schema.sql` |
| `logged_meals` | `logged_meals_update_own` | `update` | `authenticated` | `user_id = auth.uid()` | `user_id = auth.uid()` | `20260516160000_app_data_schema.sql` |
| `profiles` | `profiles_insert_own` | `insert` | `authenticated` | — | `auth.uid() = id` | `20260516150000_create_profiles.sql` |
| `profiles` | `profiles_select_own` | `select` | `authenticated` | `auth.uid() = id` | — | `20260516150000_create_profiles.sql` |
| `profiles` | `profiles_update_own` | `update` | `authenticated` | `auth.uid() = id` | `auth.uid() = id` | `20260516150000_create_profiles.sql` |
| `user_recipes` | `user_recipes_delete_own` | `delete` | `authenticated` | `user_id = auth.uid()` | — | `20260530091000_user_recipes.sql` |
| `user_recipes` | `user_recipes_insert_own` | `insert` | `authenticated` | — | `user_id = auth.uid()` | `20260530091000_user_recipes.sql` |
| `user_recipes` | `user_recipes_select_own` | `select` | `authenticated` | `user_id = auth.uid()` | — | `20260530091000_user_recipes.sql` |
| `user_recipes` | `user_recipes_update_own` | `update` | `authenticated` | `user_id = auth.uid()` | `user_id = auth.uid()` | `20260530091000_user_recipes.sql` |
| `weight_log` | `weight_log_delete_own` | `delete` | `authenticated` | `user_id = auth.uid()` | — | `20260516160000_app_data_schema.sql` |
| `weight_log` | `weight_log_insert_own` | `insert` | `authenticated` | — | `user_id = auth.uid()` | `20260516160000_app_data_schema.sql` |
| `weight_log` | `weight_log_select_own` | `select` | `authenticated` | `user_id = auth.uid()` | — | `20260516160000_app_data_schema.sql` |
| `weight_log` | `weight_log_update_own` | `update` | `authenticated` | `user_id = auth.uid()` | `user_id = auth.uid()` | `20260516160000_app_data_schema.sql` |

Tabellen ohne Zeile hier tragen bewusst keine Policy: RLS ist an,
also erreicht sie ausser dem Funktionseigentuemer und
`service_role` niemand.

### Warum `auth.uid()` und nicht `(select auth.uid())`

PostgreSQL empfiehlt fuer `stable` Funktionen in Policies die
Schreibweise `(select auth.uid())`: der Planer hebt sie in einen
InitPlan und wertet sie einmal statt je Zeile aus. Alle Policies
hier stehen trotzdem in der direkten Form — bewusst (Befund
P7-06, Review 2026-08-29):

* Der Gewinn faellt nur bei einem **Seq Scan** an. Jede Tabelle
  oben hat `user_id` (bzw. `id`) als **fuehrende Indexspalte**,
  und `auth.uid()` ist `stable`, taugt also selbst als
  Index-Bedingung — die Plaene, die die App erzeugt, sind
  Index-Scans.
* Der Preis waere ein `drop`/`create` **jeder** Policy in einer
  Migration: die gesamte Zugriffskontrolle der App in einem
  Schritt neu geschrieben, fuer Mikrosekunden.

Die Entscheidung ist nicht endgueltig: `normalisiereAusdruck` in
`test/migrations/migration_schema.dart` liest beide Schreibweisen
als dieselbe Bedingung, der Waechter bliebe nach einer Umstellung
also gruen.

## Funktionen in `public` (19)

| Funktion | Rechte des | `search_path` | EXECUTE fuer | aus |
|---|---|---|---|---|
| `claim_chat_quota` | **Eigentuemers** | `public` | `service_role` | `20260517100000_coach_chat.sql` |
| `consume_edge_rate_limit` | **Eigentuemers** | `public, extensions` | `service_role` | `20260518000100_fix_edge_rate_limit_pgcrypto_search_path.sql` |
| `create_chat_session` | **Eigentuemers** | `public` | `authenticated`, `service_role` | `20260517170000_chat_sessions.sql` |
| `delete_account` | **Eigentuemers** | `''` | `authenticated`, `service_role` | `20260815120000_delete_account_reauth.sql` |
| `delete_chat_session` | **Eigentuemers** | `public` | `authenticated`, `service_role` | `20260517170000_chat_sessions.sql` |
| `enforce_user_row_cap` | **Eigentuemers** | `public` | `service_role` | `20260829120000_row_caps_and_hardening.sql` |
| `ensure_default_chat_session` | **Eigentuemers** | `public` | `authenticated`, `service_role` | `20260609120000_chat_rpc_least_privilege.sql` |
| `get_chat_quota_today` | **Eigentuemers** | `public` | `authenticated`, `service_role` | `20260808210000_chat_quota_honesty.sql` |
| `handle_new_user_profile` | **Eigentuemers** | `public` | `service_role` | `20260516150000_create_profiles.sql` |
| `handle_new_user_stats` | **Eigentuemers** | `public` | `service_role` | `20260516160000_app_data_schema.sql` |
| `increment_lifetime_stats` | **Eigentuemers** | `public` | `authenticated`, `service_role` | `20260814120000_audit_rls_guard.sql` |
| `list_chat_sessions` | **Eigentuemers** | `public` | `authenticated`, `service_role` | `20260517170000_chat_sessions.sql` |
| `prune_edge_rate_limits` | **Eigentuemers** | `public` | `service_role` | `20260517220000_security_hardening.sql` |
| `record_tracking_day` | **Eigentuemers** | `public` | `authenticated`, `service_role` | `20260811120000_lifetime_stats_integrity.sql` |
| `refund_chat_quota` | **Eigentuemers** | `public` | `service_role` | `20260808210000_chat_quota_honesty.sql` |
| `rename_chat_session` | **Eigentuemers** | `public` | `authenticated`, `service_role` | `20260517170000_chat_sessions.sql` |
| `rls_auto_enable` | Aufrufers | `public` | `service_role` | `20260814120000_audit_rls_guard.sql` |
| `set_updated_at` | Aufrufers | `public` | `service_role` | `20260516150000_create_profiles.sql` |
| `touch_chat_session` | **Eigentuemers** | `public` | `service_role` | `20260517170000_chat_sessions.sql` |

`security definer` heisst: der Rumpf laeuft mit den Rechten des
Eigentuemers und damit an RLS vorbei. Jede solche Funktion pinnt
deshalb ihren `search_path`, und jede, die `authenticated`
aufrufen darf, bindet sich selbst an `auth.uid()` — beides prueft
`test/migrations/rls_invariants_test.dart`.
