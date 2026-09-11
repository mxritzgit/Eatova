# Meal entry — a continuation of Today

The add-meal sheet follows Today’s Balance Duo palette and typography. This
redesign changes the entry surface, preserving the existing photo, barcode,
search, manual, favorite and recent-meal workflows.

## Acceptance

- [x] Clear title and selected date/slot context, a prominent labeled photo
  action, and readable gallery, barcode and manual alternatives.
- [x] Normal entry does not immediately open the keyboard. Explicit search
  entry focuses search; clearing it restores the entry choices and cancels
  pending search state without changing the selected slot.
- [x] All paths remain reachable with the keyboard, at 320 px, with 2x system
  text and in both themes/locales. Reduced motion keeps immediate feedback.
- [x] Independent general/security reviews, complete Flutter suite and
  visual/flow checks. Protected-main merge requires green PR CI.

## Design and behavior contract

Use `AppTokens`, `AppType` and the existing radius/spacing conventions as the
style source. Lavender links the main photo action to Today; white and neutral
surfaces keep secondary methods quiet. Nutrient colors remain nutrient colors.
No new palette, font, package or backend is needed.

The hierarchy applies H1/H2 (one primary action), H19/H20 (labeled, visible
affordances), H27/H48 (preserve context), and H9/H36/H39 (reflow, reduced motion,
touch targets). Hick’s Law motivates separating entry choices from search
results; Fitts’s Law motivates larger capture targets. Motion acknowledges
interaction, with no looping decoration or delayed access.

Keep store-supplied list updates and row identities intact. Do not change meal
arithmetic, calorie validation, search debounce/deadlines, account checks,
photo confirmation/upload timing, local mirroring, undo or quota behavior.
Keep stateful search and portion fields mounted consistently through updates.

Delivery follows the PR from `design/meal-entry`. A merged client design does
not establish an installed device build or store release.

## Verification evidence, 2026-09-11

- Flutter 3.47.2: all 4,339 tests passed, no failures or skips. The 421 test
  files match default suite discovery; slow training suites were scheduled first.
- Line coverage: 95.13% (25,105/26,391), excluding generated localization,
  against the unchanged 88% floor.
- Strict analyzer passed with no warnings or infos. Independent general and
  security reviews found no actionable introduced issues.
- Android x64 debug APK built with dummy configuration. Existing AGP/Kotlin
  future-support advisories remain; dependencies and lockfiles are unchanged.
- Existing app-shell flows passed for manual entry, photo/barcode, favorites,
  archive dates, portion editing, undo and account changes. New tests cover
  entry-intent focus, clear-search/late-result handling, capture sources,
  accessible targets and reduced-motion press feedback.
- Real-font Flutter modal previews were inspected in DE/EN and light/dark,
  at 375/393 px and 320 px with 2x text and a simulated keyboard inset. Loading,
  explicit search error, results, empty and added-meal states were also checked.

Ignored local evidence is in `.agents/meal-entry/`. Browser automation was
unavailable; the visual checks used Flutter rendering and automated app-shell
flows, not a physical device. Native keyboard and camera presentation on an
installed build remain device checks. No backend or migration rollout is needed.
