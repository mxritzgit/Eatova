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

Review this runbook after an incident or major platform change. A documented
procedure must still be exercised; do not mark operational readiness complete
on the strength of code tests alone.
