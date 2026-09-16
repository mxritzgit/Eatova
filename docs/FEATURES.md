# Current features and platform support

Base source review: **2026-09-14**, main through PR #88; authentication and
onboarding updated **2026-09-16**. This is the current capability inventory.
Dated reviews describe what was present at their own checkpoint.

## What is available

| Area / entry point | Implemented behavior | Source |
| --- | --- | --- |
| Account entry | Email/password and Google sign-in, code confirmation/recovery, six-step profile setup with editable summary | [Entry and onboarding](AUTH-ONBOARDING-DESIGN.md) |
| Today | Calorie balance, macro bars, streak, selected-day steps, quick meal logging, Profile and Settings | [Today](../lib/src/screens/today/today_screen.dart) |
| Food | Breakfast/lunch/dinner/snack diary, meal editing and deletion, date calendar, favorites, history trends | [App shell](../lib/src/app/eatova_home_page.dart), [Food design](FOOD-DESIGN.md) |
| Meal entry | Camera or gallery with optional context; barcode; product search; manual per-100-g values and a chosen portion; shared meal-slot picker | [Entry contracts](FOOD-ENTRY-POLISH-2026-09-14.md) |
| Recipes | Browse catalog; create, edit or delete own/adopted recipes; photo, preparation, structured ingredients, fractional servings; add to selected diary date | [Recipes](../lib/src/screens/recipes/recipes_screen.dart) |
| Meal Plan | Weekly date/slot planning with recipe snapshots and servings; explicit consumption adds to diary without double-counting retries | [Plan screen](../lib/src/screens/recipes/meal_plan_screen.dart), [store](../lib/src/app/home_store_meal_plan.dart) |
| Shopping List | Weekly ingredient aggregation and durable checked state; compatible structured quantities combine, free-text lines remain independent | [Plan and shopping screen](../lib/src/screens/recipes/meal_plan_screen.dart) |
| Training plans | Multiple workouts, plan selection/editing, exercise lists, repetition/timed sets and rest | [Training](../lib/src/screens/training/training_screen.dart) |
| Workout player | Pause/resume, reset, 10-second rewind/forward, set/exercise navigation, actual values and local paused recovery | [Session controller](../lib/src/services/training_session_controller.dart) |
| Training history | Completed immutable sessions with actual values, previous results/Last time and deletion | [History](../lib/src/screens/training/training_history_screen.dart) |
| Coach | Chat over SSE with full server-side approval before text is released; sessions, attached image, nutrition context and quota | [Coach service](../lib/src/services/coach_chat_service.dart) |
| Coach recipes | `/recipe` proposal with recipe text and a generated picture; explicit confirmation saves the recipe | [Recipe flow](../lib/src/screens/coach/coach_recipe.dart) |
| Coach training | `/plan` brief with goal/experience/equipment/frequency/duration/constraints; optional selected-plan discussion or adaptation; explicit adoption | [Training brief](../lib/src/screens/coach/coach_training_brief.dart) |
| Profile | Body data, daily goals, weight chart, health connection and lifetime statistics | [Profile](../lib/src/screens/profile_screen.dart) |
| Settings | Language, theme, account changes, JSON export, sign-out and verified account deletion | [Settings](../lib/src/screens/settings/settings_screen.dart) |
| Reminders | Local evening streak-at-risk notification, scheduled ahead; no server push channel | [Notifications](../lib/src/services/notification_service.dart) |

## Platform matrix

| Capability | Android | iOS |
| --- | --- | --- |
| App target | API 26+ | iOS 15+ |
| Health steps | Health Connect, read-only, foreground refresh | HealthKit read |
| Health weight history / write-back | Not implemented | Read history; write a recorded weigh-in with permission |
| Health availability | Explicit unsupported/update/permission/no-data states | Explicit permission and read-evidence states |
| Coach dictation | Not exposed | Native speech-to-text |
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
- Coach recipe/plan output is a proposal. Opening a card or receiving a reply
  does not silently adopt it.
- Initial setup groups personal details, body data, activity, goals and an
  optional dietary preference into six screens, ending in an editable plan.
  Completing it does not request notification permission; reminders require
  the existing explicit opt-in. See [entry and onboarding](AUTH-ONBOARDING-DESIGN.md).
- Completed workouts preserve a snapshot and actual values. Editing a source
  plan does not rewrite history. A paused checkpoint is local to the device;
  it is not a cross-device live workout session.
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
- JSON export is available through **Today → Settings → Export data**. Copying
  the JSON is wired; native file sharing has a prepared callback but no app
  wiring. It is not an import/restore feature. Unreadable or capped sections are
  identified, and non-diary sections have a 10,000-row client limit (a server
  cap may be lower). [Export source](../lib/src/services/data_export.dart).
- Theme/language apply to app-owned UI. Stored user text, previous AI replies
  and independently configured auth email templates are not retroactively
  translated by changing the picker.
- Source/CI coverage does not establish a new App Store/Play release or a fresh
  physical-device Health Connect test. Dated delivery records state what was
  actually deployed or installed.

## Current visual contracts

Today uses the pastel Balance Duo dashboard; Food uses the Thumb First diary;
Recipes uses Spotlight; Training uses the dark Nachtstudio direction. A shared
original icon family connects Today, meal slots and navigation. Entry sheets,
calendar, account pages and headers follow the subsequent polish work.

The [design guide index](README.md#design-contracts-and-previews) links to the
current contracts and actual Flutter previews.
