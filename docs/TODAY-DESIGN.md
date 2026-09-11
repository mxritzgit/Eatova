# Today — Balance Duo

The user selected the “02 / Balance Duo” reference on 2026-09-11. This
implementation redesigns Today and carries its lavender palette into the
existing screens. Other tabs retain their structure and features.

## Acceptance

- [x] Split calorie hero, three pastel macro rows, compact steps, meal rows and
  a fixed “Mahlzeit erfassen” action follow the selected reference.
- [x] Light lavender replaces the dark green brand surfaces; dark mode uses
  neutral violet surfaces. Recipe photographs and camera overlays stay legible.
- [x] Calorie arithmetic, selected dates, meal slots, Health Connect recovery,
  loading states and navigation retain their existing behavior.
- [x] Complete final review, full-suite verification and delivery record.

## Design contract

`lib/src/theme/app_tokens.dart` remains the color source of truth. Existing
`forest`/`onForest` and `lime`/`onLime` names are compatibility fields;
they now describe lavender surfaces and contrasting violet accents.
New code uses `brandSurface`/`onBrandSurface`. Do not use the pale surface
alone to communicate selection; existing selection controls retain their
contrasting ink/background pairing.

The light palette uses background `#F8F8FC`, white cards, brand surface
`#EAE5FF`, text `#16151F`, and contrasting accent `#6550A8`.
Protein, carbohydrate and fat surfaces are `#DDF5E4`, `#DDF3FC` and
`#FFEFC1`. A separate `progressAccent` (`#9782DC`) keeps the rings softer
than action/text ink while retaining 3:1 contrast against their tracks.
Nutrient progress colors follow the same contract. Photo/camera foregrounds
use `onImage` and `imageAccent`; they must not follow the dark text on a
light brand surface.

The existing Archivo/Bricolage Grotesque fonts and radius scale remain.
Small screens and large system text stack the hero and macro labels instead
of shrinking detail text. Only the large remaining-calorie number can scale
down. The calorie ring, macro amounts, date controls and headings retain
localized semantics. Input focus remains borderless, with a distinct soft fill.

## Data and interaction boundaries

The hero still calculates remaining calories as raw goal + activity credit -
consumed calories. It labels the raw goal and activity separately. Negative
remaining values mean “kcal drüber”; progress rings stop at 100%. Archive
days have their own heading, and loading never displays invented zero totals.
Missing steps remain distinct from measured zero.

The fixed add action reuses the existing meal-slot callback into Food. It reads
the suggested slot when tapped, preserves the selected diary day, and is
disabled during loading. All four meal slots, Profile, Coach and day controls
remain reachable. Meals use icons because logged meals do not currently retain
a photo; sample photos are not substituted for user data.

No schema, backend, dependency, permission or cache changes are required.

## Verification evidence

Final validation on Flutter 3.47.2:

- 4,329 Flutter tests passed; zero failures or skips. The final run contains
  exactly the same cases as default full-suite discovery, with slow training
  suites scheduled first.
- 95.11% line coverage excluding generated localization code (floor: 88%).
- Strict analyzer: no warnings or infos. Final independent Codex review: no
  actionable findings. Source and whitespace checks passed.
- Android x64 debug APK built successfully with dummy configuration. Existing
  AGP/Kotlin support advisories remain; no dependency changes were made.
- The new archive-day add/manual-save flow passed through the real app shell.


Ignored local evidence lives in `.agents/today-balance/` and
`build/today-balance/`. Flutter-rendered previews cover light/dark, German/
English, normal phone widths and 320 px with 2x system text. Recipe detail and
profile previews were also inspected.

The complete application compiled in an isolated local web preview, using
`PreviewAuthRepository`, no sync and dummy configuration. Direct browser UI
automation was unavailable in this session. Automated UI flows exercise the
real app shell, including archive-day manual entry through the new action.

Delivery follows the PR from `design/today-balance-duo` after green CI. The PR
records the final merge status. This client-only change needs a new app build
to appear on an installed device; no backend or schema rollout is required.
