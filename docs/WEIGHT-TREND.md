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
  - Each local day counts once, with its **last** weigh-in. There is no
    delete, so a later entry corrects an earlier one, for example a typo.
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
- **Re-anchoring:** after a weigh-in (manual or Apple Health import) and after
  the boot load, the store sets `profile.weightKg` to the rounded plan weight
  when they differ.
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
  - the plan card's "current" pole, gap and forecast;
  - the weight card's goal progress;
  - BMI.

  The weight card's big number stays the latest weigh-in, and its trend line
  appears only with a plan weight.
- **Goals screen:** with a plan weight, the weight row is read-only and shows
  it, because a typed value would immediately be smoothed back. Its hidden
  energy fields use the same weight. Without a plan weight the row stays
  editable. Onboarding does not create a weigh-in.

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
  understate the model.
- Enough data in the **window**: the 21 local days that end yesterday (today
  is not complete yet).
  - At least 14 **logged days**. A day counts when its logged intake reaches
    50 % of the current daily goal, since emptier days are almost certainly
    incomplete.
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

### Storage and rollout

- `profiles.energy_adjustment_kcal smallint not null default 0`, with a check
  of ±1000.
- `profiles.energy_checked_on date`, nullable.
- Both are written only through `apply_sync_operation` (SECURITY DEFINER), with
  no column grants. A profile save whose payload lacks the keys (an older
  build) keeps the stored values instead of resetting them.
- The live migration goes first and the client second. The client selects the
  new columns on load.
