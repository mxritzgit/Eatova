# App design review, 2026-09-07

Review and implementation based on `main` at `4ae47eb`, on local branch
`design/app-icon-polish`. The user requested replacing the Today walking-person
icon and Coach sparkles, plus a broader design inspection and suitable fixes.

## Review coverage

Ten review assignments were completed across three reusable subagents. Creating
a fourth subagent failed with the environment's thread limit; ten distinct
agents were therefore not available. The assignments covered Today, Coach,
navigation, Food, Recipes, profile/settings/trends, accessibility, empty/loading/
error states, typography, and a final interaction/consistency review.

Style comes from `lib/src/theme/app_tokens.dart` and the shared design widgets.
The forest/lime palette, Bricolage/Archivo typography, soft borderless inputs,
and existing motion conventions remain the basis of this work. No dependency,
backend, localization copy, or data-flow changes are needed.

## Implemented decisions

| Surface | Change | Reason |
| --- | --- | --- |
| Today and profile step goals | Shared vector shoe-print symbol | Specific, recognizable meaning instead of a generic person. |
| Coach header and tab | Outlined/filled conversation symbols | One identity across entry points; no decorative AI stars. |
| Coach disclosure and generated-image badge | Info and image symbols | Distinguish explanation from image provenance; retain explicit AI wording. |
| Photo analysis and its states | Camera, add-photo, and result-check symbols | Describe the actual task and state. |
| Calculated plan, weight maintenance, recent meals | Calculator, flat trend, and history symbols | Replace unrelated magic, sleep/shield, and bookmark metaphors. |
| Today step card | Full-width wrapping explanation and wrapping header | Keep burned calories, goal, title, and count readable at large text sizes. |
| Today meal rows | Chevron when tappable | Make the existing entry action discoverable. |
| Today Coach CTA | Minimum 44 px tap height; banner uses `rCard` | Comfortable touch target and consistent shared corner radius. |
| Coach conversations | 15 px body text; error-specific banner icon | Easier reading and clearer state recognition. |
| Coach AI image badge | 11 px wrapping label | Preserve attribution on narrow images with larger system text. |
| Food metadata | UI typeface and quieter weight | Separate descriptions from the numerical/headline typography. |
| Recipe detail | Nutrition tiles adapt to measured text width; readable instructions | Full values and labels instead of ellipses; 14 px primary body text. |
| Profile statistics | 11 px labels, wrapping values/units, adaptive columns | Honor enlarged system text instead of shrinking it with `FittedBox`. |

The main craft priorities were recognition (H16/H48), readable hierarchy (H2),
responsive reflow (H9), visible affordances (H19), and touch targets (H39).

## Deferred suggestions

- Coach starter suggestions would add a new interaction. Keep for a separately
  designed flow; choosing a suggestion should only fill a draft.
- Profile pace/calorie plan chips deserve a separate narrow-screen review.
  They were identified in source, but not changed in this increment.
- Full profile captures at 320 px / 2x also show pre-existing name truncation
  and an awkward wrap in the weight comparison's current-value label. These
  sit outside the changed statistics layout.
- Broad redesigns of navigation, trends, recipe catalog, and input forms had
  no demonstrated benefit sufficient to justify replacing their current design.

## Verification and delivery

Regression tests cover the Today CTA target and full step explanation, recipe
nutrition at 320 px with 2x text in German/English and both themes, and profile
statistics without text-shrinking transforms. Existing tests cover the retained
callbacks, localization, loading/error states, recipe confirmation and Undo.

Real Flutter widget renders use the bundled fonts and Material glyphs with
stubbed data, with normal phone widths plus 320 px / 2x text. Local inspection
artifacts live in ignored `build/design-polish/`; these are widget renders,
not screenshots of an installed device build. A first visual pass caught and
fixed a split word in the large-text steps header.

The new profile layout regression was also run against an isolated copy of
HEAD's original widget: it fails at the expected stacking assertion (second
tile top 20 instead of at least 559), after successful setup and rendering.
The working tree was never reverted or mutated during concurrent tests.

The first complete suite exposed two recipe-flow tests tapping below the
viewport and four assertions still expecting the replaced maintenance icon.
The flow tests now scroll both Add and Back into view; the icon assertions
retain their goal-calculation checks and expect the flat-trend symbol.
All 27 tests in those two suites pass after the updates.

Final verification: Flutter 3.47.2 / Dart 3.13.2, strict analyzer clean,
**3,666 Flutter tests passed**, **94.82% line coverage** excluding generated
localization (88% floor), and independent `codex review --uncommitted` without
actionable findings. Six additional visual-capture cases passed. Verification
logs are ignored under `.agents/design-polish/`. Backend/Deno/RLS code is
unchanged and those suites were not rerun for this UI-only increment.

No commit, push, merge, backend deployment, or installed device build was
performed. Review the local renders and use the normal topic-branch PR workflow
for delivery.

### Android emulator delivery, 2026-09-08

At the user's request, built the current debug APK successfully and installed
it as an update on `fitpilot_pixel` (`emulator-5554`, Android 16 / API 36).
Eatova launched successfully; its activity was foregrounded and the Today tab
was visually verified. Existing app data was preserved. The screenshot is at
ignored `build/design-polish/android-launch.png`. This supersedes the earlier
no-installed-build statement for this local Android emulator only; no physical
device/iOS installation, commit, push or merge was performed.
