# Changelog

All notable changes to Eatova are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Versions map to the `version` field in `pubspec.yaml` (build number after `+`).

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
