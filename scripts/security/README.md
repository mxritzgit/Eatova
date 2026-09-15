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
targets; this does not establish the deployed Auth server version.

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
