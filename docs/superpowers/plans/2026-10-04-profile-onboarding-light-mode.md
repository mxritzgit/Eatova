# Profile, goals, onboarding and light mode: plan (2026-10-04)

The owner asked for four changes on 2026-10-04 and approved this plan in
advance:
- bring the profile page and the "Profile & Goals" screen up to the current
  design system and make them nicer;
- rethink and redesign the onboarding;
- explain why the plan card shows a different "current" weight than the
  one just logged;
- add a complete light mode.

The light mode comes last, after the other work is merged into the
integration branch. The owner also authorized the merge to main after green
CI.

## Phase 1, in parallel: two workers in their own worktrees

### W1: My Profile and Profile & Goals

- **Bug: two "current" weights.** The plan card's left pole is labelled
  "Current" but shows the smoothed trend (`WeightLog.planWeightKg`,
  docs/WEIGHT-TREND.md stage 1). The weight card shows the last weigh-in.
  For example, the owner logged 117 kg while the plan card said 119.1.
  - The trend stays the plan's weight, since the smoothing is the point of
    stage 1.
  - The UI has to say what it shows: the pole reads "Trend" (de "Trend"),
    with the latest weigh-in as a small caption ("Last weigh-in 117 kg"),
    so the two numbers explain each other.
  - The goals screen's read-only weight row and its texts get the same
    wording.
  - Update docs/WEIGHT-TREND.md.
- **Design.** Both screens move from a form-like list to the dark-redesign
  language used by Today, Food and Training:
  - a calmer header;
  - hero cards with icons;
  - grouped cards with leading icon tiles;
  - value capsules;
  - SoftPillButton and PrimaryActionButton;
  - consistent section labels;
  - no duplicated labels (for example "Reminders" as both the section and
    the row);
  - no lowercase enum text such as "male".

  Every behaviour stays: validation, manual energy mode, the reminder
  switch, save, the discard guard, keys used by tests and flows, and a11y.
- **Files owned:** lib/src/screens/profile_screen.dart,
  lib/src/widgets/profile/*, lib/src/screens/settings/goals_screen.dart,
  settings_plan_hero.dart, settings_pickers.dart, settings_controls.dart
  (only as goals needs; the settings screen and the account sheets also use
  it), plus their tests and capture tests.

### W2: Onboarding

- **Question audit.** For every question, find in the code what it drives:
  - name: the greeting and the Coach;
  - sex, age, height and weight: BMR;
  - activity: PAL;
  - goal, target and pace: the deficit, the forecast and the target BMI
    hint;
  - diet: recipe filtering;
  - the notification opt-in.

  Keep only what changes the plan or the experience. Then order the
  questions from motivation to details: goal first, then body, activity,
  pace, extras, and the plan reveal. Use sensible defaults, one decision per
  screen, big tappable options, back navigation, and optional steps that
  can be skipped. Write the decision table (question → kept/changed/dropped
  → reason) into docs/AUTH-ONBOARDING-DESIGN.md or a new
  docs/ONBOARDING-2026-10-04.md.
- **Design.** Rebuild the steps in the current design system: the
  dark-redesign tokens, AppType, StepFrame and progress, option cards, value
  pickers, PrimaryActionButton, and a rewarding plan summary in the style of
  the Goals hero.
- **Constraints:**
  - same `UserProfile` fields;
  - no migrations;
  - age at least 16;
  - existing persistence and completion lifecycle;
  - text through ARB in de and en.
- **Files owned:** lib/src/screens/onboarding_screen.dart and any new
  lib/src/screens/onboarding/* files, plus their tests and captures.
  Shared design widgets only for additive changes.

## Phase 2, after integrating phase 1: light mode, three workers

The light palette `AppTokens.light` has been dormant since the dark
redesign (2026-09-28, `kDarkOnly`). Its values are from August and no longer
match the redesign. The structure stays; only the colours change.

- **L1 Foundation** (runs first):
  - a new `AppTokens.light` that mirrors every dark token's role, with AA
    contrast and the same accent family;
  - `buildEatovaTheme` light;
  - system UI overlay and status bar per brightness;
  - remove `kDarkOnly`; the Settings theme row is back (System, Light,
    Dark; default System);
  - shared design widgets (lib/src/widgets/design, lib/src/widgets/common)
    free of dark-only assumptions;
  - theme tests (app_tokens_test, hell_modus_audit_test,
    theme_mode_app_wiring_test) updated to the live switch;
  - a light variant in the capture harness.
- **L2 and L3 screens** (in parallel on top of L1). Remove hardcoded colors,
  fixed `Brightness.dark` assumptions, dark-only gradients and glows and
  images, and dark-only shadows. Use tokens, verify with light-mode
  captures, and fix contrast.
  - L2: Today, Food (lib/src/widgets/kcal, scan screens), profile, goals,
    settings, onboarding and auth.
  - L3: Coach, Recipes and meal plan, Training, and the remaining sheets.

## Integration and delivery

Each worker commits in its own worktree; the orchestrator reads every diff
and cherry-picks onto `feat/profile-onboarding-light-2026-10-04`. Gates:
- `flutter analyze --fatal-infos --fatal-warnings`;
- the full suite with coverage of at least 88 %;
- Deno tests if functions changed (not expected);
- a visual check of the captures in dark and light.

Then a PR, the PR gate, the merge, cleanup, and updates to the handoff and
memory.
