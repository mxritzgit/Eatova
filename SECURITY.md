# Security Policy

## Supported versions

Eatova is an actively developed, in-production application. Security fixes
are applied to the latest state of the `main` branch.

| Version            | Supported |
| ------------------ | --------- |
| `main` (latest)    | ✅        |
| Older revisions    | ❌        |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, report them privately:

- **Email:** moritz.gietl@gmail.com
- Alternatively, use GitHub's
  [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  for this repository.

Please include:

- A description of the vulnerability and its potential impact
- Steps to reproduce (proof of concept if possible)
- Affected files, endpoints, or components

We aim to acknowledge reports within a few days and will keep you updated on
remediation progress. Please give us a reasonable window to release a fix
before any public disclosure.

## Scope and design notes

- **Supabase anon key:** the client ships a public Supabase anon key
  (a JWT with `role: anon`). This is by design — it is meant to be embedded in
  the client and is not a secret. All data access is enforced server-side by
  **Row Level Security (RLS)** policies, defined in `supabase/migrations/`.
- **Provider API keys** (AI vision, AI coach, etc.) are **never** committed to
  the repository. They are configured as Supabase Edge Function secrets and are
  only ever used server-side.
- **Reportable issues** include, for example: RLS policy gaps that expose data
  across users, authentication or authorization bypasses, injection flaws, and
  leakage of any genuine secret.

Thank you for helping keep Eatova and its users safe.
