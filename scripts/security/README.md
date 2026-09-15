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

The script uses the real GoTrue **2.196.0** image (the version in the official
[Supabase Compose](https://github.com/supabase/supabase/blob/master/docker/docker-compose.yml)
checked on 2026-09-15) and PostgreSQL **17.6**. Both versions are explicit test
targets with the tested registry digests pinned in the script; this does not
establish the deployed Auth server version.

It creates a separate Docker network and two disposable containers named
`eatova-r3-authority-db` / `eatova-r3-authority-auth`. Postgres uses tmpfs and has
no published port. Auth is available only on `127.0.0.1:54991`. Existing resources
with those names cause startup to fail; they are not replaced. Created resources
are removed in `finally`. A forcibly killed interpreter can leave them behind;
inspect the exact names before manually removing any leftover test resources.

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
- Fresh-session password changes retain GoTrue's existing nonce exception.
  A session backdated to 25 hours requires reauthentication. This documents the
  policy; it does not impose a new current-password requirement on app users.
- One email-change code leaves the old address and creates no session; replay
  fails. Both codes preserve the user ID while switching the login address.
- Direct repeated invalid `/verify` requests reach 429. The fixture explicitly
  configures the trusted gateway header and a synthetic fixed client IP. This
  does **not** prove hosted gateway header stripping, distributed rate limits,
  CAPTCHA behavior or email-quota resilience.

Only OTP expiry and old-session age use backdated rows in the disposable database;
the refresh tests wait for the real server's grace intervals. Tokens, passwords,
mail addresses and response bodies stay in memory. Google/browser callbacks,
real identity linking, security-mail delivery, app/device behavior, administrator
MFA, HIBP entitlement and actual production Auth version remain separate checks.

The expected semantics follow the pinned upstream [authentication middleware](https://github.com/supabase/auth/blob/v2.196.0/internal/api/auth.go),
[refresh service](https://github.com/supabase/auth/blob/v2.196.0/internal/tokens/service.go),
[token-family revocation](https://github.com/supabase/auth/blob/v2.196.0/internal/models/refresh_token.go),
[OTP verification](https://github.com/supabase/auth/blob/v2.196.0/internal/api/verify.go)
and [no-op mail selection](https://github.com/supabase/auth/blob/v2.196.0/internal/mailer/templatemailer/template.go),
inspected on 2026-09-15. A still-valid JWT signature is not evidence that a
revoked token remains accepted by this version's `/user` endpoint. Conversely,
these `/user` checks do not establish immediate revocation at a different service
that validates only JWT signatures, such as a separately configured REST gateway.
