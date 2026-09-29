# Food — dark redesign

Since the dark redesign (2026-09-28, `design/food/template.html` of the user's
`Design.html`), the Food tab is one scrolling page on the dark tokens with a
floating capture dock above the floating tab bar. The earlier "Thumb First"
contract (concept 09, 2026-09-12) is superseded; its behaviour guarantees are
kept.

## Design and behavior

- **Header**: the "Food" title and a round calendar button that opens the
  existing date picker. Other years include the year; future days remain
  unavailable.
- **Day switcher**: a pill with previous/next day around the day's name
  (Today, Yesterday, "N days ago") and its date ("Monday, Sep 28"). The next
  arrow is disabled on today.
- **Day summary**: logged kcal, kcal left (or over) against the budget incl.
  the activity credit (`nutritionSummaryForFoodDate`, the same number as
  Today), a stacked macro bar sized by each macro's kcal share, and a legend in
  grams. Tapping the card opens Trends.
- **Meal cards** (one per slot): the shared `SlotIconTile`, the slot name,
  "08:10 · 3 items" and the slot total; every entry as a row (name, amount,
  kcal; oldest first) and an "Add to <slot>" row. Tapping an entry edits it,
  swiping deletes it with undo. Tapping a filled card's header shows or hides
  the macro details (the slot's P/C/F sum and each entry's P/C/F). An empty
  slot shows its suggested kcal band on today, and the day's recipe pick
  ("Fits tonight · 610 kcal") when `nextMealPick` targets that slot; the pick
  opens the recipe, whose add action asks for the slot.
- **Dock**: a search capsule (opens the search sheet; long-press opens manual
  entry directly), a barcode button and the accent camera button for the AI
  scan. All three start in the current meal slot. Manual entry is also the
  "Add manually" row of every add sheet; favorites stay in the add sheet.
  The diary scrolls under the dock and the tab bar; very short windows keep
  the dock at the diary's end.
- Loading archive days show a loading state without stale totals or enabled
  capture actions. A new date starts at the top with the macro details closed.

Services, store, account isolation, offline cache/outbox, meal arithmetic and
favorites are unchanged. There are no backend, schema, dependency or lockfile
changes.

## Verification

The wiring of every control and figure is pinned in
`test/flows/food_redesign_wiring_test.dart`; the building blocks in
`test/widgets/kcal/food_redesign_parts_test.dart`. Captures of the design
scenario come from `test/design/food_redesign_capture_test.dart` (run with
`--dart-define=DARK_REDESIGN_CAPTURE=true`, output in `build/dark-redesign/`).
