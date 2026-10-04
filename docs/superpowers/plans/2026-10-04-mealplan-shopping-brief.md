# Meal plan, shopping list and training brief: plan (2026-10-04)

The owner asked for two things on 2026-10-04. The merge to main after CI is
authorized.

1. Significantly improve the meal plan and shopping list design. The owner
   finds it too generic ("AI slop") and still in the older style.
2. Make the training tab's "Ask Coach" → "Your training brief" simpler and
   nicer, so it is clear what to press. Plan creation should feel good.

Current state, from the captures in build/dark-redesign/ (meal-plan-*,
training-editors-brief-*):
- **Meal plan:**
  - The hero card uses generic copy ("Your week, thoughtfully planned").
  - The tab switch has an underlined label.
  - The day headers have large round "+" buttons.
  - "Eaten today" is a full-width pill on every card.
- **Shopping list:**
  - A slogan hero ("Everything for your week").
  - Free-text recipes show raw "- " lines.
  - Weighed items are loose cards.
- **Brief:**
  - A long form with a three-sentence privacy intro.
  - Intent chips without explanation.
  - The goal is a bare text field.
  - Seven unlabeled number chips.
  - A paragraph of fine print.
  - The only action is at the very bottom.

## Rules for both workers

- **Same design language** as the newest screens: Today, Training, Settings,
  Profile & Goals, Onboarding, and the redesigned sheets.
  - Use tokens only (`context.t`), AppType, SlotIconTile and icon tiles,
    SoftPillButton, PrimaryActionButton, FilterChipPill (44 px), AppToggle
    and HeaderIconButton.
  - Inputs are borderless soft fills.
  - No generic marketing copy; texts say what is true and useful.
- **Both modes:** light and dark must look intentional. Render with
  `--dart-define=DARK_REDESIGN_CAPTURE=true` and with
  `--dart-define=DESIGN_CAPTURE_BRIGHTNESS=light`.
- **Behaviour stays.** Keep the data, persistence, keys used by tests and
  flows, semantics, and 2x text at 320 px. Shopping check ids stay unchanged
  (they are persisted server-side). No migrations and no function changes.
- **Text** goes through lib/l10n/app_de.arb and app_en.arb; remove keys that
  are no longer used.
- **Tests:** every behaviour change gets a test that fails on the old
  behaviour, and the capture suites are updated.

## W-A: Meal plan and shopping list

Files: lib/src/screens/recipes/meal_plan_screen.dart and meal_plan_editor.dart
(only if needed), with their tests and test/design/meal_plan_capture_test.dart.

- **Header:** Week and Shopping as the app's segmented control, not an
  underlined label. The week navigation is compact.
- **Week overview:** a 7-day strip. Each day shows a dot or count of planned
  meals and today is marked; tapping a day jumps to it. One factual summary
  line ("4 meals planned · 1 eaten") replaces the slogan hero. "Only Eaten
  today adds to your diary" becomes a quiet footnote.
- **Day sections:** a compact header with weekday, date and a Today badge.
- **Meals:** compact rows with the slot icon tile, a photo thumbnail, the name
  and "Slot · servings · kcal". The trailing actions are a small eaten
  toggle and the menu.
- **Empty day:** a soft "Plan a meal" row instead of the large "+" circle.
  Days outside the planning window stay disabled.
- **Shopping list:**
  - A compact progress header (count plus bar or ring) without a slogan.
  - Weighed items in one grouped card: round check, name, amount capsule.
    Checked items dim in place, so nothing jumps under the finger.
  - Free-text recipes as cards: thumbnail, name, servings, ingredient lines
    without "- " markers. The recipe-level check stays as it is.
  - A designed empty state with a way to plan meals.

## W-B: Training brief

Files: lib/src/screens/coach/coach_training_brief.dart (and the plan preview in
it), with their tests and the brief shots in
test/design/training_editors_capture_test.dart and
coach_cards_capture_test.dart.

- **Title:** a clear title and one short line about what happens.
- **Privacy:** the note becomes a compact info row ("Only these details and
  the selected plan are shared").
- **Intent:** big option cards with an icon and a one-line description
  (create, adapt, discuss), not bare chips.
- **Selected plan:** a compact row that can expand to the preview.
- **Goal:** quick option chips for common goals plus an optional custom
  text.
- **Fields:** experience and equipment as labelled segmented choices with
  icons. Sessions per week and minutes per session as compact choices with
  units.
- **Bottom bar:** a sticky bar with a one-line summary ("3× a week · 30 min ·
  Dumbbells") and the PrimaryActionButton, whose label depends on the
  intent. The quota note is small ("uses 1 Coach request").
- **Data model:** `CoachTrainingContext`, validation, limits and the
  confirmation rule are unchanged. A proposal never writes before the user
  confirms.

## Integration

The orchestrator reads both diffs and the captures in both modes, then
cherry-picks onto `feat/mealplan-shopping-brief-2026-10-04`. Gates:
- analyze with fatal infos and warnings;
- the full suite with coverage of at least 88 %.

Then a PR, the PR gate, the merge, cleanup, and updates to the handoff and
memory.
