# Isolated Edge authentication probe

Run from the repository root with Docker Desktop, Deno 2 and Python 3.11+:

```powershell
python scripts/security/local_edge_auth_probe.py
```

After integrating the global AI budget, require its boundary explicitly:

```powershell
python scripts/security/local_edge_auth_probe.py --require-provider-budgets
```

This mode checks a separate `reserve_ai_provider_call` request, bound to the
verified user and correct operation, before **each** stubbed classifier, coach
answer and meal-analysis call. The RPC remains a local stub and never changes a
deployed budget. Its required-mode flag and reservation counts appear in the
report, so an older baseline run cannot be confused with a budget enforcement
check. Recipe/plan/image budget paths have separate handler/SQL regression tests.

The script uses the real GoTrue **2.197.0** image, matching the hosted health
endpoint version observed read-only on 2026-09-20, and PostgreSQL **17.6**. Both
versions are explicit test targets with registry digests pinned in the script.
Local results establish that pinned implementation and configuration, not live
password behavior; future hosted version changes need a fresh comparison.

It creates a separate Docker network and two disposable containers named
`eatova-r3-authority-db` / `eatova-r3-authority-auth`. Postgres uses tmpfs and has
no published port. Auth is available only on `127.0.0.1:54991`. Existing resources
with those names cause startup to fail; they are not replaced. Created resources
are removed in `finally`. A forcibly killed interpreter can leave them behind;
inspect the exact names before manually removing any leftover test resources.
Readiness waits for PostgreSQL's final TCP server, not its temporary socket-only
initialization server. Auth HTTP requests reject non-loopback origins, ignore
system proxy configuration and never follow redirects. The local transport
regressions run with `python test/tooling/local_auth_transport_test.py`, require
Deno 2, and use only temporary loopback HTTP servers. The Deno subprocess also
removes inherited HTTP/HTTPS/ALL/NO proxy variables case-insensitively: its
`--allow-net` permission checks the target, but did not prevent proxy forwarding
in the installed Deno 2.8.1 runtime. Required non-proxy configuration is retained.

All credentials and A/B accounts are generated for that disposable service.
Email confirmation is automatic, synthetic addresses use `example.test`, and no
mail/AI/payment service is configured. Auth calls use real signature verification;
all application REST, quota and AI requests are intercepted. Network permissions
for the Deno process permit only that loopback address. No tokens or user payloads
are written to the report. The network has normal Docker routing because Docker
Desktop's internal networks did not expose the loopback port reliably; the probe
does not send external Auth/provider requests.

The report at `.agents/edge-auth-probe/result.json` records statuses and counts:

- Valid A and B can execute their intended paths. A's supplied B session is
  checked with A's owner filter; the existing fallback uses A's default session.
- Missing/public-anon, malformed, expired, future-`nbf`, wrong-signature,
  `alg:none`, nonexistent-user and wrong-audience requests return 401 before
  protected data/provider effects. Auth failure rate counters are separate.
- Request-body identity, role, premium and model claims cannot change the
  verified actor or choose provider/system instructions.
- A differently named issuer signed with the **same local project key** remains
  accepted by the tested GoTrue version. No unrelated signing key is accepted.
  The app binds subject/audience after `/user` verification; hard issuer binding
  needs evidence for the hosted project's current and legacy issuer formats.

The fixture factory in `supabase/functions/_shared/auth_test_fixtures.ts` has an
intentionally invalid signature and is used only with stubbed Auth in unit tests.
Those unit tests do not establish cryptographic verification. The manual probe
uses genuinely signed tokens from its local service and records its image digest.

## Real Auth lifecycle and detection proof

```powershell
python scripts/security/local_edge_auth_probe.py --auth-lifecycle --prove-detection --require-provider-budgets
```

This additional mode uses separate `eatova-r4-auth-lifecycle-db` /
`eatova-r4-auth-lifecycle-auth` containers, their own network and loopback port
**54992**. Its sanitized report is `.agents/auth-lifecycle-probe/result.json`.
The original mode and port remain available. Both modes fail rather than
replacing existing containers, and remove only resources they created.

The local configuration explicitly requires email confirmation, eight-character
passwords, eight-digit OTPs valid for 600 seconds, both email-change codes,
password reauthentication for old sessions, refresh rotation and a ten-second
reuse interval. SMTP is absent: GoTrue uses its built-in no-op mail client.
Admin-generated codes replace mailbox delivery **inside this disposable test**.
Neither actual email delivery nor the hosted configuration is established.

The probe verifies these real server boundaries:

- Refresh produces a different token. Retrying the immediate parent recovers
  the active token; reusing an older ancestor outside the interval is rejected.
  The active family is then rejected after its own grace interval. Disabling
  rotation in a second local run must make this last assertion fail. This is
  recorded as `rotation_disabled_mutation_detected`, not a production change.
- Local logout revokes its session while preserving a parallel session. Global
  logout revokes the account's remaining session, preserving another account.
  Ban and deletion deny password/refresh or user-endpoint access as applicable.
  All three Edge handlers also reject logged-out, banned and deleted tokens
  before protected data, quota or provider effects.
- Unconfirmed signup has no session and cannot log in; short passwords fail.
  Correct codes confirm the intended account; wrong/replayed codes fail.
  Duplicate confirmed signup returns no session and empty identities, so its
  response is **still distinguishable** from a fresh signup.
- Existing/missing recovery requests return the same successful status. Recovery
  codes are account-bound, single-use and expire. A recovered user can replace
  the password; the old password and previous refresh session then fail.
- The default local configuration requires the current password for ordinary
  password sessions, including fresh ones. The independent fresh-session nonce
  exception remains; a session backdated to 25 hours also needs reauthentication.
  `--legacy-password-policy` instead tests the former disabled-current-password
  configuration. Neither local mode changes or establishes live configuration.
