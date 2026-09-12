# Food — Thumb First

The Food tab follows the selected concept 09: an open meal diary, a simple date
row and a lavender capture dock above bottom navigation. It uses the existing
Today Balance Duo tokens, typography and component radii. Favorites retain their
accepted presentation.

## Design and behavior

- A Food heading and calorie tile show the selected day's total. Previous/next
  arrows and the calendar replace the scrolling date chips. Other years include
  the year; future days remain unavailable. Trends open from the calorie tile;
  profile and settings remain reachable from the header's overflow menu.
- Four meal sections use pastel icons and fine separators. Empty sections open
  meal entry for their slot. Populated sections show a meal name or entry count,
  a short preview and the slot's total calories.
- Tapping a populated section reveals every entry, including long names,
  quantities, macros, calories and time. Existing editing, swipe deletion and
  undo remain available. An explicit add action follows the expanded entries.
- Search, camera, barcode and direct manual entry share the bottom dock. Manual
  entry shows date/slot context, lets the user choose a slot and writes only
  after confirmation, with the existing validation and an account-identity guard.
- Normal phone layouts pin the dock. Narrow/short windows and large text scroll
  the full page. Stable widget paths preserve expansion and scroll position when
  another tab's keyboard or rotation resizes Food. Choosing another date resets
  the diary to its first meal.
- Loading archive days show a loading state without stale totals or enabled
  capture actions. German/English, dark mode and reduced motion use the existing
  localization and theme systems.

Services, store, account isolation, offline cache/outbox, meal arithmetic and
Favorites are preserved. There are no backend, schema, dependency or lockfile
changes.

## Verification

Verified on 2026-09-12 with Flutter 3.47.2:

- All 4,372 tests across 424 files passed, without skips or failures.
- Coverage: 95.12% (25,329/26,629 lines), excluding generated localization as
  CI does; the 88% floor is unchanged. Strict analyzer: no warnings or infos.
- Android x64 debug APK built with dummy configuration. Existing AGP/Kotlin
  future-support advisories remain; no dependencies were changed.
- Independent general and security follow-up reviews found no open actionable
  introduced regressions after the corrections below.

The implementation includes regression coverage for ten entries, full-name
reading and editing, slot confirmation, archive navigation, loading, scroll reset,
responsive state retention, 320 px windows and 2x text. Existing app flows follow
the visible new controls while retaining persistence, totals, undo and date
separation assertions. Contrast and touch-target checks cover both themes.

Review defects were reproduced with failing tests before correction: oversized
fixed chrome on a narrow/short viewport, lost browsing state on resize, a dock
that did not fill spare height, and a pending calendar result lost when its
controls moved. The picker and overflow-menu choices now complete from the
stable screen context, including profile/settings selection after resizing. The
earlier stale scroll offset on a new date was also demonstrated before correction.

Verification evidence is also recorded with the delivery PR. Ignored local
logs and real-font Flutter captures are in `.agents/food-thumb-first/`. Captures
include empty, populated, ten-entry, expanded, dark and large-text states. These
are rendered Flutter and automated app-shell checks; physical-device appearance
and native keyboard testing remain separate from code and CI verification.

Delivery uses `design/food-thumb-first`, based on main `90f4b03` (PR #81), through
protected main after green CI. A new client build must be installed to see the
design on a device; no backend rollout is needed.
