# Eatova

> A polished Flutter nutrition app — frictionless calorie and macro tracking
> with AI meal scanning, barcode lookup, and a personal AI coach.

[![Status](https://img.shields.io/badge/status-in%20production-success)](#project-status)
[![Platform](https://img.shields.io/badge/platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Backend](https://img.shields.io/badge/backend-Supabase-3ECF8E?logo=supabase&logoColor=white)](https://supabase.com)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Eatova makes everyday food logging fast: snap a meal photo and get an itemized
nutrition estimate, scan a barcode, or search a self-hosted product index —
then let an AI coach answer training and nutrition questions with your actual
daily numbers as context. The app ships four tabs (**Heute**, **Food**,
**Rezepte**, **Coach**), is localized in German and English once you're
signed in, and targets Android and iOS only.

> **i18n scope:** the screens behind sign-in follow the language picker
> (`gen_l10n` over `lib/l10n/app_de.arb` / `app_en.arb`), guarded by
> `test/l10n/hartkodierung_waechter_test.dart` — which since the 2026-08-19
> review also looks for German display words that carry no umlaut, the class
> its character filter was blind to. Two things stay outside the picker:
>
> - the **sign-in/sign-up flow** itself (`lib/src/screens/auth_screen.dart`,
>   `lib/src/screens/auth_code_screen.dart`) is **not** part of that migration
>   and remains hard-coded German — an English-language device sees German text
>   on the very first screen;
> - German free text that is **already stored**: the model's own `explanation`
>   from earlier meal scans, and notes written into log entries before those
>   notes were resolved at display time. Stored text is your data and is never
>   retranslated retroactively.
>
> The notes on the analysis card (`lib/src/models/meal_analysis_result.dart`)
> are what the second point is about: source, confidence and portion notes are
> moving onto neutral markers that are resolved against the picker when the
> card is drawn, instead of being frozen in German at logging time. New
> entries follow the picker as that mechanism reaches each of them; the old
> rows keep the wording they were written with.

> **Note on the name:** the app is **Eatova** (formerly ShiftFit/FitPilot).
> The Dart package is now named `eatova` as well, so package name, app name,
> and branding are consistent throughout the repository.

---

## Project status

Eatova is **in production**. This repository is open-sourced under the MIT
license so the implementation can be studied, reused, and improved. It is a
real application, not a demo — treat the `main` branch as shippable.
See [CHANGELOG.md](CHANGELOG.md) for the release history.

---

## Features

- **Today** — the day at a glance: calorie hero, macro rings, and the logging
  streak. The landing tab; the Food tab is the diary itself.
- **Food tracking** — calorie and macro tracking per meal slot (breakfast,
  lunch, dinner, snacks) with:
  - **AI photo analysis** — in-app camera or gallery photo; the `analyze-meal`
    Edge Function returns an itemized nutrition breakdown (per-component
    grams/kcal) that can be re-portioned before and after logging.
  - **Barcode scanning** — product nutrition via `mobile_scanner`.
  - **Product search** — live text search against a self-hosted Meilisearch
    index of Open Food Facts, with the public Open Food Facts API as fallback.
  - **Manual entry** — a form for label values per 100 g plus the portion, for
    everything the scan, the barcode and the search do not find.
  - **History & editing** — swipe-to-delete, an edit sheet for logged meals,
    pinned favorites, and a date strip to log onto past days.
- **Trends** — weight, calories, and macros over selectable 7/30/90-day
  ranges, computed from real logged history, with goal corridor overlays.
  A full page opened from the Food tab, not a tab of its own.
- **Recipes** — browse recipes and add them straight to the tracker (on the
  day currently selected in the Food tab), plus your own recipes with a photo.
- **AI Coach** — chat coach for training and nutrition questions with session
  management, image input, speech input (iOS), a compact snapshot of your
  remaining macros as context, a daily quota, and layered safety filtering.
  The `/recipe` command returns a generated recipe with an AI picture as a
  card; it lands in your recipes only after you confirm it, and the picture
  stays on the device.
- **Profile & stats** — weight log with chart, a stat bar (streak, record,
  meals logged, weigh-ins), body values, daily goals, and the Apple Health
  connection. Language, theme, the JSON data export, sign-out and account
  deletion live on the Settings page behind the gear icon; the reminder toggle
  sits with the daily goals.
- **Offline robustness** — a durable write-through cache plus a sync outbox:
  logging works offline and reconciles with Supabase when connectivity
  returns; a cold start offline shows the last known state.
- **Reminders** — one local, on-device notification type: the evening
  streak-at-risk nudge, planned as dated single shots over a four-week horizon
  (daily for the first week, then weekly). No push infrastructure required.
- **Health integration** — reads daily steps, body-weight history, and sleep
  duration from Apple HealthKit on iOS, and writes back a body-weight entry
  when you log a weigh-in; the step count drives the calories-burned estimate.
  No-op on Android (no Health Connect integration).
- **Auth** — Supabase e-mail auth plus native Google Sign-In (Credential
  Manager on Android, Google SDK on iOS) with a web-OAuth fallback.
- **Crash reporting (opt-in)** — Sentry, only active when a DSN is provided.

---

## Tech stack

| Layer            | Technology                                                        |
| ---------------- | ----------------------------------------------------------------- |
| App              | [Flutter](https://flutter.dev) / Dart (SDK `^3.11.5`), German + English (`gen_l10n`/ARB) |
| Backend          | [Supabase](https://supabase.com) — Auth, Postgres + RLS           |
| Serverless       | Supabase Edge Functions (Deno / TypeScript)                       |
| Product search   | Self-hosted [Meilisearch](https://www.meilisearch.com) index of [Open Food Facts](https://world.openfoodfacts.org), OFF API fallback |
| AI meal analysis | Gemini vision model via [OpenRouter](https://openrouter.ai)       |
| AI coach         | Grok via OpenRouter, with server-side quota + safety layers       |
| AI recipe image  | Gemini image model via the OpenRouter image API (`/recipe` only)  |
| Health           | Apple HealthKit (`package:health`, iOS only) — read: steps, weight, sleep · write: weight |
| Crash reporting  | [Sentry](https://sentry.io) (optional, DSN via dart-define)       |

Key Flutter packages: `supabase_flutter`, `camera`, `image_picker`,
`mobile_scanner`, `health`, `google_sign_in`, `sentry_flutter`,
`flutter_local_notifications`, `shared_preferences`, `package_info_plus`.

---

## Architecture

```text
┌─────────────────────────────────┐         ┌──────────────────────────────────┐
│           Flutter app           │         │             Supabase             │
│            (lib/src)            │  HTTPS  │                                  │
│                                 │ ──────► │  Auth · Postgres (RLS)           │
│  screens · widgets · theme      │         │  Edge Functions (Deno):          │
│  models · services · config     │         │   · analyze-meal ──► OpenRouter  │
│  l10n (de + en)                 │         │   · coach-chat   ──► (Grok text, │
│                                 │         │                    Gemini image) │
│  LocalCache + SyncOutbox        │         │   · search-key                   │
│  (offline write-through)        │         └──────────────────────────────────┘
└──────────────┬──────────────────┘
               │
               ├── Meilisearch product index (self-hosted, search-only key)
               ├── Open Food Facts API (barcode + search fallback)
               ├── Apple HealthKit (read: steps/weight/sleep · write: weight; iOS only)
               ├── Local notifications (on-device, no push backend)
               └── Sentry (crashes only, opt-in via SENTRY_DSN)
```

The Flutter client is layered by responsibility, and all server-side state is
persisted to Supabase with Row Level Security. AI features run server-side in
Edge Functions so API keys never ship in the client bundle. Writes go through
a local write-through cache and an outbox, so the app stays usable offline.

---

## Project structure

```text
lib/
├── l10n/                     # app_de.arb / app_en.arb (source of truth)
├── main.dart                 # Entry point; exports EatovaApp for tests
└── src/
    ├── app/                  # MaterialApp, auth gate, home shell + store
    ├── auth/                 # Auth repository
    ├── config/               # Supabase, search index + legal link config
    ├── l10n/                 # l10n helper + generated/ (gen_l10n output)
    ├── models/               # Pure data models and mapping logic
    ├── screens/              # Top-level screens (auth, onboarding, food/meal,
    │   ├── coach/            #   trends, profile), large ones as part-based
    │   ├── recipes/          #   libraries in their own folder
    │   ├── settings/
    │   └── today/
    ├── services/             # Sync, outbox, cache, analyzers, external APIs
    ├── theme/                # Central colors and app theme
    └── widgets/              # Reusable UI, grouped by feature
        ├── auth/  common/  design/  shared/
        ├── kcal/  meal/  profile/

test/
├── flows/                    # End-to-end widget flows (auth, navigation,
│                             #   scan, logging, search, recipes) + helpers
├── app/  l10n/  models/  screens/  services/  theme/  widgets/
└── *_test.dart               # Screen-/feature-level suites

supabase/
├── functions/                # Edge Functions (analyze-meal, coach-chat,
│                             #   search-key) + _shared/
├── migrations/               # Versioned SQL schema (RLS, grants, features)
└── OAUTH_SETUP.md            # OAuth provider setup guide
```

The app is mobile-only: the repository contains `android/` and `ios/` platform
folders. Desktop and web scaffolding was removed on purpose (services use
`dart:io`; there is no web target).

**Conventions for future changes:**

- New screens → `lib/src/screens/` (large screens as a `part`-based library in
  their own subfolder, like `screens/coach/`)
- Reusable UI → `lib/src/widgets/`
- Pure data objects → `lib/src/models/`
- External API / sync logic → `lib/src/services/` (don't call APIs from widgets)
- Colors and theme → `lib/src/theme/` only
- User-facing text → a key in `lib/l10n/app_de.arb` **and** `app_en.arb`, never
  a string literal in a widget (`test/l10n/hartkodierung_waechter_test.dart`
  fails on hard-coded text)
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

### Crash reporting (optional)

Release builds can ship crash reporting via [Sentry](https://sentry.io). Set
`SENTRY_DSN` in `dart_defines.json` (see `dart_defines.example.json`) — with an
empty or missing DSN, Sentry is never initialized and the app runs exactly as
before, so dev builds and CI are unaffected. The configuration is deliberately
conservative (no PII, no screenshots, no replay, no performance tracing);
app code reports handled errors through `lib/src/services/crash_reporter.dart`.

### Release build (Android)

Play Store builds are signed with a dedicated upload keystore. Both the
keystore (`android/app/upload-keystore.jks`) and its credentials
(`android/key.properties`) are git-ignored and must never be committed.
`android/key.properties` has this format (`storeFile` is resolved relative to
`android/app/`):

```properties
storePassword=<store password>
keyPassword=<key password>
keyAlias=upload
storeFile=upload-keystore.jks
```

Build the Play Store bundle (or an installable APK) with:

```bash
flutter build appbundle --release --dart-define-from-file=dart_defines.json
flutter build apk --release --dart-define-from-file=dart_defines.json
```

If `android/key.properties` is missing, any release *assemble*/*bundle*/*package*
task **fails** with a `GradleException` naming the offending tasks
(`android/app/build.gradle.kts:118-143`). This is deliberate: without the file the
artifact would be signed with the universal Android **debug** key — Play rejects
the upload, and a sideloaded build silently breaks Google Sign-In because the
SHA-1 fingerprint no longer matches. Create `android/key.properties` as shown
above; for a pure compile check, build `--debug` instead. Debug builds (which is
all CI builds) are unaffected. Release builds run R8 (minify + resource
shrinking); plugin keep rules live in `android/app/proguard-rules.pro`.

> **Warning:** Back up the keystore and its passwords outside the repository
> (password manager + offline copy). If the upload key is lost, the only
> recovery is requesting an upload-key reset through Google Play App Signing
> support, which takes days and blocks releases.

---

## Backend

The Supabase project is fully versioned in `supabase/`:

- **`migrations/`** — every schema change (tables, RLS policies, grants,
  feature migrations) as a timestamped SQL file.
- **`functions/`** — Deno/TypeScript Edge Functions:
  - `analyze-meal` — accepts a meal photo and returns a structured, itemized
    nutrition estimate from a Gemini vision model (via OpenRouter).
  - `coach-chat` — the AI coach endpoint (Grok via OpenRouter), with
    server-side daily quota and layered safety filtering. Its `mode: "recipe"`
    branch drafts a recipe and generates the card picture through the
    OpenRouter image API; it returns data only and never writes user rows.
  - `search-key` — hands the client the base URL plus the search-only key of
    the product index at runtime (see "Product-search key rotation").
- **`OAUTH_SETUP.md`** — step-by-step OAuth provider configuration.

To work against your own project, apply the migrations with the Supabase CLI
and deploy the Edge Functions. Each function requires its own provider API key
configured as a function secret — keys are never stored in the repo.

### Product-search key rotation

The Meilisearch search-only key used by the product search is resolved at
**runtime**, not baked into the binary. The client walks this chain:

1. **Cache** — last key fetched, in SharedPreferences under
   `eatova.v1.search_credentials` (12 h TTL). Deliberately *not* keyed per
   user: it is device-global config, not PII, and sign-out must not throw a
   working key away. Expired entries are still **used** (served immediately,
   refreshed in the background) so a user offline for a week keeps searching.
2. **Fetch** — the `search-key` edge function returns base URL + key together,
   so relocating the mirror is a single secret update.
3. **Compile-time default** — `--dart-define=OFF_MIRROR_URL` /
   `OFF_MIRROR_SEARCH_KEY`. Covers a fresh install with no network.
4. **Mirror off** — empty credentials, search goes straight to Open Food Facts.

Search never hard-fails because the key endpoint is unreachable; the worst case
is the Open Food Facts fallback.

**To rotate the key:** create the new search-only key in Meilisearch, run
`supabase secrets set EATOVA_MIRROR_SEARCH_KEY=<new key>`, then revoke the old
one. Installed builds recover on their next search: the mirror answers the dead
key with `403`, the client drops it from memory and disk, fetches the
replacement and retries the same query once. No app update, no user action.

Rotation is driven by the 403 path, not by the TTL — the TTL only exists to
propagate a **base-URL** change, which surfaces as a connection error rather
than a 403 and therefore cannot self-heal. Refetching after a rejection is
single-flight with a 1-minute per-process cooldown, so a mirror returning 403
for an unrelated reason cannot burn the 20/h user rate limit. A successful
rotation logs once under the `search_credentials` log name.

`--dart-define=OFF_MIRROR_URL=` (empty) is a **hard local kill switch**: that
build never touches the mirror and no server setting can turn it back on. The
server-side kill switch is `EATOVA_MIRROR_SEARCH_KEY=disabled`, which makes the
function return empty credentials. A *missing* secret is a misconfiguration
(HTTP 500), not a kill switch — clients then keep their working compile-time
default instead of silently losing mirror search.

---

## Testing

```bash
flutter test
```

The suite is split by concern: end-to-end widget flows live in `test/flows/`
(shared fakes and the viewport-pinning `testWidgetsRobust` wrapper in
`test/flows/flow_test_helpers.dart`), unit suites in `test/models/` and
`test/services/`, widget- and screen-level suites in `test/widgets/`,
`test/screens/`, `test/app/` and `test/theme/`, the localization guards in
`test/l10n/` (ARB parity, hard-coded-text watchdog, locale wiring), and the
remaining suites at the `test/` root. Widget tests rely on stable `Key` values
and label strings (test pins) — when changing UI, keep those identifiers
intact or update the corresponding tests in the same change.

---

## Continuous integration

`.github/workflows/security.yml` runs on every push/PR to `main`, on a weekly
schedule, and on demand:

- `flutter analyze` + `flutter test`, with a coverage floor check
- Android debug build (APK) and Android release build (AAB with R8), the latter
  against a throw-away keystore plus a check that R8 actually ran
- `flutter pub outdated` (informational)
- secret scanning (gitleaks)
- [OSV-Scanner](https://google.github.io/osv-scanner/) against `pubspec.lock`
  and the Deno dependencies, with SARIF upload
- `deno lint` and `deno check` for the Edge Functions
- Supabase migration drift against the Management API

`.github/workflows/ios.yml` builds the iOS app without code signing. The weekly
cron run catches newly published CVEs in dependencies that were clean at merge
time.

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

> **Disclaimer:** Eatova provides general fitness and nutrition information
> and is **not** medical advice. Consult a qualified professional before making
> significant changes to your training, diet, or health routine.