- One email-change code leaves the old address and creates no session; replay
  fails. Both codes preserve the user ID while switching the login address.
- Direct repeated invalid `/verify` requests reach 429. The fixture explicitly
  configures the trusted gateway header and a synthetic fixed client IP. This
  does **not** prove hosted gateway header stripping, distributed rate limits,
  CAPTCHA behavior or email-quota resilience.

Only OTP expiry and old-session age use backdated rows in the disposable database;
the refresh tests poll read-only database timestamps until the real server's
grace interval has elapsed, with a bounded monotonic deadline. Host sleep alone
does not establish elapsed time inside a Docker VM. Each HTTP denial is still
attempted once; a successful refresh is never retried until an assertion passes.
Tokens, passwords,
mail addresses and response bodies stay in memory. Google/browser callbacks,
real identity linking, security-mail delivery, app/device behavior, administrator
MFA, HIBP entitlement and actual production Auth version remain separate checks.

The expected semantics follow the pinned upstream [authentication middleware](https://github.com/supabase/auth/blob/v2.197.0/internal/api/auth.go),
[refresh service](https://github.com/supabase/auth/blob/v2.197.0/internal/tokens/service.go),
[token-family revocation](https://github.com/supabase/auth/blob/v2.197.0/internal/models/refresh_token.go),
[OTP verification](https://github.com/supabase/auth/blob/v2.197.0/internal/api/verify.go)
and [no-op mail selection](https://github.com/supabase/auth/blob/v2.197.0/internal/mailer/templatemailer/template.go),
inspected on 2026-09-20. A still-valid JWT signature is not evidence that a
revoked token remains accepted by this version's `/user` endpoint. Conversely,
these `/user` checks do not establish immediate revocation at a different service
that validates only JWT signatures, such as a separately configured REST gateway.

## Real recovery mail purpose, OTP and password-change contract

Run `python scripts/security/local_email_template_probe.py --prove-detection`
with Docker available. Pinned GoTrue 2.197.0, Postgres 17.6 and a small Python SMTP
sink run on a disposable internal Docker network with no published ports. The
sink stores synthetic messages only in RAM and has no relay implementation.
Request bodies travel through stdin; tokens and rendered messages are never
written to evidence or logs. All containers and their network are removed on exit.

The probe submits account deletion, password reset, legacy/no-context, unknown
context and deletion-again requests for the same synthetic user. It verifies
request-specific headings, a neutral subject, one eight-digit OTP, absence of
authentication links, and actual verification of each OTP with the same user ID.
The final repeated request catches purpose state leaking across calls. The
negative control changes only a temporary copy of the deletion branch and must
fail the actual SMTP heading assertion. Sanitized results are in the ignored
`.agents/email-template-probe/result.json`.

The same stack tests direct `PUT /user` requests with native current-password
enforcement enabled. Young ordinary sessions reject missing or wrong current
passwords, even with a valid mailbox nonce. The correct current password succeeds
without an additional nonce for young sessions. A 25-hour-old session requires
both proofs; missing, invalid, expired, foreign-account and replayed nonces fail.
GoTrue consumes a valid old-session nonce **before** checking the current
password: retrying a missing/wrong-current-password failure with that same nonce
must fail. Real password logins confirm every accepted update and establish that
denied updates preserve the old password. Three negative controls separately
remove purpose routing, disable reauthentication, and disable current-password
enforcement; each must fail its corresponding real HTTP/SMTP assertion.
This credential matrix sets higher local token/user request refill rates so its
many deliberate login attempts test password effects rather than exhaust the
shared IP bucket. Limits are not changed live; the separate lifecycle probe
retains its real IP rate-limit assertion.

The suite deliberately also proves the native exceptions. A real email-recovery
OTP creates a session that can change its password repeatedly without another
proof, including after token refresh. A verified signup-OTP session has the same
exception. A locally simulated OAuth session with no existing password can set
its first password without an additional proof. That fixture clears the synthetic
password hash, changes its stored AMR to OAuth, then obtains a real refreshed
GoTrue token; it does not contact an identity provider or prove external OAuth
login/identity linking. Once a password exists, ordinary OAuth sessions also
require it. The SMTP matrix also verifies that a dual-email-change OTP
session has this exception. These checks must not be described as universal
fresh-mail protection. Local logout of the recovery/signup/email-change OTP
session rejects subsequent password updates and refresh, preserving a separately
established normal session. The lifecycle probe additionally preserves the
original initiating password session across dual-email verification and local
OTP logout, including its authenticated user read and refresh. This does not
establish immediate JWT revocation
at stateless services such as PostgREST.
Account deletion's independent fresh OTP guard remains covered by the
database/RLS and scoped-deletion suites.

Run `python scripts/security/local_email_template_probe.py --legacy-policy` to
check the former deployed policy while preparing or assessing a rollout. It
expects recent-session and existing-password OAuth changes without the current
password to succeed; the old-session nonce boundary remains required. This
explicit baseline is also in CI, and writes separate sanitized evidence to
`.agents/email-template-probe-legacy/result.json`. The default local policy is a
target contract, not a live deployment claim. The separate read-only
`auth_password_policy.py` audit checks actual server flags; source policy and
delivery evidence remain in [Auth configuration](../../supabase/AUTH_EMAIL_OTP.md).

This proves rendering and OTP behavior for the committed recovery template on
the pinned local Auth server. It does not prove live template deployment, real
mail delivery, or rendering in every mail client. Template fields are documented
in [Supabase Email Templates](https://supabase.com/docs/guides/auth/auth-email-templates);
the request-specific context uses
[redirectTo](https://supabase.com/docs/guides/auth/redirect-urls).
