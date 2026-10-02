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
  - Several weigh-ins on one local day count as one, their mean.
  - The smoothing is 10 % per day and time-aware: a day `Δ` days after the
    previous one moves the trend by `1 − 0.9^Δ`. A weekly weigh-in therefore
    counts about 52 %, and a weigh-in after a month almost fully.
  - A day more than 5 % away from the trend reseeds it. That covers a
    correction or a typo, which the next weigh-in fixes, instead of dragging
    the trend for weeks. Normal daily swings (1–2 kg of water) stay smoothed.
  - Without weigh-ins there is no trend, and the profile weight applies as
    before.
- **Re-anchoring:** after a weigh-in (manual or Apple Health import) and after
  the boot load, the store sets `profile.weightKg` to the rounded trend when
  they differ. This needs a completed onboarding and a value within
  `ProfileLimits`.
  - Live mode recomputes the goals in the same step (`applyLiveGoals`).
  - Manual mode keeps its own goals and only updates the weight.
  - The weigh-in and the profile update are one local commit and travel as
    one outbox batch.
  - Before computing, the store waits until no other local mutation is
    pending, so a goals save in flight is never overwritten with a stale
    profile.
- **Notice:** when the daily kcal goal changes in live mode, a short snack
  names the new goal. This is typically 50 kcal every 3–4 kg.
- **One current weight in the UI:**
  - the plan card's "current" pole shows the trend;
  - the weight card shows the latest weigh-in plus the trend;
  - BMI uses the trend.
- **Goals screen:** with weigh-ins, the weight row is read-only and shows the
  trend, because a typed value would immediately be smoothed back. Without
  weigh-ins it stays editable. Onboarding does not create a weigh-in.

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
