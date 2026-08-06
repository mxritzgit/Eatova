# Contributing to Eatova

Thanks for your interest in improving Eatova! This document describes how to
set up the project, the conventions we follow, and how to get a change merged.

> The Dart package is named `eatova`, matching the app name **Eatova**
> (formerly ShiftFit/FitPilot). Don't rename the package again without a very
> good reason — it would break every import and test.

## Getting set up

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install)
   (Dart `^3.11.5`).
2. Fork and clone the repository.
3. Install dependencies:

   ```bash
   flutter pub get
   ```

4. (Optional) Point the app at your own Supabase project via a git-ignored
   `dart_defines.json` — see the [README](README.md#point-at-your-own-supabase-project).

## Before you open a pull request

Run the same checks CI runs, and make sure they pass:

```bash
flutter analyze   # must be clean — zero issues
flutter test      # all tests green
```

If you touch the Edge Functions in `supabase/functions/`, also run:

```bash
deno lint
deno check supabase/functions/**/*.ts
```

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
3. Ensure `flutter analyze` and `flutter test` pass locally.
4. Describe **what** changed and **why** in the PR description.
5. Update documentation when behavior or structure changes.

## Reporting bugs and requesting features

Open a GitHub issue with clear reproduction steps (for bugs) or a concise
description of the use case (for features). For security issues, **do not** open
a public issue — follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE) that covers this project.
