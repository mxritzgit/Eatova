# Changelog

All notable changes to Eatova are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Versions map to the `version` field in `pubspec.yaml` (build number after `+`).

## [Unreleased]

### Added

- **English localization** — everything behind sign-in speaks German and
  English (`gen_l10n` over `lib/l10n/app_de.arb` / `app_en.arb`): screens, the
  recipe catalog, the AI scan, dictation and the service texts all follow the
  chosen language. The picker sits in the settings; without a choice a German
  device gets German and every other device English. `test/l10n/` guards ARB
  parity and hard-coded text. **Not yet covered:** the sign-in/sign-up flow
  (`auth_screen.dart`, `auth_code_screen.dart`) is still hard-coded German —
  it predates this package and was never folded into it.
- **Heute tab** — the day at a glance (calorie hero, macros, streak) as the
  landing tab; the Food tab becomes the diary itself. Four tabs instead of
  three, in the order Heute · Food · Rezepte · Coach.
- **New design language** — token-based theme with a light mode, and the
  settings as a page of their own (language, appearance, data export,
  sign-out, account deletion) instead of a block inside the profile. The
  profile screen was reworked around an identity header and a stat bar.
- **Coach recipe generator (`/recipe`)** — the coach drafts a recipe and has a
  picture generated for the card; the pair costs one quota slot. The proposal
  carries data only: it becomes one of your recipes after an explicit
  confirmation in the sheet, the returned picture is stored on the device and
  never on the server, and after a restart the card is rebuilt from the chat
  history plus that local file. A
  failed image is not a failed recipe — the card falls back to a placeholder
  and the slot is not refunded.
- **Manual meal entry** — a form for label values per 100 g plus the portion,
  reachable as a labelled row in the add sheet and from the empty state of the
  product search. Logged with its own source marker instead of a faked scan
  result.
- **Password reset and six-digit e-mail codes** — recovery and sign-up
  confirmation run through OTP codes on their own screen instead of mail
  links. The send confirmation stays neutral about whether an account exists.
- **Food calendar** — 30 scrollable days with a visible archive chip.
- **Encrypted local cache** — the write-through cache (diary, weight series,
  body values, profile) is AES-256-GCM encrypted. Only the 32-byte key lives
  in the OS keystore (Android Keystore / iOS Keychain); the blobs stay in
  SharedPreferences.
- **Photos for your own recipes** — stored in the app's own directory, removed
  with the recipe, on sign-out and on account deletion. A recipe row only ever
  carries a `local:` reference, so a second device shows the placeholder
  instead of a broken image.
- **Splash** — the brand focus ring loads and locks in, replacing the flash.

### Changed

- Calories burned are frozen per day instead of showing 0 for archive days.
- The coach's empty state no longer suggests example questions.

### Fixed

- **Review 2026-08-08, six waves** — data-loss paths, silently wrong health
  numbers, UI/navigation/state, the Android and iOS platform layer, plus wire
  tests against the silent switches; CI builds the real release artifact.
- **Sentinel class** — states that passed themselves off as data (auth,
  notification permission probe, profile values), and the quota RPC guard with
  its slot refund.
- The streak reminder no longer falls silent after two weeks away: dated
  single shots over a four-week horizon (daily for the first week, then
  weekly) instead of a seven-day window that only refilled on use.
- Coach: the "added" state of a recipe card survives a restart (the slug is
  derived from the message id instead of an in-memory map).

### Security

- All seven findings of the security review of 2026-08-11 and the hardening
  points of the audit of 2026-08-09.
- Coach: a Layer-2 bypass for images is closed; the rate-limit subject is taken
  from `cf-connecting-ip` or the rightmost `x-forwarded-for` entry, so a
  client-supplied header can no longer aim at someone else's bucket; poison
  operations can no longer wedge the sync outbox.

## [1.1.0] - 2026-08-07

### Added

- **Meal editing** — edit sheet for already-logged meals (name, kcal, macros,
  slot), with macro-aware re-portioning.
- **Trends screen** — weight, calories, and macros over 7/30/90-day ranges
  with goal corridor overlays, computed from real logged history.
- **Food calendar** — date strip in the Food tab to view and log onto past
  days; recipes land on the day selected in the Food tab.
- **Offline outbox** — durable write-through cache (`LocalCache`) plus a sync
  outbox: logging works offline and reconciles with Supabase later; cold
  starts offline show the last known state instead of defaults.
- **Crash reporting (opt-in)** — Sentry, initialized only when `SENTRY_DSN`
  is provided via dart-define; no PII, no replay, no tracing.
- **Native Google Sign-In** — Credential Manager sheet on Android, Google SDK
  dialog on iOS, ID token exchanged via Supabase; web-OAuth fallback kept.
- **Release signing (Android)** — dedicated upload keystore (git-ignored),
  R8 minification + resource shrinking, Play-Store-ready `appbundle` builds.
- **German localization** — Material/Widgets localization delegates with
  locale `de`, so SDK dialogs (time/date pickers) render in German.
- **Branding** — Eatova wordmark with focus ring on the auth screen and
  focus-ring launcher icons for Android + iOS.
- `CHANGELOG.md` (this file).

### Changed

- Legal links now point to `eatova.de` (privacy policy, imprint) instead of
  the GitHub `PRIVACY.md`.
- AI scan hardening: the in-app camera preview no longer rotates with the
  device; photos are re-compressed (max 1600 px, JPEG q85) before upload.
- Sync queries are bounded (query limits) to keep payloads predictable.
- About dialog shows version and build number dynamically from the package
  metadata (`package_info_plus`) instead of hard-coded values, and lists the
  actual data sources (OpenFoodFacts, own search index; Apple Health on iOS).
- `coach_chat_screen.dart` (2000+ lines) split into a `part`-based library
  under `lib/src/screens/coach/` — pure file split, no behavior change.
- The end-to-end widget test monolith (`test/widget_test.dart`) split into
  thematic suites under `test/flows/` (auth, navigation, recipes, scan,
  logging, product search) with shared helpers; same 15 tests as before.

### Fixed

- Cancelling the Google login no longer surfaces as a generic error.
- `FlutterFragmentActivity` on Android so the `health` plugin registers.

### Removed

- Unused desktop/web platform scaffolding (`web/`, `linux/`, `windows/`,
  `macos/`) — the app is mobile-only (Android + iOS) and core services use
  `dart:io`.

## [1.0.0] - 2026-08-05

Initial production release (build 1) after the ShiftFit/FitPilot → **Eatova**
rebranding, in development since 2026-05.

- Three tabs: **Food**, **Rezepte**, **Coach** (the earlier Today dashboard,
  week planner, and training/recovery features were removed in favor of a
  focused nutrition app).
- Food tracking with per-slot logging (breakfast/lunch/dinner/snacks), AI
  photo analysis with itemized results (in-app camera + gallery, `analyze-meal`
  Edge Function with a Gemini vision model), barcode scanning, product search
  against a self-hosted Meilisearch index with Open Food Facts fallback,
  favorites, and swipe-to-delete history.
- AI coach (Grok via OpenRouter) with sessions, image input, speech input on
  iOS, daily quota, and layered safety filtering.
- Recipes tab with add-to-tracker.
- Profile with weight log, streak/lifetime stats, achievements, JSON export,
  and Apple HealthKit step import (iOS).
- Local on-device reminders (hydration, caffeine cut-off, sleep runway,
  streak-at-risk) — no push backend.
- Supabase backend: auth, Postgres with Row Level Security, versioned
  migrations, Deno Edge Functions.
