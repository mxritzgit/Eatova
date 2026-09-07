# Eatova agent entry point

## Start here

- Read `docs/PROJECT_HANDOFF.md` for the dated handoff, review history, open work,
  and pointers to Claude's existing project memories.
- Check `git status --short --branch` and the current diff before editing. The
  handoff's branch and CI status are snapshots, not permanent facts.
- Use the existing `README.md`, `CONTRIBUTING.md`, `docs/`, and source code as
  shared documentation. Reuse Claude's notes; do not create a second full archive.
- Later verified fixes supersede old review findings. Read the follow-up and
  confirm the relevant commit before treating a historical finding as open.
- Distinguish code committed, PR merged, backend deployed, and device build
  installed. One does not establish the others.

## Project conventions

- Flutter Android/iOS app with Supabase; preserve the existing architecture and
  theme tokens. Screens, store, services, and models have separate roles.
- Inputs use borderless soft fills and subtle focus fill changes, following the
  user's existing preference. Preserve accessible focus indication.
- Keep code comments concise and English; existing German test names are valid.
- Avoid unrelated formatting of existing files and incidental lockfile churn.
- Use `lib/l10n/*.arb` for localized UI and regenerate with `flutter gen-l10n`.
- Coach recipe proposals do not write user data until explicit confirmation;
  generated recipe images stay on device. Preserve account isolation, encrypted
  cache behavior, outbox durability, quota rules, and sanitized diagnostics.
- Never print or commit credentials or local runtime configuration. Tests use
  dummy defines and stub external requests.

## Verification and delivery

- Match the Flutter version pinned in `.github/workflows/` (3.47.2 at handoff).
  Local Windows SDK: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat`.
  Check the installed version before dependency or lockfile changes.
- Follow `CONTRIBUTING.md` and the actual CI workflows. Analyzer warnings and
  infos are fatal. Coverage floor is 88%; RLS is also tested against Postgres.
- Add meaningful regression tests for behavioral fixes. For critical guarantees,
  demonstrate that the test detects the faulty behavior. Freeze date/time when
  testing date-dependent behavior. Do not mutate a shared working tree during
  concurrent tests; use isolation if a future task explicitly calls for it.
- Use topic branches and PRs; preserve the protected-main workflow. Run checks
  appropriate to the change and report failures and unverified live state plainly.
- Update the shared handoff when a major review, decision, or open item changes;
  link to evidence instead of copying transcripts or sensitive local notes.
