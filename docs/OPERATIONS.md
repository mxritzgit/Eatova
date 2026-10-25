# Operations and recovery

This runbook describes operator procedures and a reproducible synthetic restore
test. It does not establish that production backups, monitoring, staffing or a
particular deployed revision match these procedures. Record dated live evidence
separately in the security audit. Do not put credentials, user records, crash
payloads or database dumps in GitHub issues, commits or CI artifacts.

## Ownership and access

The repository maintainer coordinates incidents and releases. The Supabase
organization owner controls database recovery and membership; the provider
account owner controls provider keys and billing. Before production launch,
assign a reachable primary and backup person to those roles, agree an escalation
channel, and test access without copying credentials into the record. A role
description alone is not an on-call arrangement.

Use separate projects and credentials for development, staging and production.
Check the project identity at each deployment; a secret-manager environment
named `dev` does not prove that its target is non-production. CI unit tests use
dummy configuration and isolated databases. Restrict deployment credentials to
the intended protected environment and branch. Review admin membership and
token permissions after personnel changes and at least quarterly. Enroll and
verify administrators' MFA and recovery access before enforcing a policy that
could lock out an organization.

Direct Postgres and pooler connections must use TLS, preferably `verify-full`
with the provider CA and hostname verification. Supabase's HTTP services already
require TLS. Changing database SSL enforcement briefly restarts the database:
inventory direct clients, prepare a maintenance window, and confirm the applied
setting and project health afterwards. Network allowlists require a verified
list of operating networks; do not guess addresses or block unknown operators.
See [Supabase SSL enforcement](https://supabase.com/docs/guides/platform/ssl-enforcement).

## Backups and the restore rehearsal

The operator must choose and record a production RPO (maximum tolerable data
loss), RTO (maximum recovery time), retention period, encrypted backup location,
backup owner and failure-notification route. Do not equate a successful dump
with a usable restore or infer coverage from a `walg_enabled` flag. Verify actual
completed restore points and their age. Supabase currently provides automatic
daily backups on paid plans; Free projects need their own export/off-site
strategy. Database backups do not contain the bytes of Storage objects.
See [backup scope and retention](https://supabase.com/docs/guides/platform/backups).

Run the rehearsal with Python 3 and Docker:

```sh
python test/operations/backup_restore.py --prove-detection
```

The PostgreSQL image digest is pinned in the script and must match the RLS CI
image. Pull that exact image first if it is absent locally. The script accepts
no database URL, account credentials, input dump or existing container name.
It creates two new containers with no network and no published ports, applies
all repository migrations to the source, and seeds two reserved synthetic
identities. It then exports a custom-format backup in memory, restores into the
second cluster with explicit application roles, compares table contents and
catalog definitions, and verifies own-user access, cross-user rejection and
anonymous rejection using restricted roles. The detection option deliberately
disables RLS and removes a synthetic row to prove those failures are caught.
Cleanup verifies the unique container ownership label before removing only the
containers created by that run.

Keep the exit code and JSON result: source revision, image digest, migration
count, restore duration, data/schema/role checks and detection results. A tiny
synthetic database's duration is not a production RTO. This rehearsal covers
the repository schema and minimal test Auth scaffold; it does not recover real
Supabase Auth infrastructure, Storage files, Edge secrets, provider accounts,
device-only recipe images or a managed physical/PITR backup.

A production recovery exercise needs a separate approved destination, encrypted
transfer and controlled data access. Plan database and object-storage recovery
together, including deletions that must remain deleted, schema/function version
compatibility, Auth settings, secrets and external-provider configuration. Never
restore over production as a test. Validate ownership boundaries, representative
authorized reads/writes and post-restore integrity before opening traffic. Record
the achieved recovery point and duration, then dispose of the recovery copy
under the agreed retention and access policy.

## Monitoring and evidence

Password changes also depend on managed Auth configuration. The protected
`supabase-drift` job on `main` runs the read-only
[`auth_config_drift.py`](../scripts/security/auth_config_drift.py) audit against
[`auth_config.expected.json`](../supabase/auth_config.expected.json):
current-password enforcement, reauthentication and password-change notifications
must all be enabled, and mail quota, `site_url`, OTP settings, redirect
allow-list and the published mail templates must match. Missing settings,
invalid types and read failures fail the audit without printing credentials,
unpinned values or template bodies. PR jobs run only its
offline tests and disposable Auth probes, with no production credentials.
See the [password contract and rollout](../supabase/AUTH_EMAIL_OTP.md).
Do not disable current-password enforcement to make an old app build's settings
dialog work: distribute a compatible client; sign-in and mail recovery remain
the supported access paths. Native OTP/provider exceptions are documented and
must not be mistaken for a guarantee of fresh mailbox proof on every change.

The application disables Sentry default PII, screenshots, view hierarchy,
automatic session tracking, replay and tracing; event and breadcrumb filters
are wired in `lib/src/services/crash_reporter.dart`. Provider diagnostics use
allowlisted metadata. These source controls do not prove server-side retention,
administrator audit logs, alert routing or that a deployed app has a Sentry DSN.

The following are initial rule proposals to agree with the operator, not claims
that alerts exist. Use aggregated counters and technical categories, never meal
content, images, chat text, access tokens or user-identifying labels.

| Signal | Initial trigger to review | Required response |
| --- | --- | --- |
| API availability | More than 5% server errors over 5 minutes with at least 20 requests | Check deployment, database health and sanitized error categories |
| Authentication abuse | Sustained rejected-login/rate-limit spike above the established baseline | Review aggregate origin/rate data and account protections |
| AI budget | 60% of an approved daily reservation limit: all calls, pictures or the [Free pool](#free-ai-pool) (the [ops watch](#ops-watch) threshold since Premium); separate alert at exhaustion | Check usage trend, reserve policy and stop switches |
| Backups | Latest completed recovery point older than the agreed RPO or a failed scheduled backup | Repair backup path and verify a new usable recovery point |
| Privileged changes | Owner/membership/token changes or security protection disabled | Verify the authorized change and actor through restricted admin audit access |
| Monitoring failure | Missing expected heartbeat or disabled rule | Restore collection/routing before relying on silence |

For every actual rule record its provider/project, rule identifier, owner,
threshold/window, destination, repeat suppression, retention and last successful
test time. Test evaluation with synthetic data in a notification-suppressed
destination before any authorized routing test. Do not send unsolicited test
alerts to real recipients. A configured rule without delivery evidence remains
unverified. Recheck access, rules and restore evidence after material changes.

### AI call telemetry

Every paid provider call writes one JSON line to `function_logs`, from
`coach-chat`, `analyze-meal` and `recipe-import`
([ai_telemetry.ts](../supabase/functions/_shared/ai_telemetry.ts)):

```json
{"event":"ai_call","fn":"coach-chat","route":"chat","provider":"anthropic","model":"claude-sonnet-5-5","effort":"high","stream":true,"attempt":1,"outcome":"ok","http_status":200,"latency_ms":8423,"stop_reason":"end_turn","input_tokens":812,"output_tokens":233,"cache_creation_input_tokens":0,"cache_read_input_tokens":2400,"refunded":false}
```

| Field | Meaning |
| --- | --- |
| `fn`, `route` | Function and call: `chat`, `classifier`, `recipe`, `plan`, `log`, `image` (Coach); `analyze`, `describe`; `import` |
| `provider`, `model`, `effort` | `anthropic` or `openrouter` (recipe images), the configured model id, thinking effort (`null` for images) |
| `stream`, `attempt` | Streamed Coach answer; 1-based attempt of a recipe-import retry |
| `outcome`, `http_status` | `ok`, `refused` (provider safety stop), `timeout`, `aborted` (client gone), `error`; the provider's HTTP status or `null` |
| `latency_ms` | From request start to the settled result, for a stream to its end |
| `stop_reason` | Provider stop reason from a fixed list (`end_turn`, `max_tokens`, `refusal`, ...), else `other` |
| `*_tokens` | Usage counters as reported, `null` if absent. Claude's `input_tokens` excludes cached tokens: the prompt is input + cache creation + cache read |
| `refunded` | The user's Coach question slot for this request was given back. Always `false` in analyze-meal and recipe-import, which have no refund |

The line is built from an allowlist: enum values (anything else becomes
`other`), bounded integers, booleans and `null`. It never carries prompts,
answers, user ids, IPs or request ids; tests feed content into every field and
check that it does not appear. Telemetry never throws. `coach-chat` writes its
lines when the request, or its stream, has settled, so `refunded` is final; a
call whose function is killed before that point leaves no line. A refusal the
app derives from an answer (Layer 3, an unusable draft) counts as `ok` here.

Query the lines in the Supabase dashboard's Logs Explorer (source
`function_logs`, BigQuery dialect; set the time range in the picker). The
queries below were written against the documented schema and not run against
the live project. They extract fields with `regexp_extract`, which works
because the key order is fixed.

```sql
-- Tokens per function, route and day. Price them with the provider's current
-- price list: cache writes and reads are billed at different rates than input.
select
  timestamp_trunc(timestamp, day) as day,
  regexp_extract(event_message, r'"fn":"([a-z-]+)"') as fn,
  regexp_extract(event_message, r'"route":"([a-z]+)"') as route,
  count(*) as calls,
  sum(cast(regexp_extract(event_message, r'"input_tokens":(\d+)') as int64)) as input_tokens,
  sum(cast(regexp_extract(event_message, r'"cache_creation_input_tokens":(\d+)') as int64)) as cache_write_tokens,
  sum(cast(regexp_extract(event_message, r'"cache_read_input_tokens":(\d+)') as int64)) as cache_read_tokens,
  sum(cast(regexp_extract(event_message, r'"output_tokens":(\d+)') as int64)) as output_tokens,
  countif(regexp_contains(event_message, r'"refunded":true')) as refunded_calls
from function_logs
where regexp_contains(event_message, r'^\{"event":"ai_call"')
group by day, fn, route
order by day desc, output_tokens desc;

-- Prompt-cache hit rate per route: the share of prompt tokens read from cache.
-- Near zero at low traffic means the 5-minute cache expires between requests.
select route,
  safe_divide(sum(cache_read), sum(input + cache_write + cache_read)) as cache_read_share,
  countif(cache_read > 0) as calls_with_cache_hit,
  count(*) as calls
from (
  select
    regexp_extract(event_message, r'"route":"([a-z]+)"') as route,
    coalesce(cast(regexp_extract(event_message, r'"input_tokens":(\d+)') as int64), 0) as input,
    coalesce(cast(regexp_extract(event_message, r'"cache_creation_input_tokens":(\d+)') as int64), 0) as cache_write,
    coalesce(cast(regexp_extract(event_message, r'"cache_read_input_tokens":(\d+)') as int64), 0) as cache_read
  from function_logs
  where regexp_contains(event_message, r'^\{"event":"ai_call","fn":"[a-z-]+","route":"[a-z]+","provider":"anthropic"')
)
group by route;

-- p50/p95 latency per route and stream mode, successful calls only.
select route, stream, count(*) as calls,
  approx_quantiles(latency_ms, 100)[offset(50)] as p50_ms,
  approx_quantiles(latency_ms, 100)[offset(95)] as p95_ms
from (
  select
    regexp_extract(event_message, r'"route":"([a-z]+)"') as route,
    regexp_contains(event_message, r'"stream":true') as stream,
    cast(regexp_extract(event_message, r'"latency_ms":(\d+)') as int64) as latency_ms
  from function_logs
  where regexp_contains(event_message, r'^\{"event":"ai_call"')
    and regexp_contains(event_message, r'"outcome":"ok"')
)
group by route, stream;

-- BE-3: answers cut by max_tokens per route, and how many refunded the slot.
select
  regexp_extract(event_message, r'"route":"([a-z]+)"') as route,
  count(*) as calls,
  countif(regexp_contains(event_message, r'"stop_reason":"max_tokens"')) as max_tokens_stops,
  countif(regexp_contains(event_message, r'"stop_reason":"max_tokens"')
    and regexp_contains(event_message, r'"refunded":true')) as max_tokens_refunded
from function_logs
where regexp_contains(event_message, r'^\{"event":"ai_call"')
group by route
order by max_tokens_stops desc;
```

Two recommended alerts, as instructions. The second runs in the
[ops watch](#ops-watch) once its environment exists; the first is not
configured by this repository. Follow the record and test rules above for
each.

1. **Edge Function 5xx rate.** Every 5 minutes, count responses by status in
   `function_edge_logs` (the gateway's view, which also sees boot errors and
   timeouts that leave no `ai_call` line), for example with the dashboard's
   invocation query: `from function_edge_logs cross join unnest(metadata) as m
   cross join unnest(m.response) as response`, grouping
   `response.status_code >= 500` per `m.function_id`. Alert above 5% over 5
   minutes with at least 20 requests, as in the table above. Run the query from
   a protected scheduler through the Management API's logs endpoint, or route a
   log drain into an alerting tool where the plan allows it. Do not put the
   management token into PR-reachable workflows.
2. **Provider budget at 60%.** Schedule the readiness check below: it exits 1
   when global AI calls, images or the Free pool's calls reach the warning
   share of their approved daily limit (`--budget-warning-percent`, 60 in the
   ops watch), and 2 when the state is unknown. Route both
   exit codes and a missed run. Separately set the provider accounts' spend
   limits and alerts ([provider spend limits](#provider-spend-limits)); the
   daily reservation limit is not a money limit.

### Executable read-only readiness check

Run the [metadata checker](../scripts/operations/readiness.py) with Python 3.11+
and a management token injected into the process as `SUPABASE_ACCESS_TOKEN` by
the approved secret manager. For the Eatova workstation, follow the local
Infisical access guide; retrieve only that token and the named project reference.
Independently compare the reference with the intended linked project before use.
Do not put credentials in command arguments, shell history or a committed file.

```sh
python scripts/operations/readiness.py \
  --expected-project-ref <verified-production-ref> \
  --backup-max-age-hours <operator-approved-RPO-hours>

# Optional: also verify the identity of a separately designated staging project.
python scripts/operations/readiness.py \
  --expected-project-ref <verified-production-ref> \
  --staging-project-ref <verified-staging-ref> \
  --backup-max-age-hours <operator-approved-RPO-hours>

# Offline tests, with fixed time and stubbed responses; no token/network needed.
python -m unittest discover -s test/operations -p '*_test.py'
```

The script verifies project identity first, reads completed-backup metadata and
the enabled PITR recovery window, and reads only the singleton AI limits and the
current UTC day's global call, image and Free-pool counters. The sole POST
uses Supabase's [read-only SQL endpoint](https://supabase.com/docs/reference/api/v1-read-only-query)
with a fixed aggregate query. It never queries account rows, sends notifications,
creates a backup, changes a stop switch or exports a database. HTTPS uses the
fixed Supabase management host, certificate/hostname verification, no proxies or
redirects, a response-size cap and timeouts. Errors contain fixed categories or
HTTP status numbers; raw responses and exception text are withheld.

The JSON report and exit code can be consumed by an operator-approved scheduler:

| Exit | Meaning | Operator action |
| --- | --- | --- |
| `0` | Requested metadata checks passed | Keep the dated result; still require restore and alarm-delivery evidence |
| `1` | Attention: project unhealthy, no fresh completed recovery point, a failed backup, an active AI stop/zero limit, or usage at the warning/exhaustion threshold | Review the indicated condition; stops may be intentional |
| `2` | Unknown: identity/access/transport/response validation failed | Treat the check as unavailable; do not read silence as healthy |

The budget part also reads the [Free pool](#free-ai-pool)
(`daily_free_call_limit` and the day's `free_calls`): `free_calls_warning`
and `free_calls_exhausted` use the same warning share as calls and images,
and `free_limit_not_below_total` means the pool is not below
`daily_call_limit`, so it no longer keeps a reserve for Premium.

The script's default usage warning is 80%; the [ops watch](#ops-watch)
passes 60 (the Premium decision, see [alerts and checks](#alerts-and-checks)).
Change it explicitly with `--budget-warning-percent` after agreeing the
threshold. The required backup
age is a monitoring threshold, not proof of achieved RPO/RTO. A current backup
record is not a successful restore. Completed daily physical backups count even
with PITR disabled; if only an unlisted physical window is returned without PITR,
restore access remains unknown. See the [backup API](https://supabase.com/docs/reference/api/v1-list-all-backups)
and [physical backup behavior](https://supabase.com/docs/guides/platform/backups).
Any failed backup record is reported even
if another recent record completed; review retained failures before suppressing
them. Missing metadata and 403 responses remain unknown, never zero usage or
an empty backup inventory. A UTC midnight rollover invalidates that snapshot;
rerun once for the new day. Output excludes project names/refs, account IDs,
tokens, payloads and provider error bodies.

Without `--backup-max-age-hours` the backup check is skipped and the report
says `"backups": "not_checked_no_max_age_supplied"`; that is not a green
backup. `--summary FILE` appends a Markdown table of states, budget counters
and reasons. Requests send a browser user agent, as the deploy tooling does:
a Cloudflare rule in front of the Management API rejects default library
agents (error 1010).

The tool itself installs no schedule, notification route or paid resource; the
[ops watch](#ops-watch) schedules it. Run it from a trusted operator host or
protected deployment environment; never expose the token to PR code. Add a
heartbeat/dead-man check and approved routing for exit `1`, exit `2`, and
missed runs. Test those routes separately with
synthetic results before a specifically authorized delivery test. If staging
is omitted it is explicitly unchecked. Two distinct verified project identities
alone do not prove separate credentials, data, billing or deployment isolation.
The checker does not establish an Anthropic or OpenRouter money limit, external backups,
Storage-file coverage, provider retention, Sentry rules or end-to-end recovery.

### Reported Coach answers

Users report Coach answers and generated recipe pictures in the app
(`public.ai_reports`, see [Backend](BACKEND.md#ai-consent-and-answer-reports)).
Review them from a trusted operator connection, read-only, newest first, e.g.
`select created_at, reason, target, message_id, session_id from
public.ai_reports order by created_at desc limit 50`. A `message_id` that is a
UUID is `chat_messages.id`; a `local-…` id is an answer the device had not
reloaded yet, found through `session_id` and the closest assistant message
before `created_at`. Open message content only as far as the case needs it and
record the outcome (prompt or guardrail change, provider report) in a
restricted case record, not in this repository. Nothing alerts on new reports
yet; who reviews them and how often is an open owner decision.

### Ops watch

**Ops watch** ([ops-watch.yml](../.github/workflows/ops-watch.yml)) runs
hourly (minute 17) and on demand from `main`. It makes no paid call and reads
no user data:

1. the readiness check above with `--budget-warning-percent 60`: project
   identity and health, the AI stop switches, the zero account limit, the
   shared daily AI calls, images and Free-pool calls at 60 % or exhausted,
   and a Free pool not below the total. Exit 1 (attention)
   and exit 2 (unknown) fail the run. Backups are checked only once the
   variable `OPS_WATCH_BACKUP_MAX_AGE_HOURS` holds the agreed RPO in hours;
   without it the summary names them as not checked, because a project
   without completed backups would otherwise fail every hour;
2. the deploy workflow's boot probe for every function (`probe --slugs all`):
   preflight 204, the gateway's 401 without a token and the handler's own 401
   with the anon key (for the public webhook `store-notifications` the
   handler's own `invalid_notification_auth` 401 both times). A missing,
   undeployed or crashing function, or one whose `verify_jwt` differs from
   its registered mode, fails the run. A request without an answer or with a
   5xx is asked once more after five seconds, so one lost request does not
   fail the run (2026-10-22: one `analyze-meal` request never reached the
   gateway and the run went red).

The job summary holds both tables (states, counters, HTTP statuses); the log
holds the readiness JSON and the probe table, neither with a ref, token or
response body. A failed
run is the alert: GitHub mails it to the person who last changed the
schedule, if their notification settings send Actions failures.

One-time setup on GitHub (owner):

1. Create the environment `ops-watch`: deployment branches and tags limited
   to `main`, administrators not allowed to bypass. No required reviewers: an
   hourly run cannot wait for an approval, and the job only reads.
2. Add the environment secrets `SUPABASE_ACCESS_TOKEN` (a management token;
   prefer a separate one so it can be revoked alone), `SUPABASE_PROJECT_REF`
   and `SUPABASE_ANON_KEY` (the same public key the deploy probe uses).
   `supabase-drift` lacks the anon key, and `supabase-deploy` requires an
   approval per run, so neither is reused.
3. Optional: the variable `OPS_WATCH_BACKUP_MAX_AGE_HOURS` once an RPO is
   agreed.
4. Run the workflow once by hand and keep the run URL as delivery evidence;
   check that a failed run reaches the owner's mail.

Limits: a run that never happens is silent. GitHub delays scheduled runs
under load and disables the schedule of a public repository after 60 days
without activity, so check the workflow's run list when the mails stop
looking routine. Not watched yet: the Edge Function 5xx rate (alert 1 above)
and daily `ai_call` totals; Sentry and provider-side spend limits stay with
their own consoles.

### Account export and deletion outside the app

Use a restricted case record, not a public GitHub issue. Record a case reference,
verified account ownership, requested scope, assigned operator, affected systems,
completion evidence and remaining retention dates. Authenticate the request
through the existing account/recovery process; an email address or user ID alone
is not authorization. Keep the minimum identifiers needed for authorized lookup
inside that record. Never ask for passwords, login codes or complete chat logs.

| System | Authorized export/deletion work | Evidence needed to close the case |
| --- | --- | --- |
| App server records | Use the authenticated in-app export and account deletion; verify result in the correct project. The export covers server data only. | Completion and own-account scope; synthetic A/B rehearsal before changing the workflow |
| Device and offline data | Before deletion, let the owner preserve wanted unsynced edits and device-only pictures. Explain that server export excludes them. Verify logout/account deletion clears local account caches on each device. | Owner/device check; separately record unavailable devices and OS-controlled copies |
| Supabase Auth and operational records | Check permitted Auth metadata and configured platform log retention using restricted admin access. Avoid bulk log downloads; distinguish live-row deletion from retained audit records. | Provider-supported outcome or documented retention/exception; no unrelated users in the response |
| Anthropic (text/vision) and OpenRouter (recipe pictures) | Identify each runtime key's owning account and settings. Determine which provider records exist and use the provider's supported access/deletion route. Do not claim zero retention from a different key's settings. | Account/configuration evidence and provider confirmation or explicit retention limit |
| Sentry | Verify the deployed project's settings and retention. Use only necessary authorized lookup; sanitized client events may provide no reliable account linkage. Do not invent a match. | Actual project settings and supported outcome, or a precise non-identifiability limitation |
| Support and communications | Search only the relevant authorized support locations and account-correlated records; remove unrelated third-party information from an export. | Each responsible location's completion/retention evidence |
| Backups and recovery copies | Record which retained copies may predate deletion and when they expire. Restrict access and keep a minimal, separately protected deletion-replay record when required by the approved retention process. | Agreed retention and expiry; any restore re-applies applicable deletions before reopening traffic |

Deliver exports only through an authenticated, access-restricted route agreed
with the owner. Verify the recipient and record delivery without retaining a
second unsecured payload. Apply the approved short-lived case-artifact retention
and remove temporary copies after delivery. For a restore, the deletion replay
record must survive separately from the old database being recovered; do not
restore it from that same older backup. Test this with synthetic deleted/retained
accounts in the separate recovery destination. Contractual/legal retention,
exceptions and response deadlines require the responsible privacy owner's
decision. A technical database cascade alone does not close the external case.

Remaining operator inputs are specific: production backup destination and
RPO/RTO/retention; separately identified staging project and credentials; actual
Anthropic and OpenRouter accounts/keys and money budgets; Play Console and App
Store Connect access and the Premium service-account key; read access to Sentry/provider settings;
primary/backup responders and approved alert destination; privacy owner and
provider access/deletion procedures. Keep their secrets and personal contact
details outside this repository.

## Incident response, containment and rollback

1. Record UTC time, affected service/revision, sanitized symptom, known impact
   and evidence source. Use the private route in [SECURITY.md](../SECURITY.md).
   Restrict incident records; preserve only necessary evidence without copying
   raw health data or credentials.
2. Identify an incident coordinator and service owner. Assess active disclosure,
   account compromise, cost runaway and data-loss risk. Involve the responsible
   privacy/legal owner when notification duties need assessment; do not infer
   legal deadlines or contact users automatically from this runbook.
3. Contain the affected operation while preserving evidence and durable user
   data. For product search, `EATOVA_MIRROR_SEARCH_KEY=disabled` is the supported
   server switch; clients fall back to public OFF. See [search-key rotation](BACKEND.md#product-search-key-rotation).
   For AI, after `20260915091000_ai_provider_budgets.sql` and the corresponding
   handlers are deployed and verified, a privileged database administrator can
   update the singleton `public.ai_provider_limits` row: `enabled=false` stops
   new reservations globally; `coach_enabled`, `analysis_enabled` and
   `images_enabled` scope the stop. Zero daily limits also deny reservations.
   Two switches stop only Free AI and keep Premium working (see the
   [Free AI pool](#free-ai-pool)).
   Confirm the expected row exists and verify the setting afterwards. These
   switches do not cancel in-flight provider work or reverse existing charges.
   Do not delete user history or reset counters to recover service. For
   Premium store processing see [the new functions' stop](#deploy-modes-of-the-new-functions).
4. For an exposed secret, identify its consumers and minimum permissions,
   prepare the replacement in the secret manager, update those consumers,
   verify a legitimate operation using synthetic input, revoke the old secret,
   and confirm rejection of the old credential without logging it. Revoke a
   compromised management token/session promptly where ongoing access poses
   risk. Supabase signing-key changes and privileged DB credential changes need
   explicit consumer/session planning; a public anon/search-only key is not
   automatically evidence of a secret breach. Never rotate an unrelated key.
5. Prepare the smallest reviewed fix or last compatible verified application/
   function revision. Use protected PRs and required checks; record deployed
   function/source versions and artifact checksums separately from Git merge.
   Deploy or roll back Edge Functions with the
   [deploy workflow](#edge-function-deploys); its record is that evidence.
   Database migrations are forward-only by default: review a corrective
   migration and data compatibility instead of blindly undoing SQL. A database
   restore needs the separate recovery procedure above and acceptance of its
   data-loss window. Do not label an older client build safe without testing its
   compatibility with current schema and server behavior.
6. Verify containment and recovery with the relevant synthetic regression,
   restricted-role checks, applied settings and aggregate health counters.
   Restore only the intended switches after verification. Document cause,
   affected interval, credential actions, remaining uncertainties and follow-up
   owner/date. Confirm alert delivery and backup freshness before closure.

## Edge Function deploys

**Deploy Edge Functions** ([deploy-functions.yml](../.github/workflows/deploy-functions.yml))
replaces deploys from a workstation checkout, which uploaded CRLF files from
Windows and once left a redeploy unrecorded. It deploys only Edge Functions;
apply migrations separately and first when a function needs them. A merge
still deploys nothing.

### One-time setup on GitHub (owner)

1. Create the environment `supabase-deploy` (Settings, Environments):
   - Required reviewers: the owner, plus a backup maintainer if there is one.
     With a single maintainer, leave "Prevent self-review" off, or nobody can
     approve.
   - Deployment branches and tags: selected branches, only `main`.
   - Do not allow administrators to bypass the protection rules.
2. Add three environment secrets there, never as repository secrets, because
   any workflow of a branch can read repository secrets:
   - `SUPABASE_ACCESS_TOKEN`: the management token the Supabase CLI and the
     Management API read under this name; the same name as in `supabase-drift`.
     Prefer a token used only for deploys and revoke it on personnel changes.
   - `SUPABASE_PROJECT_REF`: the verified production project. As a secret, the
     target can only change with an environment change, and the value is
     masked in logs.
   - `SUPABASE_ANON_KEY`: the public key the boot probe sends, under the name
     the functions and the app use. It must pass the gateway's JWT check; if
     the publishable key does not, use the legacy anon JWT. Not a secret by
     nature, but kept out of the repository like the app's defines.
3. The CLI is pinned: `SUPABASE_CLI_SHA256` in the workflow is the SHA-256 of
   `supabase_linux_amd64.tar.gz` from the `v2.120.0` release, compared on
   2026-10-18 with that release's `checksums.txt` and GitHub's asset digest.
   An invalid value fails the run before it uses a secret. A CLI upgrade
   changes both values together, in a reviewed PR.

The first run is the first real check of the CLI commands
(`functions deploy --use-api`, `functions download --use-api`, `--workdir`) and
of the gateway answers the probe expects; none of this ran from the repository.

### Running a deploy

Actions, Deploy Edge Functions, Run workflow on `main`:

- `functions`: comma-separated slugs (`coach-chat,search-key`) or `all`.
- `sha`: empty deploys the current `main` head; a full 40-character SHA
  deploys that commit, which must be on `main`.
- `allow_below_floor`: off by default; see [Rollback](#rollback).

After the environment approval the run:

1. checks out `main` for its own tooling and the chosen commit separately, so
   an older commit never supplies its own deployer or verifier;
2. plans: the slugs exist, each has a boot probe definition, and the tracked
   `supabase/config.toml` sets `verify_jwt = false` only for a slug on the
   explicit allowlist of public webhooks in `deploy_functions.py` (only
   `store-notifications`, which authenticates every request itself); every
   other function keeps the CLI default `verify_jwt = true`, and the workflow
   never passes `--no-verify-jwt`;
3. refuses a commit older than a chosen function's lowest safe rollback
   commit (below), and a commit with a migration that is not registered in
   the live `supabase_migrations.schema_migrations` (the drift job's query,
   against the target's own `supabase/migrations/`): a function deployed
   before its migration answers its RPCs with 5xx. Apply the migration first;
4. reads each function's version and downloads its live source, compared with
   the commit ignoring CRLF; a mismatch here only shows what was live before;
5. deploys one function after another with the pinned CLI and `--use-api`;
6. reads back ACTIVE, the registered `verify_jwt` mode (true; false only for
   `store-notifications`) and a new version, downloads the live source
   again and compares it byte for byte with the function's import
   graph in the commit: a missing, changed or unexpected file fails;
7. runs the boot probe: preflight 204, 401 from the gateway without a token,
   and the handler's own 401 with the anon key, which proves it booted and
   passed its configuration check. `store-notifications` has no gateway
   check, so its probe expects the handler's own `invalid_notification_auth`
   401 both without a token and with the anon key. A request without an
   answer or with a 5xx is asked once more after five seconds. No user
   token, no paid call;
   a key that reaches the Auth lookup counts one failed lookup for the
   runner's address;
8. writes the deploy record and the job summary.

The record (artifact `deploy-record-<run>-attempt-<n>`, kept 90 days) holds the
source and `main` SHAs, the rollback flag, the slugs, versions before and
after, each check, whether the target's migrations were registered, which
functions went below their floor on an override, the CLI version, times and
the run URL; no project ref, key or response body. Copy its essentials into
the handoff entry of the rollout. Any failed check fails the run. A failure
after step 5 may mean some functions are already live: read the record, then
fix forward or roll back.

Only one run is active at a time and a running deploy is never cancelled.
GitHub keeps at most one waiting run per group: queuing another one cancels
the older waiting run before it starts.

### Rollback

Run the workflow with the older commit as `sha`. The same checks apply to that
tree and the record says `rollback: true`. Check compatibility first: the
older function must work with the current schema (migrations are
forward-only, see the RPCs it calls) and with installed app builds. When in
doubt, fix forward with a reviewed PR. `_shared` code is part of every
function's graph, so roll back all functions that need the older version.

Each function has a lowest safe rollback commit (`ROLLBACK_FLOORS` in
[deploy_functions.py](../scripts/operations/deploy_functions.py)); a target
that does not contain it is refused:

| Function | Floor | Why |
| --- | --- | --- |
| `coach-chat`, `analyze-meal`, `recipe-import` | `27ee6c44` | Free AI pool (#172): an older handler sends no `scope` or `resetAt` on a budget denial (the app's Free notice falls back to the general message) and uses the old Free numbers when the plan lookup fails; older `analyze-meal` and `recipe-import` keep the day slot of a capacity denial. Before #170 a handler also applied one limit to every account |
| `search-key` | `ea2722e6` | The last source verified live with today's schema and clients (identical before the #155 deploy); #170 changed only a comment |
| `subscription-verify`, `store-notifications` | `fdd8d63f` | `first_release`: the base of the Premium PR; a commit without the function fails as unknown anyway |

Only set `allow_below_floor` after checking that the older handler works with
the installed clients and the live schema; the record names the functions
deployed below their floor. Raise a floor in the same PR that makes older
handlers incompatible (a new required request field, a renamed RPC, a
migration the old code breaks on), and give a new function its floor before
its first deploy.

## Premium store setup

Owner steps outside the repository for the [Premium tier](PREMIUM.md)
(server side in [Backend](BACKEND.md#premium-plans-and-store-subscriptions)).
None of them was carried out from this repository; record each with its
date in the handoff, without keys, tokens or personal account data. Order:
migration live, merge, deploy `coach-chat`, `analyze-meal`, `recipe-import`,
`subscription-verify` and `store-notifications`, app build. The terms and the
privacy text for the paid tier must be published before the first real
purchase ([legal draft](PREMIUM-LEGAL-DRAFT.md)). Prices live only in the
store consoles; the app shows the store's price.

### Google Play

1. **Billing build and products.** Upload a build with the billing
   dependency (it adds `com.android.vending.BILLING`, which
   `android/permissions_allowlist.txt` must list) to the internal track; Play
   Console offers subscription products only once such a build exists and a
   payments profile is set up. Then, under Monetize, Subscriptions, create the
   subscription `eatova_premium` with two auto-renewing base plans:
   `monthly` (billing period one month, 7,99 EUR) and `yearly` (one year,
   49,99 EUR), prices for other countries set or converted in the console.
   On `yearly` add one offer with a 7-day free trial for new customers
   (Google's eligibility: never had this subscription); `monthly` gets no
   trial. Activate both base plans and the offer. Keep grace period and
   account hold enabled: they become the states `grace` and `on_hold`.
2. **License testers.** Under Setup, License testing, add the testers'
   Google accounts and invite them to the internal track. Their purchases
   cost nothing, renew in minutes instead of months, and arrive with
   `testPurchase`, stored as environment `test`; the Profile marks them as a
   test purchase. They grant Premium on the production backend.
3. **Service account.** In a Google Cloud project, enable the Google Play
   Android Developer API and create a service account without Cloud roles,
   used only for this (not the release lane's upload account). Invite its
   email in Play Console under Users and permissions, for the Eatova app,
   with exactly "View financial data, orders, and cancellation survey
   responses" and "Manage orders and subscriptions". New permissions can take
   hours to apply; until then verification answers `503 store_unavailable`.
   Create one JSON key for it.
4. **Function secret.** Set the whole key JSON as
   `EATOVA_PLAY_SERVICE_ACCOUNT_JSON` without putting the value on a command
   line (`supabase secrets set NAME=value` leaves it in shell history and the
   process list). Either paste it in the Supabase dashboard (Edge Functions,
   Secrets), or let a short script read the file and post it to the
   Management API, run under the approved secret manager so that
   `SUPABASE_ACCESS_TOKEN` and the verified `SUPABASE_PROJECT_REF` are
   injected into the process (`python set_play_secret.py <key-file>`):

   ```python
   # Reads the key file named as the only argument and the management token
   # from the environment; prints only the HTTP status.
   import json, os, sys, urllib.request

   class NoRedirect(urllib.request.HTTPRedirectHandler):
       def redirect_request(self, *args, **kwargs):
           return None  # a redirect raises instead of resending the token

   with open(sys.argv[1], encoding='utf-8') as f:
       key = json.load(f)
   body = json.dumps([{'name': 'EATOVA_PLAY_SERVICE_ACCOUNT_JSON',
                       'value': json.dumps(key, separators=(',', ':'))}]).encode()
   ref = os.environ['SUPABASE_PROJECT_REF']
   request = urllib.request.Request(
       f'https://api.supabase.com/v1/projects/{ref}/secrets', data=body, method='POST',
       headers={'Authorization': 'Bearer ' + os.environ['SUPABASE_ACCESS_TOKEN'],
                'Content-Type': 'application/json',
                'User-Agent': 'Mozilla/5.0 (eatova-ops)'})
   with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
       print(response.status)
   ```

   The browser user agent is needed because a Cloudflare rule in front of
   the Management API rejects default library agents (error 1010). Keep the
   script and the key file outside the repository, store the key in the
   secret manager and delete the downloaded copy. `EATOVA_PLAY_PACKAGE_NAME`
   and `EATOVA_PREMIUM_PRODUCT_IDS` are needed only when they differ from
   their defaults. To rotate, create a new key, set it the same way, check a
   purchase, then delete the old key in Google Cloud.
5. **Check.** A license tester buys on the internal track; the Profile shows
   Premium with the test badge. From an operator connection, read only
   non-secret columns, never `store_key`:
   `select platform, product_id, base_plan_id, status, expires_at, environment, acknowledged from public.store_subscriptions order by created_at desc limit 5`.
   Google refunds a purchase that is not acknowledged within three days, so
   `subscription-verify` must stay reachable. A new purchase is stored first
   with Google's state (`acknowledged = false`); once the server's
   acknowledgement succeeds, `mark_store_subscription_acknowledged` sets
   `acknowledged = true` on that row (in `verify` and in `refresh`), and any
   later verification stores Google's state again. An active or grace Google
   row still at `false` after a day therefore means the server's
   acknowledgement failed or was not recorded (a failed mark is ignored):
   look for `subscription-verify acknowledge failed`
   in the function logs (it carries only the HTTP status) and check the order
   in Play Console. The app's own purchase completion also acknowledges, so
   Play may already show it acknowledged; the row then turns `true` at the
   next verification.
6. **Optional: real-time developer notifications.** Without them refunds
   and cancellations reach the account only at the next restore or
   `refresh`.
   1. Set `EATOVA_PUBSUB_PUSH_AUDIENCE` (the audience string the push
      subscription will send, for example the push URL) and
      `EATOVA_PUBSUB_PUSH_SA_EMAIL` (the email of a dedicated push service
      account) as function secrets first; without them the function answers
      `503 not_configured` and Pub/Sub keeps retrying.
   2. In Google Cloud Pub/Sub create a topic and give
      `google-play-developer-notifications@system.gserviceaccount.com` the
      Pub/Sub Publisher role on it.
   3. Create a push subscription to
      `https://<project-ref>.supabase.co/functions/v1/store-notifications`
      with authentication on, using that service account and audience (in
      older projects the Pub/Sub service agent also needs the Service
      Account Token Creator role on it). Keep the default retry and message
      retention.
   4. In Play Console, Monetization setup, enter the topic
      (`projects/<gcp-project>/topics/<topic>`) for real-time developer
      notifications and send a test notification: the function answers 200
      to `testNotification`.

   Before switching this on, confirm the privacy wording for Pub/Sub as a
   processor ([PRIVACY.md](../PRIVACY.md), legal draft).
7. **Data safety.** In App content, Data safety, add Financial info,
   Purchase history: collected, not shared, linked to the account, optional
   (only for buyers), purpose app functionality; keep encryption in transit
   and deletion on request as declared. Check the answers against the form's
   current questions; the [legal draft](PREMIUM-LEGAL-DRAFT.md) lists the
   text to publish with it.

### App Store

These need the paid Apple Developer Program, which is not active yet (owner
decision); until then iOS shows the store as unavailable.

1. **Agreement.** Accept the Paid Apps Agreement in App Store Connect
   (Business: banking and tax). The App ID `com.eatova.app` needs the In-App
   Purchase capability.
2. **Products.** Under Monetization, Subscriptions, create the group
   "Eatova Premium" with `eatova_premium_monthly` (one month, 7,99 EUR) and
   `eatova_premium_yearly` (one year, 49,99 EUR), display name and
   description in German and English, and the review screenshot. Suggested
   levels: yearly above monthly, so a change to yearly applies at once and a
   change to monthly at the next renewal, as on Google Play. Family Sharing
   stays off (it cannot be turned off again once on).
3. **Introductory offer.** On `eatova_premium_yearly` only: free, one week,
   for new subscribers. Apple grants it once per subscription group.
4. **Server notifications.** Under App Information, App Store Server
   Notifications, set the production and the sandbox URL to
   `https://<project-ref>.supabase.co/functions/v1/store-notifications`,
   version 2. A sandbox purchase sends `SUBSCRIBED`; a `TEST` notification
   can be requested through the App Store Server API, which this repository
   does not call.
5. **Sandbox testers.** Under Users and Access, Sandbox, create testers and
   sign in with one on the device (Settings, App Store, Sandbox Account).
   Sandbox and TestFlight purchases are free, arrive as environment Sandbox,
   are stored as `sandbox` and grant Premium on the production backend (App
   Review buys the same way); the Profile marks them as test purchases.
6. **App privacy and review.** In App Privacy add Purchases, Purchase
   History: linked to the user, not used for tracking, purpose app
   functionality (it matches `NSPrivacyCollectedDataTypePurchaseHistory` in
   `ios/Runner/PrivacyInfo.xcprivacy`). The app description or the EULA field
   must link the terms of use and the privacy policy; the paywall links both.
   `EATOVA_APPLE_BUNDLE_ID` is needed only when the bundle id differs.

### Manual grants

`platform = 'manual'` gives an account Premium without a store, for testing
before the stores exist and for support cases. Run it from a trusted
operator connection (the Management API's SQL endpoint or the SQL editor),
not with the service key, which may only read the table. Take the account id
from the verified case record; the label names the case, never a person.

```sql
-- Grant until a fixed date. environment 'test' marks an operator test in the
-- Profile; use 'production' for a support case.
insert into public.store_subscriptions
  (user_id, platform, store_key, product_id, status, expires_at, environment, acknowledged)
values
  ('<account-uuid>', 'manual', 'manual:<case-label>', 'eatova_premium_manual',
   'active', '<end, e.g. 2026-12-31T23:59:59Z>', 'test', true);

-- End it early: the account is Free from its next request.
update public.store_subscriptions
  set status = 'revoked', updated_at = now()
  where platform = 'manual' and store_key = 'manual:<case-label>';
```

The Profile shows a manual grant as "Freigeschaltet bis {date}" and offers
no store management. The row is deleted with the account.

### Changing limits

The functions read `plan_tiers` on every request; a change applies from the
next request, without a deploy or an app release. The app shows the new
numbers after its next plan read (on start and on resume, at most every five
minutes).

```sql
update public.plan_tiers set coach_daily = 4, updated_at = now() where tier = 'free';
select tier, coach_daily, meal_analysis_daily, recipe_import_daily,
  provider_calls_daily, recipe_picture from public.plan_tiers order by tier;
```

- Bounds: 1 to 10,000 per feature, 0 to 10,000 provider calls.
- Raising a limit is always possible. Once the app is public, lowering a
  Free limit needs the AGB notice four weeks ahead; lowering a Premium limit
  changes a paid product and needs the notice and termination right of the
  terms (see the [legal draft](PREMIUM-LEGAL-DRAFT.md)). `20261026100000`
  lowered Free to 2 / 3 / 1 without a notice: the app is not public and its
  only accounts are the owner's test accounts.
- `provider_calls_daily` must stay above what the features can spend (Free
  2 Coach × 2 + 3 + 1 import × 2 = 9 calls, cap 11 for one refunded Coach
  retry; Premium 20 × 3 with pictures + 30 + 10 × 2 = 110 under 150), and
  `ai_provider_limits.daily_user_limit` at least the highest
  `provider_calls_daily`, because the lower value wins. A legacy account
  with Premium gets the merged maximum 20 × 3 + 100 + 20 × 2 = 200 as its
  ceiling (`resolve_plan` merges it), so the migration raises
  `daily_user_limit` to at least 200. A legacy Free account can spend
  5 × 3 + 100 + 20 × 2 = 155 against its 150, as before Premium.
- `FREE_FALLBACK` in `_shared/plan.ts` and the app's assumed defaults stay at
  the decided values; changing them needs a code change.

### Free AI pool

`reserve_ai_provider_call` counts every provider call of a Free account (tier
not `premium`, a legacy account without Premium included) in the global
`ai_provider_daily_usage.free_calls` and denies Free once it reaches
`ai_provider_limits.daily_free_call_limit` (`429 ai_budget_exhausted` with
`scope: "free"`). Premium is not counted and not stopped by it. Why, the
order of checks and the bounds: [Premium, section 7](PREMIUM.md#7-abuse-protection).

| Setting | Before the launch | Meaning |
| --- | --- | --- |
| `daily_free_call_limit` | 150 | Provider calls of all Free accounts together per UTC day |
| `daily_call_limit` | 400 | All provider calls per UTC day, Free and Premium |
| `daily_image_limit` | 20 | Recipe pictures per UTC day (Premium only) |
| `daily_user_limit` | 200 (unchanged) | Operator ceiling per account; the plan's `provider_calls_daily` (11 for Free) is lower |

`20261026100000` sets the pool to 150 and replaces only the ceilings
`20261025100000` left (3000 calls, 200 pictures) with 400 and 20; any other
live value, and an operator's later change, stays on a second run. Worst case before the launch:
about 16 USD a day from Free and at most about 43.5 USD from all calls,
pictures included. Keep `daily_free_call_limit` below `daily_call_limit`;
the readiness check reports `free_limit_not_below_total` otherwise.

Sizing at the launch, from a few weeks of ops-watch numbers:

- `daily_free_call_limit`: about Free daily active accounts × 5 calls × 1.5.
- `daily_call_limit`: the Free pool plus a Premium reserve of at least 150 ×
  the heavy Premium accounts.
- `daily_image_limit`: about 50 to 100.
- Raise the Anthropic spend limit to match ([below](#provider-spend-limits)):
  at least 30 × `daily_free_call_limit` × about 0.105 USD plus the expected
  Premium spend, so a Free pool used up every day for a month cannot reach
  it. Otherwise lower `daily_free_call_limit` to about (limit − Premium
  spend) / (30 × 0.105 USD).

```sql
update public.ai_provider_limits
  set daily_free_call_limit = <pool>, daily_call_limit = <total>, daily_image_limit = <pictures>
  where singleton;
select daily_free_call_limit, daily_call_limit, daily_image_limit, daily_user_limit
  from public.ai_provider_limits;
```

Two switches stop Free AI and keep Premium working:

1. `update public.ai_provider_limits set daily_free_call_limit = 0 where singleton;`
   denies every Free call with `scope: "free"`; a current app shows the calm
   "at capacity" notice with the next 00:00 UTC as the return time. Use it
   only for a stop that ends by then.
2. `update public.plan_tiers set provider_calls_daily = 0, updated_at = now() where tier = 'free';`
   denies through the per-account cap (`scope: "account"`, the generic
   message without a time). Use it, or a general stop switch, for a stop of
   unknown length. It does not reach a legacy account, which reads the
   `legacy` row.

With either, a meal analysis or recipe import denied at its first
reservation gets its day slot back. Undo a switch by setting the earlier
value again. Neither cancels a call in flight; the general stop switches are
in the [incident response](#incident-response-containment-and-rollback).

### Provider spend limits

The reservation limits count requests, not money. The only bounds in
dollars are in the provider consoles. Owner steps (the console labels are
not verified):

1. **Anthropic Console:** on the workspace that holds the production
   `ANTHROPIC_API_KEY`, a monthly spend limit of about 50 USD before the
   launch, with an alert at about 20 USD. Raise it with the pools at the
   launch.
2. **OpenRouter:** a credit limit of about 10 USD on the picture key
   (`OPENROUTER_API_KEY`).

Once the Anthropic limit is reached, the provider refuses further calls for
every tier until the limit resets or is raised. A Free farm that uses the
whole pool every day (about 7 to 16 USD a day) reaches a 50 USD limit in
about 3 to 7 days and then stops Premium too; the 20 USD alert, or
`free_calls_warning` on several days in a row, is the signal to lower
`daily_free_call_limit` or set it to 0 first. Record the date and the
values in the handoff, never a key. The readiness check cannot see these
settings and keeps reporting `monetary_limit_verified: false`.

### Ending the legacy window

**Ended live on 2026-10-25 at 08:30:35 UTC**, with the owner's consent and
without the notice: all 7 accounts were the owner's test accounts and the
app is not public, so no announced terms applied. One statement set
`legacy_until = now()` on the settings row while it was still null. Since
then no account is legacy, every account without Premium gets the `free`
row, and no app shows the notice (it needs a legacy account). The procedure
below is kept as built.

Accounts created before the migration keep the `legacy` limits while
`plan_settings.legacy_until` is null. Set it only after the new terms are
published, to the date on which they take effect for existing accounts, at
least four weeks after the notice reaches them (AGB section 11):

```sql
update public.plan_settings
  set legacy_until = '<effective date, e.g. 2026-12-15T00:00:00Z>', updated_at = now()
  where singleton;
```

Setting it makes the app show legacy accounts a one-time notice on Today
with that date (an app build with the notice is needed). A Free account sees
the new Free limits there, and its Premium screen and Profile name the date
as well. An account with Premium sees the regular Premium limits instead, on
Today and in a lasting note on its Profile; its Premium screen shows no
date. From that instant they are Free, or Premium if they bought it. The
notice and the notes reach only people who open an updated app, and
subscribers never see the date on the Premium screen; whether an email must
accompany them is a legal question
([legal draft](PREMIUM-LEGAL-DRAFT.md)). Do not move an announced date
earlier; a later date shows the notice again. Never change
`legacy_created_before`.

### Alerts and checks

- **Global caps.** Until the launch the shared ceilings are 400 provider
  calls and 20 recipe pictures per day, with 150 calls for Free
  (`20261026100000`; the Premium migration had raised them to 3,000 and
  200). The [ops watch](#ops-watch) warns at 60 % of each (240 calls, 12
  pictures, 90 Free calls), so a farm or a few heavy accounts cannot
  exhaust the day unseen.
- **Plan lookup.** A failed `resolve_plan` writes `resolve_plan unavailable`
  and serves the Free limits, also to Premium accounts; a request those
  limits would deny answers `503 plan_unavailable` (the app shows a
  retryable error, no limit notice and no upgrade offer). In the Logs Explorer
  (not run live): `select timestamp_trunc(timestamp, hour) as hour, count(*) as lookups_failed from function_logs where regexp_contains(event_message, r'resolve_plan unavailable') group by hour order by hour desc`.
- **Cost triggers** from the contract, read from the `ai_call` lines two to
  four weeks after launch: above about 2,20 EUR AI cost per subscriber and
  month, move the picture to a cheaper size or model first; if a typical
  Free account costs more than 0,75 EUR a month, lower Free analyses by one.

### Deploy modes of the new functions

| Function | `verify_jwt` | Boot probe | Rollback floor |
| --- | --- | --- | --- |
| `subscription-verify` | on (gateway checks the user JWT) | gateway 401 without a token, handler 401 with the anon key | `fdd8d63f`, `first_release` |
| `store-notifications` | off, only through `supabase/config.toml` and the webhook allowlist | handler `invalid_notification_auth` 401 without a token and with the anon key | `fdd8d63f`, `first_release` |

To stop Google Play processing in an incident, remove
`EATOVA_PLAY_SERVICE_ACCOUNT_JSON`: Google verification, a `refresh` with
rows to re-check and Google notifications answer 503, the app keeps the
purchase uncompleted and retries, and Pub/Sub retries. Removing only the
Pub/Sub pair (`EATOVA_PUBSUB_PUSH_AUDIENCE`, `EATOVA_PUBSUB_PUSH_SA_EMAIL`)
stops just the notifications. Mind Google's three-day acknowledgement
window.

There is no server switch for the App Store: Apple proofs and notifications
are verified offline against the pinned root and read none of these
secrets. To pause Apple notifications, remove the App Store Server
Notifications URLs in App Store Connect; Apple does not resend them later
unless they are requested through the App Store Server API (which this
repository does not call), so a missed event reaches the account only at
its next verify. Stopping Apple verification means deleting
`subscription-verify` in the dashboard, which stops Google verification
too: the app treats the missing function as unavailable, keeps purchases
uncompleted and retries, and the [ops watch](#ops-watch) fails until the
deploy workflow brings it back. A rollback cannot remove it: the deploy
workflow only deploys and never deletes a function, and a target without
`subscription-verify` refuses that slug as `unknown_function` (with `all`
it simply leaves the live function in place).

Existing grants keep working in every case, since `resolve_plan` reads only
the database.

## Client release and rollback gate

Before signing or uploading any client candidate, run **Client release
eligibility** in GitHub Actions from the protected `main` branch with its full
40-character merged commit SHA. The workflow runs the current trusted validator,
not code supplied by the candidate. Keep the successful run URL and
`storage-release-eligibility` artifact with the candidate's signed artifact
checksum and the applicable successful build/test CI run. Confirm its
`candidate_commit` and `candidate_tree` match the source being signed. A failed
or missing eligibility result forbids using that candidate in the supported
production release/rollback process.

For a local equivalent, use a clean, freshly fetched protected-main checkout:

```bash
python scripts/check_storage_release.py --candidate <full-merged-commit-sha> --output storage-release-eligibility.json
```

Storage protocol 2 is forward-only. SharedPreferences-era builds and the first
SQLite build without the recovery guard are not eligible rollback targets,
even if their old CI was green. Port the corrective change onto a compatible
SQLite build, review/test it and obtain fresh eligibility. The supported process
does not allow reinstalling an obsolete binary over a migrated installation.
The Android [release lane](DEVELOPMENT.md#release-lane) runs this check for
the commit it builds and keeps the result with the signed bundle; the gate
still attests eligibility only and cannot physically prevent manual uploads,
bypasses or sideloads. See the [data preservation and recovery contract](OFFLINE_SYNC.md#client-rollback-contract).

Review this runbook after an incident or major platform change. A documented
procedure must still be exercised; do not mark operational readiness complete
on the strength of code tests alone.
