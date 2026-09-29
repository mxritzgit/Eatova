# Today — dark redesign

The user's `Design.html` (2026-09-28) replaces the "Balance Duo" layout of
2026-09-11. The design, not this file, is the authority for the look; this
file records the data and interaction contract behind it.

## Layout (top to bottom)

1. Header: date line ("Monday, Sep 28"), the "Today" title, a streak pill
   (hidden at 0) and the 44 px profile avatar.
2. Seven-day strip: the six days before today plus today on the right. A
   horizontal swipe, or the "Earlier days"/"Later days" screen-reader actions,
   pages by a week; there is no page after today. It replaces the old
   previous/next arrows.
3. Calorie card: eaten share, 270° arc with the kcal left in its centre,
   Eaten / Goal / Activity. The Activity stat is omitted without a credit.
4. Three macro tiles (compact names; screen readers hear the full name).
5. Recipe pick for today's next open main meal (`HomeStore.nextMealPick`),
   opening the recipe's detail page. Hidden without a pick, on archive days
   and while a day loads.
6. "Meals" with "Open food log" (switches to the Food tab), and the four slot
   rows. Each row's "+" opens the Food tab's add flow for that slot on the
   shown day; the next open main meal's "+" is accent-filled.
7. Activity card: steps against the goal with the kcal credit, then the
   selected plan's next workout (switches to the Training tab). Without a step
   source the steps row is dropped; on Health Connect a missing source shows
   the review hint instead.

The page runs under the floating tab bar and pads its end by the bar's band.

## Data rules

- All numbers come from one `DayNutritionSummary` (budget = raw goal +
  activity credit), the rule every tab shares. The Goal stat stays the raw
  profile goal; over budget the centre says "over" with the magnitude.
- Archive days say "that day", show no suggested kcal bands and no pick or
  workout. Loading days show one loading card instead of numbers.
- The accent "+" uses `nextOpenMainMealSlot`, the rule behind the pick.

## Moved functions

- Settings: avatar -> profile page -> its gear (was a header button).
- "Log a meal" (pinned button): each slot's own "+".
- Coach banner: removed; the Coach tab is one tap away in the tab bar.

## Verification

Widget and flow tests: `test/screens/today/`,
`test/flows/today_wiring_flow_test.dart` (every control against the real
shell), `test/flows/today_first_viewport_test.dart` (header, strip and the
complete calorie card above the glass at scroll offset 0). Captures:
`test/design/today_redesign_capture_test.dart` with
`--dart-define=DARK_REDESIGN_CAPTURE=true`, written to `build/dark-redesign/`.
