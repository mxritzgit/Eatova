# Today, meal entry and account design

## Accepted direction

The 2026-09-13 request brings the existing Eatova screens into a more consistent
app: complete Steps visibility on a regular phone, compact meal context, uniform
page titles, and clearer account pages. It retains the existing Today Balance
Duo, Food Thumb First, Recipe and Training Nachtstudio designs.

### Today and page navigation

- Tighten whitespace around the date, calorie hero and macro rows. Keep type,
  ring sizes and touch targets readable. The complete Steps card fits above the
  fixed meal action at 390×844 with top/bottom insets of 59/34, including activity
  calories and a streak. Small phones with enlarged text remain scrollable.
- Use the shared 30-point display title for all five root tabs, with the same
  left alignment and top inset. Secondary page headers use 24-point display
  type and reflow at enlarged text sizes.
- Today provides the profile avatar and a direct Settings action. Remove the
  Food overflow menu and its profile/settings callback API. Returning from
  account routes preserves tab state and entered recipe search text.
- Preserve Food's calorie-to-Trends action and Training's scoped dark palette.

### Meal context

Add Meal and Barcode show the current meal in one compact context row. Tapping
it opens a shared selection sheet with four generous rows, distinctive meal
icons, a selected checkmark and clear labels. Dismissing the sheet keeps the
previous selection. The Barcode context sits below its header, where it remains
available during camera errors and manual barcode entry.

Preserve the selected diary date, save destination, search and draft state,
scanner lifecycle and account guards. Photo, manual entry, editing and favorite
flows continue to use their existing data and confirmation contracts.

Barcode uses throttled detection rather than native duplicate suppression:
Android otherwise remembers a code seen behind the meal picker and suppresses
it after the picker closes. The existing current-route and single-result guards
still reject covered or repeated callbacks. A fake that models the native
duplicate state verifies the original failure and the correction.

### Profile and Settings

Profile uses a lavender identity panel and open statistics, followed by a clear
sequence of plan, body, daily targets and health connection sections. Values
come from the existing store; the presentation introduces no inferred account
or health state.

Settings uses open groups, aligned menu rows and full-width appearance/language
choices below their labels. Account access, preferences, data/privacy and account
management each have a distinct place. Borderless soft fills and visible focus
indication remain the input convention.

Authentication, reauthentication, export, deletion, encrypted cache and account
isolation remain governed by the existing implementations and tests.

## Verification and evidence

The implementation was split across four isolated worktrees, then reviewed and
integrated by the commander. The Today regression fails on the original layout:
the Steps bottom is at 724 while the scroll viewport ends at 676. With the spacing
fix it ends at 675. Tests use the actual app shell, bundled fonts, frozen time
and device insets, including German/English and 200% text on a small phone.

Integrated Flutter captures use dummy account data and the real app shell:
[Today](app-polish-preview/today.png),
[Profile](app-polish-preview/profile.png),
[Settings](app-polish-preview/settings.png),
[Add Meal](app-polish-preview/add-meal.png), and
[meal selection](app-polish-preview/meal-picker.png).

Final integrated validation on Flutter 3.47.2: all 4,421 tests passed without
skips; coverage is 94.94% (26,208/27,604 lines), excluding generated localization
as CI does. Strict analysis passed. An Android x64 debug APK built successfully
in an isolated worktree with byte-identical production/build sources and dummy
configuration. The integrated capture/navigation run passed 64 checks.

Full-suite follow-up preserved Coach review actions with enlarged text and a
keyboard: short viewports switch to compact chrome when the title wraps. The
review action must be hit-testable. Existing language, history navigation and
color-exception tests now follow the new controls and labels.

The PR records protected-main delivery and final CI. Local review captures and
detailed logs stay in the ignored `.agents/app-polish-2026-09-13/` workspace.
Rendering and scanner tests use stubbed device services; camera hardware testing
and device installation are separate from this code delivery.
