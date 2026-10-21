# Weight trend and re-anchoring

Status: stage 1 merged on 2026-10-03 (PR #126); stage 2 implemented on
2026-10-03. Background:
[calorie review 2026-08-21](REVIEW-KCAL-2026-08-21.md) §4.1. The user made the
decisions on 2026-10-03.

## Problem

Weigh-ins never reached the plan. `UserProfile.weightKg` was set at
onboarding or on the goals screen and then stayed put. The weigh-ins on the
profile page only filled the weight log, so several things kept using the old
number:

- in live mode, the daily goal and the macros;
- the plan card ("current → target") and the forecast;
- the step kcal and the Coach context.

The weight and BMI cards already used the latest weigh-in. The profile
therefore showed two different "current" weights.

## Stage 1: the trend is the current weight

- **Trend** (`WeightLog.trendKg`): an exponentially weighted moving average
  over the weigh-ins, with these rules:
  - Each local day counts once, with its **last** weigh-in. A later entry of
    the same day counts instead of an earlier one. Since 2026-10-19 a
    weigh-in can also be edited or deleted (see "Correcting weigh-ins").
  - The smoothing is 10 % per day and time-aware: a day `Δ` days after the
    last counted one moves the trend by `1 − 0.9^Δ`. A weekly weigh-in
    therefore counts about 52 %, and a weigh-in after a month almost fully.
  - A day more than 5 % off the trend is an **outlier** (a typo, a wrong
    onboarding weight, a long break) and is held back:
    - If the next weigh-in day lies within 5 % of it, the jump is real and
      the trend moves to that day.
    - Otherwise the outlier is dropped.
    - An outlier on the last day does not move the plan yet.

    Normal daily swings (1–2 kg of water) stay below 5 % and are smoothed.
  - A day more than 28 days after the last counted one starts afresh. After
    a break the new weight is no outlier.
  - Known limit: the first day seeds the trend unchecked. A typo on the very
    first weigh-in day drives the plan until two later days agree. The goal
    notice makes it visible.
- **Plan weight** (`WeightLog.planWeightKg(now)`): the trend, but only while
  its last **counted** day is at most 28 days old (a held outlier does not
  refresh it) and the rounded value fits `ProfileLimits` (30–300 kg). Otherwise there is no plan weight and the
  profile weight stays in charge. This also covers a user who stopped
  weighing in and later typed a weight on the goals screen.
- **Re-anchoring:** after a weigh-in (manual or Apple Health import), after
  an edit or a delete of one, and after the boot load, the store sets
  `profile.weightKg` to the rounded plan weight when they differ.
  - It requires a completed onboarding.
  - It requires that the server answered both the profile and the
    weight-log load in this session. A full profile row is never written from
    a cached profile or a cached log alone, because another device may have
    changed it. A cache re-hydration that brings back different rows clears
    the gate again. A later boot catches up.
  - At boot it runs after the cache snapshot is written. That way its own
    commit cannot make the snapshot conflict.
  - Live mode recomputes the goals in the same step (`applyLiveGoals`).
  - Manual mode keeps its own goals and only updates the weight.
  - The weigh-in and the profile update are one atomic local commit. A
    failed commit moves neither. Delivery then replays them as two ordered
    outbox operations.
  - Before computing, the store waits until no other local mutation is
    pending, so a goals save in flight is never overwritten with a stale
    profile.
- **Notice:** when the daily kcal goal changes in live mode, a short snack
  names the new goal. This is typically 50 kcal every 3–4 kg. If the same
  commit just raised the once-per-session "saved here, syncs later" hint,
  the hint stays and the goal notice is skipped.
- **One current weight in the UI:** the plan weight, else the profile weight.
  It drives:
  - the plan card's left (trend) pole, gap and forecast;
  - the weight card's goal progress;
  - BMI.

  The weight card's big number stays the latest weigh-in, and its trend line
  appears only with a plan weight.
- **Labels (2026-10-04):** the owner logged 117 kg and the plan card said
  "Current 119.1". The value was right, the word was not. With a plan weight
  the pole now reads "Trend" and, when the last weigh-in reads differently
  at one decimal, names it underneath ("Last weigh-in 117 kg"). Without a
  plan weight the pole shows the profile weight and keeps "Current".
- **Goals screen:** with a plan weight, the weight row is read-only and shows
  it, because a typed value would immediately be smoothed back. It is titled
  "Weight trend", and its helper names a differing last weigh-in in the same
  words. Its hidden energy fields use the same weight. Without a plan weight
  the row stays editable. Since 2026-10-19 the onboarding weight becomes the
  first weigh-in (see below).

## Correcting weigh-ins (2026-10-19)

Review [2026-10-19](IMPROVEMENT-REVIEW-2026-10-19.md), section 3: a typo
could only be outvoted by later weigh-ins, and the onboarding weight was no
weigh-in.

- **History:** the profile's weight card ("All weigh-ins") and the weigh-in
  sheet ("History", also from Today's weight chip) open all weigh-ins,
  newest first. A row opens the edit sheet: value, day (the 7-day strip,
  swipe for earlier weeks) and time, and "Delete weigh-in".
- **Dated weigh-ins:** the weigh-in sheet takes a day and a time, default
  now, at most a year back and never in the future (a future moment
  becomes now). An edit keeps its exact original moment until the day or
  time is changed.
- **Edit:** `weightUpsert` with the row's id. The plan re-anchors through
  the same path and in the same local commit as a new weigh-in, so a
  corrected typo moves the profile back (`updateWeighIn`).
- **Delete:** `weightDelete`, terminal for the id; the snack's undo restores
  value and moment under a new id. The plan re-anchors in the same commit.
  Known limit: when the deleted weigh-in was the only one the plan rested on,
  there is no plan weight left and the profile keeps the weight it was last
  anchored to; the goals screen's weight row is editable again then. With the
  onboarding weigh-in this needs an account onboarded before 2026-10-19.
- **Lifetime counter:** `lifetime_stats.weight_logs` counts weigh-ins logged
  (`weightInsert`), like `meals_logged`. An edit, a delete and its undo
  neither add nor subtract.
- **Apple Health:** Eatova wrote a sample for each manual weigh-in. An edit
  deletes Eatova's own sample at the old moment (by its UUID, found by
  source and time) and writes the corrected one; a delete removes it, and
  the undo writes it back. A weigh-in imported from a scale has no sample of
  Eatova's: the scale's sample stays as it is (HealthKit lets an app delete
  only its own samples), and nothing is written instead. A deleted import is
  not offered again in the same session; after a restart a reading of the
  last 7 days may be offered once more. Android writes no weight.
- **Rows without an id:** builds before 2026-10-19 cached weigh-ins without
  their row id. Such a row shows "Editable after the next sync" until the
  next server load supplies it.
- **Onboarding weigh-in:** completing the onboarding records the entered
  weight as the first weigh-in, in the same local commit as the profile, so
  the trend and the weekly check start on day one. Only when the server
  answered an empty weight log in this session: an account with weigh-ins,
  or one whose log is unknown offline, gets none. An account completes its
  onboarding once (repeated taps share one completion), so the weigh-in is
  recorded once.

Server side: [20261019110000](../supabase/migrations/20261019110000_weight_log_edit.sql)
adds both kinds to `apply_sync_operation`, a `weight` tombstone family and
the current-state projection; see [durable sync](OFFLINE_SYNC.md#conflict-policy).
The migration goes live before the client that sends the new kinds.

Measured effect (male, 182 cm, light, −0.5 kg/week): the daily goal goes from
2100 kcal at 84 kg to 2000 at 76 kg. The visible correction is the forecast and
the plan card.

## Stage 2: the weekly check

The app estimates the user's actual daily expenditure from logged intake and the
weight trend, MacroFactor style, and proposes to move the daily goal. Nothing
changes without a tap. User decision of 2026-10-03: with confirmation.

### When it appears

- Live mode with a completed onboarding. Manual goals are the user's own.
- The server has answered profile and weight log in this session (the same
  gate as the re-anchoring). A check never runs on cached data alone.
- At least 7 days since the last answered check (`energy_checked_on`).
- The window's step values have been refreshed from the health store once in
  this session (full-day totals). A value pinned before its day ended would
  understate the model. A session that runs into a new day re-reads the day
  that just ended before the check may propose again.
  The trends page's longer backfill (up to six months, 2026-10-19) stores
  every day it finds in one notify and one encrypted cache write, and on
  Android reads only the last 30 days: without `READ_HEALTH_DATA_HISTORY`,
  which Eatova neither declares nor requests, Health Connect answers nothing
  older than 30 days before the first grant.
- Enough data in the **window**: the 21 local days that end yesterday (today
  is not complete yet).
  - At least 14 **logged days**. A day counts when its logged intake reaches
    50 % of the current daily goal, since emptier days are almost certainly
    incomplete. Since 2026-10-19 this is the app's one rule for a complete
    day (`services/complete_day.dart`): the trends averages, Today's day
    strip and the evening reminder use it too. The logging streak keeps its
    own bar of one entry.
  - With a step source (a reading today or any step value in the window),
    a day also needs a step value of its own. Step values are not synced:
    on a new phone, or for days before the permission, a missing value
    would model 0 steps and push the goal up for walking the budget already
    credits.
  - At least 4 weigh-in days, the first and last at least 14 days apart.
- A proposal that would change nothing is not shown. That covers a step that
  rounds to zero, an adjustment already at its cap, and a goal held by the
  floor or the ceiling.

### The estimate

- **Weight change**: a least-squares slope over the last weigh-in of each day
  in the window. Days more than 5 % off the window median are dropped as
  typos.
- **Observed expenditure** = mean intake of the logged days − slope × 7700
  kcal/kg.
- **Modelled expenditure** = maintenance (BMR × PAL plus the current
  adjustment) + mean step kcal of the logged days. The PAL ladder has no
  walking in it, so the steps belong to the model.
- **Difference** = observed − modelled.
  - Under 100 kcal there is no proposal.
  - Below two standard errors of the weight slope (× 7700) there is no
    proposal either. The noise behind that error is at least 0.5 kg per
    weigh-in: with a few weigh-ins the residuals can be tiny by chance,
    while water swings alone move a 3-week slope by more than 100
    kcal/day. Daily weigh-ins need about 280 kcal of difference; sparse
    ones need more.
  - Otherwise the step is the difference rounded to 50 and capped at ±150
    kcal.
  - The adjustment stays within ±500 kcal in total.
- The adjustment (`energy_adjustment_kcal`) shifts maintenance. The calculator
  adds it to BMR × PAL, so goal, macros, forecast and pace follow, while the
  floor and ceiling stay as they are. Manual mode keeps its own goals and only
  uses the adjusted maintenance for pace and forecast.

### Answering

- **Adjust**: adds the step to the CURRENT adjustment (another device may
  have moved it since), records today as `energy_checked_on`, recomputes the
  live goals and confirms with a notice. If the same commit just raised the
  once-per-session "syncs later" hint, the hint wins.
- **Not now**: records today only. The next check comes at the earliest in 7
  days.
- The goals screen shows a non-zero adjustment in live mode and can reset it
  to 0, which takes effect on save.

### Other readers

The Coach's seven-day block (2026-10-18) reads the same weight change through
`EnergyCheck.weightRate`: same window, typo filter and minimum of weigh-ins.
Its ± band is the two-standard-error noise guard, in kg/week. Without the
minimum the block says so instead of naming a rate. Trends (2026-10-22)
fits the same line over its own range (`EnergyCheck.weightLine`), see
below.

### Progress on Today (2026-10-18)

- Under the macros, today only: a weight chip with the latest weigh-in, or
  "Log weight" without one. It opens the profile's weigh-in sheet.
- Beside it, `EnergyCheck.progress` on the same inputs, rules and source
  gate as the proposal: "Weekly check in 5 days at the earliest · 2 more
  complete days · 2 more weigh-ins". The day assumes that every day from
  today on gets logged and that the weigh-ins fall on the days they are
  needed; weigh-ins still to come are assumed to be no typos. After an
  answer it names the end of the 7-day pause.
- With enough data and no proposal: "Weekly check active · enough data". It
  does not claim that the goal fits, since a cap or the floor can hold back a
  step the data asks for.
- While the proposal card shows, the card speaks for the check and the line
  is hidden. On cached data alone there is neither.

### Explained, and the week's result (2026-10-19)

- The progress line is a button (info glyph). It opens a short explainer:
  what the check compares (the last 21 days of entries against the weight
  trend), what it needs (14 complete days, 4 weigh-ins 14 days apart,
  weighing 2–3 times a week), and how far it may move the goal (150 kcal at
  a time, ±500 in total, nothing without "Adjust"). The numbers come from
  `EnergyCheck`'s constants. Two ways out: log weight, open the food log.
- `EnergyCheck.estimate` returns the arithmetic behind `evaluate` with or
  without a proposal: observed and modelled expenditure, the measured
  weekly rate, the plan's pace (`KcalTargets.effectiveWeeklyRateKg`), the
  counts, and whether the difference stayed inside the noise. `evaluate` is
  its proposal. Nothing new is modelled.
- Once a week, on Mondays (`EnergyCheck.resultWeekday`), when the check
  estimates on server data and proposes nothing, Today shows a quiet result
  card instead of the line: "Verbrauch ≈ 2.350 kcal am Tag", then "Dein
  Tagesziel von 2.100 kcal passt dazu." (inside the noise) or "… bleibt bei
  … kcal: Es liegt schon an einer Grenze." (a cap, the floor or the ceiling
  holds it), and "Gemessen: −0,4 kg/Woche · Plan: −0,5 kg/Woche". It has no
  answer buttons and changes nothing; it links to the explainer. Monday is a
  stateless choice: nothing is stored, so a week without opening the app on
  Monday shows no card, while the line stays tappable every day. Since
  2026-10-22 "Verstanden" hides it for seven days, per account and on this
  device only (encrypted cache slot `weekly_result_seen`).
- The onboarding plan's footnote now says that a weekly check compares the
  estimate with the entries and weigh-ins, and to weigh in 2–3 times a
  week.

### Storage and rollout

- `profiles.energy_adjustment_kcal smallint not null default 0`, with a check
  of ±1000.
- `profiles.energy_checked_on date`, nullable.
- Both are written only through `apply_sync_operation` (SECURITY DEFINER), with
  no column grants. A profile save whose payload lacks the keys (an older
  build) keeps the stored values instead of resetting them.
- The live migration goes first and the client second. The client selects the
  new columns on load.

## Reached target, one weight rate, Trends (2026-10-22)

Review [2026-10-22](IMPROVEMENT-REVIEW-2026-10-22.md), sections 1 and 3.

- **Holding a reached target.** Reaching the target switched the plan to
  maintain on the rounded trend, so a trend near X.5 kg flipped the daily
  goal by about 500 kcal from day to day. Now the hold starts when the
  rounded trend crosses into the target (`holdsReachedTarget`) and ends only
  when it runs 1.5 kg back past it (rounded: 2 kg, `targetHoldReleaseKg`).
  - No migration: the hold is derived from the synced weight log, so every
    device on this build agrees. The store's `profile` getter carries it as
    the transient `UserProfile.targetHold` and recomputes live goals when it
    changes. It is never serialized.
  - The boot heal is measured on that profile, so a held row is not written
    back on every boot.
  - Limits: there is no goal history, so a series that starts at or past the
    target holds nothing, and a target set inside the band of an earlier
    crossing holds at once. An older build on another device heals the row
    with the plain rule; this build derives the hold again on its next read.
- **Today asks once:** "Ziel erreicht – halten oder neues Ziel?" while the
  plan holds a target the user did not choose to hold. "Halten" stores
  maintain as the goal; "Neues Ziel" opens the goals page. The weigh-in that
  reaches the target says so in its snack.
- **One weight rate.** Trends used the first and last raw weigh-in of its
  range. It now fits the weekly check's line over the range (same typo
  filter, minimum of 4 weigh-in days 14 days apart, least squares), draws it
  through the weigh-ins and labels it "Gemessenes Tempo" with the shared pace
  label. Over 90 or 182 days with more than 5 % change, the check's median
  filter keeps the middle weigh-ins of the range.
- **Trends offline.** Up to 35 days (the store's meal window) the page shows
  calories and macros from this device's days with a short note and a retry.
  Longer ranges keep the error card.
- Today's 7-day trends card opens the page on 7 days.
- **Not built:** judging past days against the goal of their day needs a goal
  history, i.e. a migration (a per-day goal table or columns, plus a sync
  operation kind).
