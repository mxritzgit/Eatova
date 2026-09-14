# Food entry and calendar design

The 2026-09-14 follow-up extends the accepted compact meal context to Camera
and Manual and gives manual nutrition, product results and the Food calendar
the same typography, lavender surfaces and soft input fills as the app.

## Interaction and presentation

- Camera places `MealSlotPicker` below its header. Opening or dismissing the
  picker preserves the active camera; a slot change does not recreate it.
  Capture locks selection while busy. Large text uses the available sheet
  height; permission recovery scrolls independently above the capture controls.
- Manual separates the dish name, label values per 100 g and a lavender portion
  panel. Calories and macros update from the entered weight. Fields stack on
  narrow screens or with enlarged text. Close/cancel preserves the parent draft;
  the search fallback adopts its changed meal only when an entry is saved.
- Search results use open product rows with a separate brand, uncropped package
  image and label density. Expanding a row reveals the editable portion and its
  resulting calories/macros. The display omits a duplicated brand suffix without
  changing the stored product identity. Preview and save use the same adjusted
  result, including the existing authoritative calorie calculation.
- Food opens a calendar sheet with a selected-date panel, a return-to-today
  action and explicit confirmation. Native month/year navigation, localized
  date input and date bounds remain intact. Tapping a day edits a draft; closing
  the sheet leaves the diary on its original day.

Favorites retain their accepted presentation. No dependencies, backend schema,
account boundaries or persisted meal formats change.

## Verification

The new widget tests cover German and English, light and dark themes, 390x844
at normal text size and 320x568 at 200%. They load the bundled Archivo and
Bricolage fonts, freeze calendar time, stub product and camera services, and
exercise selection, cancellation, invalid dates/portions and the saved values.

A real-font calendar capture exposed clipped two-digit days at 200%. The
intrinsic-width regression fails with the narrower calendar and passes after
giving its grid the sheet width. Text scaling remains enabled. Camera tests
also verify permission recovery, capture/gallery reachability and unchanged
preview initialization after meal selection.

Captures are reproducible with `FOOD_POLISH_CAPTURE=true` while running
`test/food_entry_polish_test.dart`; they are written to
`build/food-entry-preview/`. Review images use fixture products and local widget
rendering, not live account or camera data. Device installation and physical
camera testing are separate from this delivery.


Reviewed Flutter captures: [Manual](food-entry-preview/manual.png),
[portion preview](food-entry-preview/manual-portion.png),
[search results](food-entry-preview/search-results.png),
[expanded product](food-entry-preview/search-portion.png),
[calendar](food-entry-preview/calendar.png), and
[German calendar at 200%](food-entry-preview/calendar-large-text.png).

Final local validation on Flutter 3.47.2: **4,452 tests passed**, zero skips,
**94.96% coverage** (26,446/27,850 lines, generated localization excluded
as in CI). Strict analysis passes with infos/warnings fatal. Gitleaks 8.30.1
found no secrets in the reviewed source snapshot. The PR records protected-main
delivery and final CI on the reviewed commit.
