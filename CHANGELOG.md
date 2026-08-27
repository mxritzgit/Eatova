# Changelog

All notable changes to Eatova are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Versions map to the `version` field in `pubspec.yaml` (build number after `+`).

## [Unreleased]

### Added

- **Macros per slot and per meal** (#49) — the diary shows protein, carbs and
  fat for every meal slot and every logged meal, not only for the day; the
  coach receives the same per-slot sums as context ("per meal today"). Bottom
  sheets now sit below the Dynamic Island and respect the keyboard.
- **Steps card on the Today tab** (#50) — the day's step count from the
  connected health source, following the selected diary date; without a
  source the card stays away instead of showing 0.
- **Slot choice in the barcode scanner** (#50) — the same slot chips as the
  camera scan, so a scanned product lands in the intended meal directly.
- **Favorites menu in the add sheet** (#53) — the top three favorites inline
  plus "All (N)", which opens a favorites sheet with search, add-to-slot and
  unpin.
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
- **Password reset and eight-digit e-mail codes** — recovery and sign-up
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

- **Calorie model reworked after the calorie review of 2026-08-21** (#47,
  #48). The activity ladder no longer includes walking (PAL 1.3 … 1.9 instead
  of a 1.2 floor), and every recorded step counts on top of it — the old
  step baseline that silently swallowed the first few thousand steps is
  gone. Daily targets have a floor of 1200 kcal (women), 1500 kcal (men) and
  1350 kcal (unspecified) instead of a unisex 1200; the deficit is capped at
  1 % of body weight per week on a 0.05 kg grid; protein targets use a
  reference weight rather than the current weight; the goal date is shown
  as a range, and pace labels round to 0.05 kg steps.
- Calories burned are frozen per day instead of showing 0 for archive days.
- The coach's empty state no longer suggests example questions.

### Fixed

- **Boot load no longer fails on a fresh session** (#52, Sentry FLUTTER-9/-A/
  -B) — the server occasionally rejected a token that had just been issued;
  the boot load treated that 401/PGRST303 as a dead session and dropped the
  data. It is now retried once with the refreshed token (`StaleAuthRetry`),
  and both status codes count as retryable.
- **A failed OAuth sheet no longer crashes the app** (#52, FLUTTER-8) — the
  auth-state listener behind the OAuth sheet had no `onError`, so a stream
  error surfaced as a fatal uncaught exception instead of a message.
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
- **Full project review of 2026-08-19** — twenty areas reviewed, every serious
  finding adversarially re-checked, and what survived fixed. The theme was
  errors being swallowed rather than reported:
  - **The app can no longer hang on the welcome screen.** Sign-in handed over
    only after the whole network boot had finished, and none of it carried a
    timeout — on a captive-portal Wi-Fi the sockets never answer and the app
    stayed stuck although the encrypted cache already held everything. The
    cached profile now opens the gate, with an eight-second budget as a
    backstop.
  - **Two paths that lost data silently.** A failed write of the offline queue
    disappeared into an empty `catch` while the screen said "syncing"; and the
    cache dropped a slot on *any* decryption error, including an isolate that
    merely failed to start under memory pressure. Both now report, and only a
    genuinely broken ciphertext is discarded.
  - **The meal scan no longer invents calories.** With no usable numbers from
    the model, a substring match against a fruit table plus a 150 g default
    produced a loggable figure. Unknown stays unknown.
  - **Personal data is cleared when the session ends, not when the sign-out
    button is pressed** — an involuntary session end or a user switch used to
    leave the previous account's cached diary, profile and weight behind.
  - Coach: a provider error the client caused itself no longer refunds the
    daily slot, so the paid classifier call stays capped at five a day rather
    than sixty an hour.
  - The data export shows a preview instead of rendering megabytes into a
    single text block, and says honestly when nothing could be loaded.
  - A fruitless product search costs one request instead of nine, and a
    throttled search service is named instead of looking like "no results".
  - Smaller ones: barcode hits during the closing animation no longer close the
    sheet underneath; the today tab shows a loading state instead of claiming
    an empty day; toggles and the day picker meet the tap-target and scaling
    bar; camera photos are removed from the cache after use; Android
    notifications get a real icon instead of a white square; session-storage,
    coach and search failures now reach crash reporting.
  - Apple Health: the sleep permission is no longer requested — nothing used
    it — and a write-only grant no longer counts as proof that reading works.
  - `user_recipes` and chat session titles get the size and range limits the
    hardening migration gave every other client-writable table.
  - The hard-coded German left in the meal card and the diary confirmations is
    localized, and the guard test can now see German words without umlauts.

### Security

- All seven findings of the security review of 2026-08-11 and the hardening
  points of the audit of 2026-08-09.
- Coach: a Layer-2 bypass for images is closed; the rate-limit subject is taken
  from `cf-connecting-ip` or the rightmost `x-forwarded-for` entry, so a
  client-supplied header can no longer aim at someone else's bucket; poison
  operations can no longer wedge the sync outbox.
- **Account deletion: the server now enforces the re-authentication it always
  displayed** — the confirmation sheet already asked for a fresh e-mail
  code, but `delete_account()` itself only checked `auth.uid()`; a captured
  session token could call the RPC directly and skip the code entirely. The
  function now requires a JWT with an `otp`/`recovery` entry in the `amr`
  claim from the last five minutes and rejects everything else with
  `EX_REAUTH_REQUIRED` (SQLSTATE 28000); the client shows a dedicated
  "confirmation expired" message for that case.
- **Sync: lifetime counters no longer double-count on a killed replay** — a
  meal or weight write interrupted between server delivery and the local
  bookkeeping used to log its lifetime-stats delta again on the next boot.
  The increment is now its own idempotent outbox operation with an id derived
  from the original write, so a repeated replay can no longer inflate
  `meals_logged`/`weight_logs`.
- **Coach: Layer-1/2 refusal texts follow the chat's locale** — the
  eleven-entry refusal catalog (medical risk, eating disorder, self-harm
  including the crisis reply, off-topic, and so on) is now bilingual on the
  server, and the chat request carries the app's locale so English sessions
  get English refusals instead of German ones. The recipe path picks this up
  as soon as the function is deployed; the **chat path only takes effect once
  the app build that sends the locale ships** — existing chat clients keep
  getting German refusals in English sessions until then.
- **E-mail codes lengthened to eight digits** — GoTrue's `/verify` endpoint is
  rate-limited per IP only and a wrong attempt does not consume the code, so a
  distributed attacker had a double-digit success chance against a six-digit
  code within its ten-minute lifetime; eight digits cut that by a factor of
  100. Input fields, validation and texts follow `kAccountCodeLength`; the
  server-side `mailer_otp_length` is flipped together with this change (an
  older build truncates the longer code — see `supabase/AUTH_EMAIL_OTP.md`
  for the rollout order).
- **The reauthentication-nonce contradiction is resolved** — verified against
  the GoTrue source: with `security_update_password_require_reauthentication`
  the nonce is only demanded for sessions older than 24 hours; fresh sessions
  skip the check entirely, which is exactly why the recovery flow works
  without one. Documented in `supabase/AUTH_EMAIL_OTP.md`, including the
  accepted residual risk and the `require_current_password` lever deliberately
  not pulled.
- **`profiles.email` no longer goes stale after an address change** — the
  bootstrap trigger only fired on user creation, so the GDPR data export
  served the old address; a new `AFTER UPDATE OF email` trigger reuses the
  same function to keep the mirror in sync.
- **Legacy `fitpilot://` redirect URIs dropped from the auth allow-list** —
  no app registers that scheme since the rebrand, so a malicious app could
  have claimed it conflict-free as an OAuth redirect target.
- **`profiles` writes are now column-scoped** — the row-level policy allowed
  a manipulated client to set `email`, `display_name` and `avatar_url`
  directly via PostgREST even though the app never writes them; a forged
  `email` would have surfaced in the GDPR export. INSERT/UPDATE grants for
  `authenticated` are now limited to exactly the columns the app writes;
  the mirror columns stay with their security-definer triggers.
- **Coach: the auto-title write is owner-bound on its own** — the
  `chat_sessions` title read and PATCH ran with the service key filtered by
  session id alone, relying on the caller having checked ownership first;
  both requests now carry a `user_id` filter as defense in depth.

### Internal

- All source comments are English and compact (#51) — roughly 27,000 comment
  lines became 16,700 across twenty packages; test names and string
  literals deliberately stay German.
- `app_settings`, `http` and `supabase` are declared as direct dependencies
  (80ea946) — they were imported directly but only reached the app
  transitively via `supabase_flutter`; the basis for the review fix run of
  2026-08-27.

### Fix-Lauf Review 2026-08-27

Closes every High and Medium finding of the 2026-08-27 full review (10 packages, 117 findings). Highlights:

- **Goals:** the manual-energy switch is persisted (`profiles.manual_energy`, migration `20260828100000`) instead of being reconstructed by comparing stored goals with the calculator; live profiles heal themselves on boot and write back once. Manually set targets are reset to the calculator once (no SQL backfill possible).
- **Food tab:** the add sheet mirrors logged and adjusted meals immediately in "already added" and the slot total; snacks (including undo) render inside the open sheet and stay tappable; search fields are borderless; fixed heights respect large text.
- **Auth:** both auth screens follow the design system in light and dark mode, `app_colors.dart` is gone, ~70 new ARB keys, typed auth exceptions, screen-reader labels and 44 pt targets, AutofillGroup, inline "enter code" action after an unconfirmed sign-up.
- **Design system:** button themes (text = ink, filled = ink/bg, min 48 pt; 54 pt only for the primary button), borderless `inputDecorationTheme` plus `FieldCapsule`/`SheetField`, one focus language (`field` -> `fieldFocus` -> `fieldError`) across all 13 input capsules, toggle-off contrast >= 3:1, light-mode carbs colour 3.4:1, `t.scrim`, radius tokens, disabled state for `PrimaryActionButton`.
- **Meal scan:** typed `MealAnalysisException`s with server `error` codes mapped to localized texts, status check before decode, retry/cancel/manual-entry inside the result sheet with the photo kept, barcode scanner app-lifecycle handling, "open settings" on denied permission plus manual EAN entry, constructor seams with a loopback wire test.
- **Sync:** per-collection mutation counters against the boot race, `LocalCache.closed` fences (no PII writes after logout), backoff escalates per replay only, offline replays no longer reach Sentry, PostgREST request timeout 20 s, "connection slow" screen instead of onboarding when the boot budget expires, boot re-entry guard, stats requeue inherits the in-flight request id.
- **Coach:** retry marker without duplicate bubbles, dictation fills the field instead of sending, microphone iOS-only, borderless composer, selectable answers, localized default session title; server: empty completion = 502 + refund (a bare `__REFUSE__` stays a refusal), app context placed right before the question plus a "USING APP DATA" block, history without refusal pairs, plain text, 800 tokens.
- **Backend:** analyze-meal daily and global caps (IP -> user-day -> user -> global), search-key Meilisearch tenant tokens behind `EATOVA_MIRROR_KEY_UID` (600 s grace, `no-store`), image-text injection guard, referer eatova.de.
- **Profile:** weight input validated (Health imports outside 20-400 kg are dropped), a single weight-log cap (365) with an explicit baseline, reminders via `TZDateTime.from`, trends goal line with the step bonus (wired through the shell), water/sleep goals removed, notification init fenced.
- **Recipes:** one cooked-weight method for all 30 catalog entries (de/en), category search in English plus ingredients and umlaut folding, "Own" chip, undo on delete, catalog-only rotating carousel, client limits equal to DB constraints.
- **Platform/docs:** iOS `InfoPlist.strings` de/en plus `CFBundleLocalizations`, privacy docs without sleep reading, coverage filter for generated l10n, onboarding and coach flow tests, `.gitignore` for session artifacts, CONTRIBUTING with the exact CI commands.

Verification: `flutter analyze --fatal-infos --fatal-warnings` clean, 2688 Flutter tests green with the CI defines, Deno 187/187.

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
