# Development and builds

Checked against main through PR #88 on **2026-09-14**. Use
[CONTRIBUTING.md](../CONTRIBUTING.md) for checks and PR conventions.

## Toolchain and targets

- Flutter **3.47.2 stable**, Dart **3.13.2**, matching the workflow pin.
- `pubspec.yaml` has the Dart lower bound `^3.11.5`; that is not the recommended
  development SDK. The declared package version is `1.1.0+3`.
- Android application ID: `com.eatova.app`, minimum API 26. Health Connect is
  separately availability-checked and is not promised on every supported OS.
- iOS minimum: **15.0**. Building iOS requires macOS, Xcode and CocoaPods.
- No web/desktop app scaffolding. Several services use native APIs and `dart:io`.

## Client configuration

```bash
flutter pub get
cp dart_defines.example.json dart_defines.json
flutter run --dart-define-from-file=dart_defines.json
```

Fill the two Supabase values in the ignored local file before running. The
source contains public defaults for the maintained service; independent
development should point at its own configured backend.

| Dart define | Purpose |
| --- | --- |
| `SUPABASE_URL` | Your project's public endpoint |
| `SUPABASE_ANON_KEY` | Public client key; RLS still enforces account access |
| `GOOGLE_WEB_CLIENT_ID` | Web/server audience for native Google token exchange |
| `GOOGLE_IOS_CLIENT_ID` | iOS Google client, paired with the URL scheme |
| `OFF_MIRROR_URL` | Optional product-search mirror override |
| `OFF_MIRROR_SEARCH_KEY` | Optional public search-only fallback credential |
| `SENTRY_DSN` | Optional crash reporting; missing/empty disables initialization |

`String.fromEnvironment` falls back only when a key is absent. An explicitly
empty value replaces the source default. Do not add empty keys merely to list
them. Empty `OFF_MIRROR_URL` is a hard local mirror disable; an empty search
key can make lookup fall back to OFF. See [search configuration](../lib/src/config/search_config.dart)
and [runtime credential rotation](BACKEND.md#product-search-key-rotation).

Do not put service-role, management, OpenRouter or Meilisearch master keys in
Dart defines. Local runtime files, keystores and credentials stay out of Git.
For the maintained workspace, named credentials are retrieved from Infisical
inside the executing process; no secret values belong in documentation or logs.

## Authentication

The UI offers email/password and native Google sign-in, with a web fallback.
Configure Google clients and mobile callbacks using
[OAUTH_SETUP.md](../supabase/OAUTH_SETUP.md). The email screens expect eight-digit
OTP codes; auth service templates/settings must match
[AUTH_EMAIL_OTP.md](../supabase/AUTH_EMAIL_OTP.md).

App strings, including auth and recovery, come from German/English ARB files.
Server email templates are independently configured and do not automatically
follow the app language picker.

## Localization and design changes

Add keys in both `lib/l10n/app_de.arb` and `app_en.arb`, then run
`flutter gen-l10n`. Generated files under `lib/src/l10n/generated/` are ignored.
Keep semantic labels and test keys stable; localize user-facing text.

Reuse theme tokens and the existing design components. Original pictograms use
`AppSymbol`/`AppIcon`; meal motifs come from `MealSlotStyle.symbol`. Inputs use
soft borderless fills with visible focus indication. Review normal/enlarged
text and both themes when changing layout. The [design index](README.md#design-contracts-and-previews)
links to current contracts and real Flutter captures.

## Crash reporting

`SENTRY_DSN` controls whether Sentry starts. The source configuration disables
default PII, screenshots, view hierarchy, replay, performance tracing and
automatic session tracking. Reports and breadcrumbs pass an allow-list filter;
handled failures go through [CrashReporter](../lib/src/services/crash_reporter.dart).
A configured DSN is a build setting, not a user-facing opt-in switch.

## Android release signing

Release builds require an upload keystore and ignored `android/key.properties`:

```properties
storePassword=<store password>
keyPassword=<key password>
keyAlias=upload
storeFile=upload-keystore.jks
```

`storeFile` is relative to `android/app/`. Keep the keystore and passwords backed
up outside the repository. Then build with your public client configuration:

```bash
flutter build appbundle --release --dart-define-from-file=dart_defines.json
flutter build apk --release --dart-define-from-file=dart_defines.json
```

The Gradle guard rejects release assemble/bundle/package tasks without signing
configuration. R8 minification and resource shrinking are enabled; plugin keep
rules live in [proguard-rules.pro](../android/app/proguard-rules.pro). CI uses a
throwaway keystore and verifies `mapping.txt`; that AAB is a compile check, not
a store-signed release. Debug builds do not require the upload keystore.

Changing the signing identity also changes Google Sign-In fingerprints. Register
the intended debug/upload/Play App Signing identities for their actual use.

## Checks and delivery

Run the exact applicable commands in [CONTRIBUTING.md](../CONTRIBUTING.md).
Flutter tests use dummy Supabase values and stub external requests; Deno tests
stub fetch and do not require network permission. Database tests use disposable
Postgres. Never point tests at the maintained live backend.

Use a topic branch and PR. Main is protected by required checks; the workflow
currently also runs full CI for documentation PRs. Code merge, backend rollout,
store publication and device installation are separate outcomes.
