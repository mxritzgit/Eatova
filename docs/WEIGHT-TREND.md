# Weight trend and re-anchoring

Status: stage 1 implemented on 2026-10-03; stage 2 planned. Background:
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

## Stage 2 (planned): adaptive weekly check

The user wants the app to estimate actual expenditure from logged intake and
the weight trend, MacroFactor style, and to adjust the goal, but only with a
confirmation. The planned rules:

- It runs at the earliest after 2–3 weeks with enough logged days and
  weigh-ins.
- It proposes at most ±150 kcal per check and never goes below the
  sex-specific floor.
- It excludes manual mode.

This needs a persisted adjustment on the profile (migration) and its own PR.
