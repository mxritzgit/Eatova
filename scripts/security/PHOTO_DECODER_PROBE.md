# Isolated Android photo decoder probe

This manual target measures the real production `compressMealPhoto` function
through Flutter's `compute` isolate on Android. It never initializes Supabase,
Sentry, camera/gallery or account storage and uses only synthetic gradients.
Release mode is deliberately refused. It is not an application or store build.

Build with the pinned Flutter SDK after normal `pub get` / `gen-l10n`:

```powershell
flutter build apk --profile --target-platform android-x64 --no-pub `
  --target scripts/security/photo_decoder_probe.dart `
  --dart-define=PHOTO_DECODER_PROBE=true `
  --dart-define=SUPABASE_URL=https://ci.invalid `
  --dart-define=SUPABASE_ANON_KEY=ci-dummy-key
```

Use **only a new disposable Android emulator**. The APK has the existing
application ID `com.eatova.app`: installing it over a real Eatova installation
would replace that app. Before each install, verify `adb -s <serial> emu avd name`
against the exact disposable AVD name you created. Never select a device merely
because it is the first result from `adb devices`.

1. Install the resulting `build/app/outputs/flutter-apk/app-profile.apk` on that
   AVD after `adb -s <serial> shell getprop sys.boot_completed` returns `1`,
   then start `com.eatova.app/.MainActivity`.
2. Read `files/photo-decoder-probe.json` from the app sandbox. On a debuggable
   fixture use `adb -s <serial> exec-out run-as com.eatova.app cat
   files/photo-decoder-probe.json`. A profile build may require root access on
   the disposable emulator; never alter protection on a user device.
3. The first launch only prepares four fixtures. Wait for
   `state=fixtures_ready_restart_process`, then force-stop the process.
4. Start/force-stop between each of the four remaining phases. Each launch
   decodes one fixture. Require `case_complete_restart_process` or `complete`
   before advancing. Put a host timeout on each launch (the recorded run used
   120 seconds); if exceeded, force-stop that fixture and report the failure.
   A timeout is a harness limit, not a production decoder deadline.
5. Completion requires `state=complete`, `next_phase=5` and four `passed=true`
   results. Collect the JSON and the APK hash, Android image/API/architecture,
   build mode and SDK version. Stop the disposable emulator after collection.

The cases are a 1600x1200 JPEG, 4000x3000 camera-sized JPEG, 2048x2048 RGBA PNG,
and 4096x4096 RGBA PNG at the 64-MiB raster budget. The latter is a legitimate
finite image, not a decompression bomb. Each must normalize to JPEG with a
1600-pixel longest edge. Fixture generation runs separately from measurements.

`wall_ms` covers the compute transfer, preflight, decode, resize and re-encode.
CPU ticks are the delta of Android `/proc/self/stat` user/system process ticks;
record `adb shell getconf CLK_TCK` before converting to seconds. RSS is sampled
every 25 ms; `process_high_water_rss_bytes` is the whole process high-water mark,
including startup. Values include Flutter and process memory, not only raster
bytes. Sampling can miss short peaks, so preserve both metrics. CPU includes
other process work; first-run shader/rendering and system scheduling can affect
timing. A fresh process prevents earlier fixture generation/decode from setting
the next case's high-water mark.

These observations establish behavior for this corpus and emulator. They do
**not** prove a worst-case RSS/CPU bound, an in-app memory limit, low-memory
hardware behavior, iOS decoding, all JPEG sampling/progressive profiles, or
server/provider decoding. Recheck representative signed builds on dedicated
Android/iOS devices before a release. Image dimensions and input-size guards
are separate from total process-resource guarantees.

## Recorded local result, 2026-09-15

All four cases completed in separate process launches on the newly created
`eatova_security_r4_media` AVD: Android 16/API 36 `google_apis` x86_64,
4 virtual CPUs, 2048 MiB configured RAM. Flutter 3.47.2 / Dart 3.13.2, **profile
AOT** target, Android Debug signing certificate, debuggable fixture. The original
user AVD and physical devices were untouched. The disposable AVD was stopped
after collection. The first install attempt occurred before Android finished
booting and failed; retry after the boot-completed signal succeeded.

| Synthetic input | Wall time | Process CPU | RSS before | Process peak RSS |
| --- | ---: | ---: | ---: | ---: |
| 1600x1200 JPEG | 1.129 s | 0.85 s | 212.1 MiB | 256.7 MiB |
| 4000x3000 JPEG | 2.439 s | 2.24 s | 215.1 MiB | 465.1 MiB |
| 2048x2048 RGBA PNG | 2.670 s | 2.92 s | 209.6 MiB | 304.9 MiB |
| 4096x4096 RGBA PNG | 7.195 s | 5.56 s | 210.3 MiB | 425.3 MiB |

`getconf CLK_TCK` returned 100; process CPU can exceed wall time because it
includes all app threads. Every output passed the JPEG/dimension assertions;
no case reached the 120-second timeout. The measurements confirm substantial
decoder working memory beyond the raster budget, particularly for 12-MP JPEG.
They do not set a safe ceiling for lower-memory real devices.

APK SHA-256:
`d00d64bd2438476ad784e88b614b27177af444ac8ce632b2203e98cd6a744e94`.
Local detailed report: `.agents/security-followup-2026-09-15/reports/media-native-result.json`
in the original project workspace (ignored). It preserves byte-level input/output
sizes, CPU ticks, sample counts, process high-water and sampled RSS separately.
This record is a local profile fixture result, not a signed release acceptance.
