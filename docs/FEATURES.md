# Current features and platform support

Base source review: **2026-09-14**, main through PR #88; authentication and
onboarding updated **2026-09-16**; Today, Settings and visual contracts
updated **2026-10-01** for the dark redesign (PR #118); Training, Coach `/log`
and dictation updated **2026-10-03** ([design](superpowers/specs/2026-10-03-training-flow-and-coach-log-design.md));
meal description by text or voice added **2026-10-10** ([contract](MEAL-DESCRIBE.md)).
This is the current capability inventory.
Dated reviews describe what was present at their own checkpoint.

## What is available

| Area / entry point | Implemented behavior | Source |
| --- | --- | --- |
| Account entry | Email/password and Google sign-in, code confirmation/recovery, goal-first profile setup (six questions, eight with a weight goal) ending in an editable plan | [Entry](AUTH-ONBOARDING-DESIGN.md), [onboarding](ONBOARDING-2026-10-04.md) |
| Today | Seven-day strip, calorie balance with activity credit, macro tiles, streak, recipe pick for the next open meal, per-slot add, steps and next workout ("In progress · Resume" while a workout is saved); avatar to Profile | [Today](../lib/src/screens/today/today_screen.dart), [Today design](TODAY-DESIGN.md) |
| Food | Breakfast/lunch/dinner/snack diary, meal editing and deletion, date calendar, favorites, history trends | [App shell](../lib/src/app/eatova_home_page.dart), [Food design](FOOD-DESIGN.md) |
| Meal entry | Camera or gallery with optional context; barcode; product search; manual per-100-g values and a chosen portion; shared meal-slot picker | [Entry contracts](FOOD-ENTRY-POLISH-2026-09-14.md) |
| Meal description | "Describe" in the add sheet: a typed or dictated sentence becomes a draft with one line per food. The AI splits the sentence and estimates amounts; each line uses a matching favorite or database product when one fits and the AI estimate otherwise, marked as such. Lines can switch candidate, change grams or be removed; nothing is logged before Add. Counts as one meal scan | [Contract](MEAL-DESCRIBE.md), [sheet](../lib/src/widgets/kcal/meal_describe_sheet.dart) |
| Recipes | Browse catalog; create, edit or delete own/adopted recipes; photo, preparation, structured ingredients, fractional servings; add to selected diary date | [Recipes](../lib/src/screens/recipes/recipes_screen.dart) |
| Meal Plan | Weekly date/slot planning with recipe snapshots and servings; explicit consumption adds to diary without double-counting retries | [Plan screen](../lib/src/screens/recipes/meal_plan_screen.dart), [store](../lib/src/app/home_store_meal_plan.dart) |
| Shopping List | Weekly ingredient aggregation and durable checked state; compatible structured quantities combine, free-text lines remain independent | [Plan and shopping screen](../lib/src/screens/recipes/meal_plan_screen.dart) |
| Training plans | Multiple workouts, plan selection/editing, exercise lists, repetition/timed sets and rest | [Training](../lib/src/screens/training/training_screen.dart) |
| Workout player | List of exercise cards with one tap per set (✓; timed sets ▶ with a 3 s lead and "Done early"); weights carry forward within an exercise or come from Last time; undo, skip set/exercise, complete the rest as planned; rests and timed sets keep running while the phone is locked; one generic rest alert per phase, whose tap reopens the workout; finish sheet (save the done sets, log the rest as shown, or discard); local recovery | [Player](../lib/src/screens/training/training_player_screen.dart), [Training design](TRAINING-DESIGN.md#workout-player-list-2026-10-03) |
| Training log | "Log workout" for a free workout (today, yesterday or up to 30 days back, optional duration, exercises with sets or a time, note) and "Log as done" for the plan's shown workout; nothing is written before Add | [Log editor](../lib/src/screens/training/training_log_editor.dart) |
| Training history | Completed immutable sessions with actual values, previous results/Last time and deletion | [History](../lib/src/screens/training/training_history_screen.dart) |
| Coach | Chat over SSE with full server-side approval before text is released; sessions, attached image, nutrition context and quota | [Coach service](../lib/src/services/coach_chat_service.dart) |
| Coach recipes | `/recipe` proposal with recipe text and a generated picture; explicit confirmation saves the recipe | [Recipe flow](../lib/src/screens/coach/coach_recipe.dart) |
| Coach training | `/plan` brief with goal/experience/equipment/frequency/duration/constraints; optional selected-plan discussion or adaptation; explicit adoption | [Training brief](../lib/src/screens/coach/coach_training_brief.dart) |
| Coach workout log | `/log` (typed, dictated or from Training's "Tell the Coach instead") turns a described finished workout into a draft card; one of the daily Coach requests. "Add to history" opens the log editor prefilled, and its Add is the confirmation; the card then reads Added or Removed from history | [Log card](../lib/src/screens/coach/coach_workout_log.dart) |
| Profile | Body data, daily goals, weight chart with trend, health connection and lifetime statistics; weigh-ins re-anchor the profile weight and live goals; a weekly check on Today proposes a calibrated calorie goal from logged intake and the weight trend, applied only after confirmation ([weight trend](WEIGHT-TREND.md)) | [Profile](../lib/src/screens/profile_screen.dart) |
| Settings | Appearance (System, Light, Dark) and language, account changes, JSON export, sign-out and verified account deletion | [Settings](../lib/src/screens/settings/settings_screen.dart) |
| Reminders | Local evening streak-at-risk notification, scheduled ahead; no server push channel | [Notifications](../lib/src/services/notification_service.dart) |

## Platform matrix

| Capability | Android | iOS |
| --- | --- | --- |
| App target | API 26+ | iOS 15+ |
| Health steps | Health Connect, read-only, foreground refresh | HealthKit read |
| Health weight history / write-back | Not implemented | Read history; write a recorded weigh-in with permission |
| Health availability | Explicit unsupported/update/permission/no-data states | Explicit permission and read-evidence states |
| Coach dictation | Not exposed | Apple speech recognition: text appears while speaking and is added to the draft; German/English switch while listening; on-device where Apple offers it |
| Meal description dictation | The phone's speech recognition app opens as a system dialog (German/English chosen first); Eatova holds no microphone permission; the text arrives when the dialog closes | Apple speech recognition with food vocabulary; text appears while speaking |
| Rest alerts | Local notification; may arrive late (inexact scheduling) | Local notification; a Focus can silence it |
| Google sign-in | Native Credential Manager path, web fallback | Native Google SDK path, web fallback |
| Localization | German / English including auth | German / English including auth |
| Recipe pictures | Device-local | Device-local |

Health availability is independent of the app's minimum OS version. Permission
and an installed provider do not prove that step records exist. The app keeps
these states distinct. Sources: [platform factory](../lib/src/services/platform_health_service.dart),
[Android service](../lib/src/services/android_health_service.dart),
[Apple service](../lib/src/services/apple_health_service.dart).

## Data and interaction contracts

- Planning a meal does not count it as eaten. Consumption is an explicit,
  idempotent operation.
- Structured recipe nutrition scales with the saved ingredients and servings.
  Without a known cooked mass, the recipe remains portion-based; the app does
  not invent a grams-per-portion value. Free-text ingredients are not a complete
  nutrition database.
- Coach recipe/plan/log output is a proposal. Opening a card or receiving a
  reply does not silently adopt it; a `/log` workout enters the history only
  through the log editor's Add.
- Initial setup asks the goal first, then personal details, body data and
  activity; target weight and pace only for a weight goal; and an optional
  dietary preference, ending in an editable plan. Completing it does not
  request notification permission; reminders require the existing explicit
  opt-in. See [onboarding](ONBOARDING-2026-10-04.md).
- Completed workouts preserve a snapshot and actual values. Editing a source
  plan does not rewrite history. A paused checkpoint is local to the device;
  it is not a cross-device live workout session.
- A logged workout is a history entry like a played one. A free log gets its
  own `log_` plan; a log of a plan's workout is refused while a workout is
  saved, so one session is never counted twice.
- Cache/outbox data is account-scoped and encrypted. Offline changes reconcile
  when service is available; AI generation and uncached remote search require
  connectivity. Recipe picture bytes are not part of server sync or JSON export.

See [core feature implementation](CORE-FEATURES-IMPLEMENTATION-2026-09-10.md)
and [Backend](BACKEND.md) for persistence details.

## Known boundaries

- Web and desktop are not application targets.
- Water, caffeine, sleep and habit logging from early versions are no longer
  active features. Legacy lifetime fields may still exist for old accounts;
  current training history is a separate implemented feature.
- The login UI offers email/password and Google. The repository's Apple OAuth
  enum is not an exposed Sign in with Apple product flow.
- Dietary preference can be chosen during onboarding; the current Profile and
  Settings screens do not expose a later diet editor.
- JSON export is available through **Today → avatar (Profile) → gear
  (Settings) → Export data**. Copying the JSON is wired; native file sharing has a prepared callback but no app
  wiring. It is not an import/restore feature. Unreadable or capped sections are
  identified. Diary, recipes and recipe history paginate; other sections have a
  10,000-row client limit (a server cap may be lower).
  [Export source](../lib/src/services/data_export.dart).
- Dictation hears one language at a time (German or English); a mix of both
  in one recording is not transcribed reliably. Apple ends a server-based
  recording after about a minute; the text so far stays.
- Theme/language apply to app-owned UI. Stored user text, previous AI replies
  and independently configured auth email templates are not retroactively
  translated by changing the picker.
- Source/CI coverage does not establish a new App Store/Play release or a fresh
  physical-device Health Connect test. Dated delivery records state what was
  actually deployed or installed.

## Current visual contracts

Since the dark redesign (2026-09-28, PR #118) the app uses Figtree for UI
text, Bricolage Grotesque for display text and a floating glass tab bar.
Today, Food, Recipes, Training and Coach have the redesigned tab roots; the
recipe details, meal plan, shopping list, Training library/editor/player,
entry sheets, calendar, account pages and auth keep their earlier structure
on the shared tokens. Since 2026-10-04 a light palette mirrors every dark
token role and the app follows the display mode (System, Light, Dark).

The [design guide index](README.md#design-contracts-and-previews) links to the
current contracts and actual Flutter previews.
