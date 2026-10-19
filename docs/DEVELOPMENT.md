# Development and builds

Checked against main through PR #88 on **2026-09-14**. Use
[CONTRIBUTING.md](../CONTRIBUTING.md) for checks and PR conventions.

## Toolchain and targets

- Flutter **3.47.2 stable**, Dart **3.13.2**, matching the workflow pin.
- `pubspec.yaml` has the Dart lower bound `^3.11.5`; that is not the recommended
  development SDK. The declared package version is `1.1.0+4`.
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

Do not put service-role, management, Anthropic, OpenRouter or Meilisearch master keys in
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
`AppSymbol`/`AppIcon`; every meal-slot mark (diary rows, pickers, sheet
headers) is a `SlotIconTile`. Inputs use soft borderless fills with visible
focus indication. Review normal/enlarged text when changing layout. The app
follows the display mode (System, Light, Dark; default System), so check both
palettes: the design capture suites render in light with
`--dart-define=DESIGN_CAPTURE_BRIGHTNESS=light` (shots in
`build/light-redesign/`, see `test/support/design_capture.dart`). The
[design index](README.md#design-contracts-and-previews) links to current
contracts and real Flutter captures.

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
up outside the repository. Then build with your public client configuration
through the helper, from an up-to-date `main`:

```bash
python3 scripts/operations/device_build.py appbundle
python3 scripts/operations/device_build.py apk
```

The helper passes `dart_defines.json` and sets the build number (Android
`versionCode`) to the commit count of `HEAD`, the same rule as the
[release lane](#release-lane). A plain `flutter build appbundle` takes the
pubspec's build number (`+4`), far below the commit counts Play has already
seen, so Play rejects it as a lower version.

The Gradle guard rejects release assemble/bundle/package tasks without signing
configuration. R8 minification and resource shrinking are enabled; plugin keep
rules live in [proguard-rules.pro](../android/app/proguard-rules.pro). CI uses a
throwaway keystore and verifies `mapping.txt`; that AAB is a compile check, not
a store-signed release. Debug builds do not require the upload keystore.

Changing the signing identity also changes Google Sign-In fingerprints. Register
the intended debug/upload/Play App Signing identities for their actual use.

## Device builds and the build number

Install release builds on a device through the helper. It builds with the
defines and with the build number set to the commit count of `HEAD`, then
installs the build over the one on the device (`flutter run` takes no build
number):

```bash
python3 scripts/operations/device_build.py iphone -d <id>  # Mac only: build ios + install
python3 scripts/operations/device_build.py android         # build apk + install
python3 scripts/operations/device_build.py ipa             # store builds, no install
python3 scripts/operations/device_build.py appbundle
```

Device builds update the installed app in place and keep its data: Android
with `adb install -r`, iPhone with `xcrun devicectl device install app`.
`flutter install` is not used, because Flutter 3.47.2 uninstalls the app
first, which deleted the unsent outbox, the encrypted cache, reminders and
Health grants on every install. If the device refuses the update (a lower
build number than the installed one, or a build signed with another key), the
install fails and the old build keeps its data; uninstalling is then your own
decision, after the outbox has been delivered.

Use `-d <device>` to pick the device (required for an iPhone; the id comes
from `flutter devices`), and `--dry-run` to print the commands without running
them. Other arguments go to `flutter build`; `--split-per-abi` and `--flavor`
are refused for an install because they change the APK path. iPhone builds
need macOS with Xcode. On Windows, set `FLUTTER` to the full path of
`flutter.bat` (PowerShell: `$env:FLUTTER = "C:\path\to\flutter\bin\flutter.bat"`).
`adb` comes from `ADB`, else from `ANDROID_HOME`/`ANDROID_SDK_ROOT`
`platform-tools`, else from `PATH`. `device_build.py build-number` prints the
number without building.

Device checks after an install include an update over the previous build with
a pending outbox entry: log a meal offline on the old build, install the new
one over it, and check that the entry is still queued and reaches the server
once online.

The pubspec build number stays the same across many merges. Reinstalling the
same release over a running app looks like an OS kill to Sentry's iOS SDK, and
was reported as a WatchdogTermination (FLUTTER-C on 1.1.0 (2) and 1.1.0 (3)). A
build number per commit lets Sentry tell an update from a kill.

## Release lane

**Release (Android)** ([release.yml](../.github/workflows/release.yml)) builds
a store release of the current `main` head, by hand only:

1. refuses any ref but `main` and a shallow checkout; the build number is the
   commit count of `main` (`device_build.py build-number`), the version name
   comes from `pubspec.yaml`;
2. runs the [client release eligibility](OPERATIONS.md#client-release-and-rollback-gate)
   check of that commit;
3. writes `dart_defines.json` from the secret `RELEASE_DART_DEFINES` (the
   JSON content of a release `dart_defines.json`) and masks every value. It
   stops when `SUPABASE_URL`, `SUPABASE_ANON_KEY` or `SENTRY_DSN` is missing
   or empty: a release without a DSN would ship with crash reporting off;
4. writes the upload keystore and `android/key.properties` from four
   secrets, and stops if one is missing;
5. builds the signed AAB with `device_build.py appbundle` and checks the R8
   mapping and that the bundle is not debug-signed;
6. with `SENTRY_AUTH_TOKEN`, `SENTRY_ORG` and `SENTRY_PROJECT`: puts a
   ProGuard id into the app (`sentry-debug-meta.properties`) before the
   build, then uploads the R8 mapping under that id and the native libraries'
   debug files with a pinned `sentry-cli`. Without them a warning says so;
7. keeps the AAB, its SHA-256, the mapping and the eligibility result as the
   artifact `android-release-<build>` (90 days);
8. with `PLAY_SERVICE_ACCOUNT_JSON`: uploads the AAB to the internal track in
   one Play edit, as `draft` (default) or `completed`. Without it, upload the
   artifact's AAB in the Play Console;
9. tags the commit `v<name>+<build>` (for example `v1.1.0+405`) through the
   API; a rerun of the same commit keeps its tag.

One-time setup on GitHub (owner):

- Environment `release`: required reviewer (the owner), deployment branches
  limited to `main`, no administrator bypass.
- Environment secrets: `RELEASE_DART_DEFINES`;
  `ANDROID_UPLOAD_KEYSTORE_BASE64` (the keystore file, base64),
  `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`,
  `ANDROID_UPLOAD_KEY_PASSWORD`; optional `SENTRY_AUTH_TOKEN` (project
  releases and debug files only), `SENTRY_ORG`, `SENTRY_PROJECT`; optional
  `PLAY_SERVICE_ACCOUNT_JSON` (a service account invited in the Play Console
  with release rights for this app only).
- Before the first release with Sentry secrets, pin `SENTRY_CLI_VERSION` and
  the SHA-256 of that release's `sentry-cli-Linux-x86_64` in the workflow in a
  reviewed PR; empty values fail the Sentry step.
- The workflow's first run is the first real check of the Play edit, the
  Sentry id in the app and the tag; check one test crash in Sentry
  (deobfuscated Java frames) after it.

The first upload of a new app, Play App Signing enrolment and store listing
remain Play Console work. iOS has no job: TestFlight, Sign in with Apple and
a distribution certificate need the paid Apple Developer Program (owner
decision); a first TestFlight upload stays manual from a Mac with
`device_build.py ipa`.

## Checks and delivery

Run the exact applicable commands in [CONTRIBUTING.md](../CONTRIBUTING.md).
Flutter tests use dummy Supabase values and stub external requests; Deno tests
stub fetch and do not require network permission. Database tests use disposable
Postgres. Never point tests at the maintained live backend.

Use a topic branch and PR. Main is protected by required checks; the workflow
currently also runs full CI for documentation PRs. Code merge, backend rollout,
store publication and device installation are separate outcomes.

Wait for a PR's checks and merge it with
[`scripts/operations/pr_gate.py`](../scripts/operations/pr_gate.py), not with
ad-hoc polling. It reads the named GitHub credential from `GITHUB_TOKEN` and
never prints it:

```sh
python3 scripts/operations/pr_gate.py wait 127              # 0 green, 1 red, 2 timeout
python3 scripts/operations/pr_gate.py merge 127 --head <reviewed sha>
```

A check counts as finished by its conclusion. GitHub can leave a finished job
at status `in_progress` for good (seen on PR #127); the tool names such a run
as a status lag instead of waiting for it. `merge` squash-merges only the
reviewed head with every check green and GitHub reporting it mergeable. The
owner's approval to merge is still required.
