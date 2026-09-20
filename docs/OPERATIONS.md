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
[`auth_password_policy.py`](../scripts/security/auth_password_policy.py) audit:
current-password enforcement, reauthentication and password-change notifications
must all be enabled. Missing controls, invalid types and read failures fail the
audit without printing configuration bodies or credentials. PR jobs run only its
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
| AI budget | 80% of approved daily reservation limit; separate alert at exhaustion | Check usage trend, reserve policy and stop switches |
| Backups | Latest completed recovery point older than the agreed RPO or a failed scheduled backup | Repair backup path and verify a new usable recovery point |
| Privileged changes | Owner/membership/token changes or security protection disabled | Verify the authorized change and actor through restricted admin audit access |
| Monitoring failure | Missing expected heartbeat or disabled rule | Restore collection/routing before relying on silence |

For every actual rule record its provider/project, rule identifier, owner,
threshold/window, destination, repeat suppression, retention and last successful
test time. Test evaluation with synthetic data in a notification-suppressed
destination before any authorized routing test. Do not send unsolicited test
alerts to real recipients. A configured rule without delivery evidence remains
unverified. Recheck access, rules and restore evidence after material changes.

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
current UTC day's global call/image counters. The sole POST uses Supabase's
[read-only SQL endpoint](https://supabase.com/docs/reference/api/v1-read-only-query)
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

The initial usage warning is 80%; change it explicitly with
`--budget-warning-percent` after agreeing the threshold. The required backup
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

No schedule, notification route or paid resource is installed by this tool.
Run it from a trusted operator host or protected deployment environment; never
expose the token to PR code. Add a heartbeat/dead-man check and approved routing
for exit `1`, exit `2`, and missed runs. Test those routes separately with
synthetic results before a specifically authorized delivery test. If staging
is omitted it is explicitly unchecked. Two distinct verified project identities
alone do not prove separate credentials, data, billing or deployment isolation.
The checker does not establish an OpenRouter money limit, external backups,
Storage-file coverage, provider retention, Sentry rules or end-to-end recovery.

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
| OpenRouter and selected model providers | Identify the actual runtime key's owning account and routing/settings. Determine which provider records exist and use its supported access/deletion route. Do not claim zero retention from a different key's settings. | Account/configuration evidence and provider confirmation or explicit retention limit |
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
OpenRouter account/key and money budget; read access to Sentry/provider settings;
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
   Confirm the expected row exists and verify the setting afterwards. These
   switches do not cancel in-flight provider work or reverse existing charges.
   Do not delete user history or reset counters to recover service.
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
There is no automated app-store publication pipeline in this repository; this
gate attests eligibility and cannot physically prevent manual uploads, bypasses
or sideloads. See the [data preservation and recovery contract](OFFLINE_SYNC.md#client-rollback-contract).

Review this runbook after an incident or major platform change. A documented
procedure must still be exercised; do not mark operational readiness complete
on the strength of code tests alone.
