# Contributing to Eatova

Thanks for your interest in improving Eatova! This document describes how to
set up the project, the conventions we follow, and how to get a change merged.

> The Dart package is named `eatova`, matching the app name **Eatova**
> (formerly ShiftFit/FitPilot). Don't rename the package again without a very
> good reason — it would break every import and test.

## Getting set up

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install).
   CI pins **Flutter 3.47.2 stable** (`.github/workflows/security.yml`), which
   ships Dart 3.13.2 — use the same version locally so `pubspec.lock` and the
   analyzer agree with CI. (The `^3.11.5` SDK constraint in `pubspec.yaml`
   is the deliberate lower bound, not the recommended version.)
2. Fork and clone the repository.
3. Install dependencies:

   ```bash
   flutter pub get
   ```

4. Point independent development at your own Supabase project via a git-ignored
   `dart_defines.json` — see the [README](README.md#point-at-your-own-supabase-project).

## Before you open a pull request

For documentation-only changes, validate the changed Markdown links/anchors,
source paths, configuration names and commands against current code/workflows;
run `git diff --check` and a secret scan. Do not rerun app suites locally solely
for prose edits. The protected PR workflow still runs its required CI checks.
Keep historical records dated and link them to the [current guides](docs/README.md).

For code changes, run the applicable checks CI runs (`.github/workflows/security.yml`), with the
same flags — a plain `flutter analyze` / `flutter test` can be green locally
while CI is red:

```bash
# 1. Analyzer: infos and warnings are fatal in CI, not only errors.
flutter analyze --fatal-infos --fatal-warnings

# 2. Tests: CI passes dummy defines so the suite compiles without a real
#    Supabase project and never opens a socket.
flutter test --coverage \
  --dart-define=SUPABASE_URL=https://ci.invalid \
  --dart-define=SUPABASE_ANON_KEY=ci-dummy-key

# 3. Edge Functions (Deno 2): lint, type-check every entry point, unit tests.
#    --allow-env only — the handlers read secrets at module load; fetch is
#    stubbed, so no --allow-net.
deno lint supabase/functions \
  && deno check supabase/functions/*/index.ts \
  && deno test --allow-env supabase/functions

# Offline evaluation harness; no API key or network permission.
deno lint supabase/eval
deno test --allow-env supabase/eval/coach_eval_test.ts
```

Step 3 is required whenever you touch `supabase/functions/`; it is cheap
enough to run every time. CI additionally builds a debug APK and a release
AAB (R8 + AOT, throwaway keystore), scans secrets across the full history
(gitleaks) and dependencies (OSV), and replays all migrations against PostgreSQL
to test real cross-user access and account-deletion reauthentication.

The line-coverage floor is **88%**, excluding `lib/src/l10n/generated/`.
The Deno job also executes each discovered test file independently to catch
module-state/test-discovery gaps. Follow the workflow's disposable PostgreSQL
setup for database checks; never run the RLS suite against the live service.
Database changes also run the provider-budget SQL/race checks and
`python test/operations/backup_restore.py --prove-detection` against new,
synthetic containers. See [operations](docs/OPERATIONS.md).

The Android job resolves and strictly scans actual runtime/desugar dependencies;
the dependency job also inventories pinned Swift revisions. Gradle build-tool
advisories are a separate visible report with [dated reachability triage](android/BUILD_TOOL_SECURITY.md).
Scanner/inventory errors fail the job; an advisory report is not proof that the
toolchain is free from vulnerabilities. The Gradle resolver regression fixtures
require the normal Flutter-generated wrapper/bootstrap before execution.
OSV uses the SHA-256-verified 2.3.8 CLI with `--no-ignore` so generated inventories
inside ignored build directories are included. This controls file discovery,
not advisory suppression. The scanner smoke tests use a real disposable Git
checkout and verify clean, vulnerable, empty and malformed inventory outcomes.

Live migration drift runs on `main`, including the weekly scheduled run, in the
`supabase-drift` GitHub environment. Its deployment branch policy must allow only
the `main` branch. Keep `SUPABASE_ACCESS_TOKEN` and `SUPABASE_PROJECT_REF` there,
never as repository secrets: PR authors can edit workflow `if` conditions. The
stable required PR check documents this split; it does not query production.

If you touch `lib/l10n/*.arb`, run `flutter gen-l10n` afterwards; the
generated code under `lib/src/l10n/generated/` is git-ignored and rebuilt in
CI, but `test/l10n/` guards ARB parity and hard-coded text.

## Coding conventions

- **Layering** (see [README → Project structure](README.md#project-structure)):
  - New screens → `lib/src/screens/`
  - Reusable UI → `lib/src/widgets/` (grouped by feature)
  - Pure data models → `lib/src/models/`
  - External API / sync logic → `lib/src/services/` — **never** call APIs
    directly from widgets
  - Colors and theme → `lib/src/theme/` only
  - Keep `lib/main.dart` small
- **Add-flows**: prefer slot/entity tap → bottom sheet over inline forms or
  global floating action buttons.
- **Test pins**: `Key` values and label strings in the widget tests (end-to-end
  flows in `test/flows/`, plus the suites in `test/` and `test/widgets/`) are
  load-bearing. If you change UI that a test targets, update the test in the
  same commit.
- **Lints**: the project uses `flutter_lints`. Keep `flutter analyze` clean.
- **Design**: reuse tokens, soft-fill input/focus styles and shared components.
  `AppIcon`/`AppSymbol` provide the custom family; meal slots use
  `MealSlotStyle.symbol`. See the [current design contracts](docs/README.md#design-contracts-and-previews).
- **Persistence**: preserve account namespaces, cache encryption, durable outbox
  acknowledgments and explicit adoption of Coach proposals.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): short imperative subject

Optional body explaining the why.
```

Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`,
`build`, `ci`. Keep the subject ≤72 characters and in the imperative mood.

## Pull requests

1. Create a topic branch off `main`.
2. Keep the PR focused on a single concern.
3. Complete the applicable local checks above and wait for the required PR CI.
4. Describe **what** changed and **why** in the PR description.
5. Update documentation when behavior or structure changes.
6. Merge through the protected-main workflow. A merge does not deploy backend
   changes, publish a store build or install an app on a device.

## Reporting bugs and requesting features

Open a GitHub issue with clear reproduction steps (for bugs) or a concise
description of the use case (for features). For security issues, **do not** open
a public issue — follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE) that covers this project.
