# Favorites — saved meals, ready to reuse

The inline favorites and their full library share an open collection surface,
with meal names, the saved portion's calories and a visible portion control.
Use the existing Balance Duo `AppTokens`, `AppType` and radius scale.

## Acceptance

- [x] Replace repeated icon-heavy pills with a distinct saved-meal presentation
  in both entry points; keep search results and recent meals unchanged.
- [x] Preserve portion validation, calorie authority, pin/unpin, removal,
  recency, filtering, selected slot/day and account boundaries.
- [x] Make the library's context, close, empty and no-match states clear;
  support both themes/locales, 320 px, 2x text and keyboard insets.
- [x] Complete independent reviews, full tests, rendering and flow checks.

Hierarchy and grouping (H2/H3/H4), recognition (H48), Fitts's Law and progressive
disclosure guide the layout. Primary work remains choosing a portion and logging
it. Favorite removal stays accessible; full deletion moves into expanded details.
No invented food photography, decorative nutrient colors or backend changes.

## Design and behavior

Both entry points use one joined surface with generous meal names, saved-portion
calories, an actionable heart and a visible portion control. The expanded meal
uses lavender, while nutrient chips reuse Today's protein, carbs and fat colors.
Calories and macros use the same adjusted result as the existing Add callback;
unknown calories and recipes without cooked weight retain their existing rules.

The library keeps its title, close button and search above a scrolling collection.
Selected-meal context explains where additions go. Empty and no-match states
provide a direct way back. The sheet handles its bottom safe area outside the
toast host, clearing consumed view padding so floating messages are not offset
twice. No store, service, account, schema, dependency or network changes.

## Verification, 2026-09-11

- Flutter 3.47.2: all 4,344 tests across 422 files passed, no skips or failures.
- Line coverage: 95.12% (25,232/26,527), excluding generated localization as CI
  does, above the unchanged 88% floor. Strict analyzer: no warnings or infos.
- Android x64 debug APK built with dummy configuration. Existing AGP/Kotlin
  future-support advisories remain; dependencies and lockfiles are unchanged.
- Independent general and security/final-delta reviews found no actionable
  introduced findings, including callback identity and safe-area handling.
- Regression checks cover saved total versus per-100-g density, adjusted totals
  matching the logged result, invalid portions, the selected slot and toast
  placement above the home indicator and keyboard. Existing app-shell flows
  cover pin/unpin, persistence, filtering, archive dates and account isolation.
- Real-font Flutter modal renders checked inline favorites, the library,
  expanded portions, keyboard, no-match and emptied-library states in DE/EN,
  light/dark, 393 px and 320 px at 2x text. The no-favorites entry was checked at
  375 px. Controls remain scroll-reachable without clipping their text.

Ignored local evidence is in `.agents/favorites-library/`. These checks use
Flutter rendering and automated app-shell flows; physical-device presentation
and native keyboard behavior remain device checks. Delivery follows the PR from
`design/favorites-library`, based on main `9467a29`. A client build must be
installed for the design to appear on a device; no backend rollout is needed.
