# FitPilot

> A polished Flutter app for fitness, recovery, and nutrition — short, evidence-based plans instead of an overloaded tracker.

[![Status](https://img.shields.io/badge/status-in%20production-success)](#project-status)
[![Platform](https://img.shields.io/badge/platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Backend](https://img.shields.io/badge/backend-Supabase-3ECF8E?logo=supabase&logoColor=white)](https://supabase.com)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

FitPilot helps you steer training, regeneration, and nutrition in everyday life:
a clear "Today" check-in, a weekly training split, a readiness/trends view, and
fast food logging via AI photo analysis or barcode scan — backed by an AI coach.

> **Note on the name:** the app is **FitPilot**. The Dart package and Git
> repository are still named `shiftfit` for historical reasons; renaming the
> package would break every import and test pin, so the internal name stays.

---

## Project status

FitPilot is **in production**. This repository is open-sourced under the MIT
license so the implementation can be studied, reused, and improved. It is a
real application, not a demo — treat the `main` branch as shippable.

---

## Features

- **Today dashboard** — daily check-in (training goal, energy, load), plus
  mood, habits, caffeine half-life, weight, a day-overview ring, smart
  reminders, and a tip of the day. Quick logging happens via stat-tap bottom
  sheets.
- **Week planner** — build and persist a weekly training split.
- **Trends / Readiness** — readiness over time, computed from real logged
  history.
- **Food tracking** — calorie and macro tracking with:
  - **AI photo analysis** — snap a meal, get an estimated nutrition breakdown.
  - **Barcode scanning** — product nutrition from Open Food Facts.
  - **Product search** — text search directly against Open Food Facts.
- **Recipes** — browse and manage recipes.
- **AI Coach** — an in-app chat coach for training and nutrition questions,
  with a daily quota and layered safety filtering.
- **Health integration** — reads daily steps from Apple HealthKit on iOS and
  estimates calories burned.

---

## Tech stack

| Layer            | Technology                                                        |
| ---------------- | ----------------------------------------------------------------- |
| App              | [Flutter](https://flutter.dev) / Dart (SDK `^3.11.5`)             |
| Backend          | [Supabase](https://supabase.com) — Auth, Postgres + RLS           |
| Serverless       | Supabase Edge Functions (Deno / TypeScript)                       |
| Nutrition data   | [Open Food Facts](https://world.openfoodfacts.org)               |
| AI meal analysis | Vision LLM via [OpenRouter](https://openrouter.ai)                |
| AI coach         | LLM chat backend                                                  |
| Health           | Apple HealthKit (`package:health`)                                |

Key Flutter packages: `supabase_flutter`, `image_picker`, `mobile_scanner`,
`health`, `url_launcher`.

---

## Architecture

```text
┌─────────────────────────────┐        ┌──────────────────────────────────┐
│         Flutter app         │        │             Supabase             │
│           (lib/src)         │  HTTPS │                                  │
│                             │ ─────► │  Auth · Postgres (RLS)           │
│  screens · widgets · theme  │        │  Edge Functions (Deno):          │
│  models · services · config │        │    · analyze-meal  (AI vision)   │
│                             │        │    · coach-chat    (AI coach)    │
└──────────────┬──────────────┘        └──────────────────────────────────┘
               │
               ├── Open Food Facts (barcode + product search)
               └── Apple HealthKit (steps, iOS)
```

The Flutter client is layered by responsibility, and all server-side state is
persisted to Supabase with Row Level Security. AI features run server-side in
Edge Functions so API keys never ship in the client bundle.

---

## Project structure

```text
lib/
├── main.dart                 # Entry point; exports ShiftFitApp for tests
└── src/
    ├── app/                  # MaterialApp, theme wiring, home shell + routing
    ├── auth/                 # Auth repository
    ├── config/               # Supabase + search configuration
    ├── models/               # Pure data models and mapping logic
    ├── screens/              # Top-level screens (Today, Week, Trends, Food, …)
    ├── services/             # Backend sync + external data sources
    ├── theme/                # Central colors and app theme
    └── widgets/              # Reusable UI, grouped by feature
        ├── app_shell/  common/  shared/
        ├── today/  week/  trends/  kcal/  meal/  profile/  auth/

supabase/
├── functions/                # Edge Functions (analyze-meal, coach-chat)
├── migrations/               # Versioned SQL schema (RLS, grants, features)
└── OAUTH_SETUP.md            # OAuth provider setup guide
```

**Conventions for future changes:**

- New screens → `lib/src/screens/`
- Reusable UI → `lib/src/widgets/`
- Pure data objects → `lib/src/models/`
- External API / sync logic → `lib/src/services/` (don't call APIs from widgets)
- Colors and theme → `lib/src/theme/` only
- Keep `lib/main.dart` small

---

## Getting started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `^3.11.5`)
- Xcode (iOS) and/or Android Studio for device/emulator builds

### Run

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

The app is runnable out of the box: `SUPABASE_URL` and `SUPABASE_ANON_KEY`
have build-time defaults in `lib/src/config/supabase_config.dart`. The Supabase
anon key is a public JWT (`role: anon`) — it is intended to be shipped in the
client and is not a secret on its own; access is enforced server-side by Row
Level Security.

### Point at your own Supabase project

Override the defaults with a local, git-ignored `dart_defines.json`:

```bash
cp dart_defines.example.json dart_defines.json
# fill in SUPABASE_URL / SUPABASE_ANON_KEY for your project
flutter run --dart-define-from-file=dart_defines.json
```

`--dart-define` values take precedence over the source defaults.

---

## Backend

The Supabase project is fully versioned in `supabase/`:

- **`migrations/`** — every schema change (tables, RLS policies, grants,
  feature migrations) as a timestamped SQL file.
- **`functions/`** — Deno/TypeScript Edge Functions:
  - `analyze-meal` — accepts a meal photo and returns a structured nutrition
    estimate from a vision LLM.
  - `coach-chat` — the AI coach endpoint, with server-side quota and safety
    layers.
- **`OAUTH_SETUP.md`** — step-by-step OAuth provider configuration.

To work against your own project, apply the migrations with the Supabase CLI
and deploy the Edge Functions. Each function requires its own provider API key
configured as a function secret — keys are never stored in the repo.

---

## Testing

```bash
flutter test
```

Widget tests rely on stable `Key` values and label strings (test pins) in
`test/widget_test.dart`. When changing UI, keep those identifiers intact or
update the corresponding tests in the same change.

---

## Continuous integration

`.github/workflows/security.yml` runs on every push/PR to `main`, on a weekly
schedule, and on demand:

- `flutter analyze` and `flutter test`
- `flutter pub outdated` (informational)
- [OSV-Scanner](https://google.github.io/osv-scanner/) against `pubspec.lock`
  with SARIF upload
- `deno lint` and `deno check` for the Edge Functions

The weekly cron run catches newly published CVEs in dependencies that were
clean at merge time.

---

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the
workflow, coding conventions, and how to run checks locally.

## Security

Please report vulnerabilities responsibly — see [SECURITY.md](SECURITY.md). Do
not open public issues for security reports.

## License

Released under the [MIT License](LICENSE). © 2026 Moritz Gietl.

---

> **Disclaimer:** FitPilot provides general fitness and nutrition information
> and is **not** medical advice. Consult a qualified professional before making
> significant changes to your training, diet, or health routine.
