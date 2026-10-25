# Current features and platform support

Base source review: **2026-09-14**, main through PR #88; authentication and
onboarding updated **2026-09-16**; Today, Settings and visual contracts
updated **2026-10-01** for the dark redesign (PR #118); Training, Coach `/log`
and dictation updated **2026-10-03** ([design](superpowers/specs/2026-10-03-training-flow-and-coach-log-design.md));
meal description by text or voice added **2026-10-10** ([contract](MEAL-DESCRIBE.md));
the shopping list became one weekly receipt **2026-10-11**; logging,
reminders, the Coach context and food preferences followed **2026-10-18**
([review](IMPROVEMENT-REVIEW-2026-10-18.md)), and the same day a trends page
with steps, weight and training over up to six months. AI consent, answer
reports, correctable weigh-ins, avoided foods in recipe suggestions and one
rule for a complete day followed **2026-10-20**
([review](IMPROVEMENT-REVIEW-2026-10-19.md)); corrections after logging,
reminder targets, app-icon shortcuts, a reached-target hold, the scale
import and Coach `/meal` followed **2026-10-22**
([review](IMPROVEMENT-REVIEW-2026-10-22.md)); Free and Premium with their
daily limits, the paywall after a fresh onboarding, the Profile's "Abo"
section and the upgrade hints followed **2026-10-25** ([contract](PREMIUM.md);
the store products are still open), and the same day the shared Free AI pool
with lower Free limits ([abuse protection](PREMIUM.md#7-abuse-protection), not
live yet), then redesigned decision cards, buttons, paywall and Abo card,
and one account per mailbox ([backend](BACKEND.md#one-account-per-mailbox),
not live yet).
This is the current capability inventory.
Dated reviews describe what was present at their own checkpoint.

## What is available

| Area / entry point | Implemented behavior | Source |
| --- | --- | --- |
| Account entry | Email/password and Google sign-in, code confirmation/recovery, goal-first profile setup (six questions, eight with a weight goal) ending in an editable plan; the onboarding header offers sign-out; a fresh onboarding ends once on the Premium screen, where "Weiter mit Free" is as large as the purchase button; one account per mailbox (server rule not live yet): Gmail spellings with or without dots, `googlemail.com` and a `+` tag count as one address, a second spelling gets the neutral sign-in hint (plus a sentence on spellings for Gmail or `+` input), and a Google sign-in in another spelling is told to sign in the way the account was registered | [Entry](AUTH-ONBOARDING-DESIGN.md), [onboarding](ONBOARDING-2026-10-04.md), [Premium](PREMIUM.md) |
| Today | Seven-day strip, calorie balance with activity credit, macro tiles, streak, recipe pick for the next open meal, per-slot add, steps and next workout ("In progress · Resume" while a workout is saved); a weight chip with the latest weigh-in and the weekly check's progress ("in 5 days at the earliest · 2 more weigh-ins"); a one-time reminder offer from the evening of the first logged day; a trends card with the averages of the last seven days (calories, protein, steps) that opens the trends page; a dot on complete days in the strip; before the first entry, a hint when yesterday is empty and filling it keeps the streak; the weekly-check line opens an explainer, and on Mondays a result card shows the burn estimate, whether the goal fits and the weight rate against the plan ("Verstanden" hides it until next week, "Ask the coach" prepares a question); a macro tile reads "≥48" with a hint line while entries lack macros; once the weight trend reaches the target, a card asks "hold or new goal?"; the trends card opens the page on 7 days; an Apple Health or Health Connect card asks per account before the health source is read, and once asks whether new scale weigh-ins should be imported automatically; avatar to Profile | [Today](../lib/src/screens/today/today_screen.dart), [Today design](TODAY-DESIGN.md) |
| Food | Breakfast/lunch/dinner/snack diary, meal editing and deletion, date calendar, favorites, a trends button in the header (the day card opens the page too); "Repeat yesterday" in an empty slot and "Copy to…" in the edit sheet (offline, with undo, recents unchanged); after logging, an entry without a weight changes its servings in half steps, a manual entry its values and name ("Change values"), an AI entry its name; times follow the phone's 12/24-hour setting; P/C/F lines read "≥48 g" for a sum with unknown entries and "–" when nothing is known | [App shell](../lib/src/app/eatova_home_page.dart), [Food design](FOOD-DESIGN.md) |
| Meal entry | Camera or gallery with optional context; barcode (GTIN-13; older 12-digit favorites still match); search shows "Your foods" first (favorites, up to 30 recents, the diary's 35-day window, own recipes; offline, umlaut-tolerant), then products; manual per-100-g values and a chosen portion, or a quick entry with total kcal and optional macros (no AI, offline); an unknown barcode saved manually becomes an own product that the next scan finds first; a search without results offers Describe with the search text; a failed or offline search and a failed barcode lookup offer a retry, and a product without nutrition opens the manual form with its name; a logged food never overwrites a pinned favorite of the same name (same barcode, or same name with energy within 20 %); "Edit" on a favorite changes it without logging; shared meal-slot picker | [Entry contracts](FOOD-ENTRY-POLISH-2026-09-14.md) |
| Meal description | "Describe" in the add sheet: a typed or dictated sentence becomes a draft with one line per food. The AI splits the sentence and estimates amounts; each line uses a matching favorite or database product when one fits and the AI estimate otherwise, marked as such. Lines can switch candidate, change grams or be removed; nothing is logged before Add. Counts as one meal scan (photo scan and Describe share the daily AI analyses) | [Contract](MEAL-DESCRIBE.md), [sheet](../lib/src/widgets/kcal/meal_describe_sheet.dart) |
| Trends | 7, 30 or 90 days or 6 months: calories per day (from 90 days one bar per week) with the goal line and ±10 % corridor, average and goal rate; macro averages and protein-goal days; steps with average, best day and days at goal (missing days are read from Apple Health or Health Connect on open); weight change, first and last weigh-in and the measured pace from the weekly check's own trend line, drawn through the weigh-ins; workouts and their weekly average; offline, up to 35 days of calories and macros come from the device's own days. Averages leave today out and count complete days only (from 50 % of the base goal), naming the days left out; a macro average over entries without that macro reads as a lower bound ("≥140 g"); incomplete days show faded; entries still waiting to sync already count | [Trends](../lib/src/screens/trends_screen.dart), [report](../lib/src/services/trend_report.dart) |
| Recipes | Browse catalog; create, edit or delete own/adopted recipes; photo, preparation, structured ingredients, fractional servings; add to selected diary date; own recipes can join catalog categories; 41 catalog recipes per language with a Snack category (11 added 2026-10-22 without photos; every diet and avoided food keeps a breakfast); today's pick rotates daily among near-equal recipes; avoided foods leave the suggestions (Today pick, For you, Fits your goal) and show a "Contains …" chip in browse lists and the detail; share a recipe through the system share sheet; "Add to meal plan" from the detail | [Recipes](../lib/src/screens/recipes/recipes_screen.dart) |
| Meal Plan | Weekly date/slot planning with recipe snapshots and servings; explicit consumption adds to diary without double-counting retries (a past day asks: planned day or today); each day shows its planned kcal against the goal; a row opens its recipe read-only with the ingredients for the planned servings; the picker shows kcal and protein per serving | [Plan screen](../lib/src/screens/recipes/meal_plan_screen.dart), [store](../lib/src/app/home_store_meal_plan.dart) |
| Shopping List | One receipt for the week's uneaten meals: the same ingredient from several meals is one row with the summed amount and a detail line of the days (free-text amounts are read and converted to the planned servings; an amount that cannot be converted keeps the recipe's own, marked). Spices and staples sit in a collapsed "Gewürze & Vorrat" section outside the progress; a recipe without ingredients gets a note. Durable checked state, one check per tap; checks of the earlier per-recipe list carry over; the list is shared through the system share sheet (clipboard as fallback) | [Plan and shopping screen](../lib/src/screens/recipes/meal_plan_screen.dart), [receipt model](../lib/src/models/shopping_receipt.dart) |
| Training plans | Multiple workouts, plan selection/editing, exercise lists, repetition/timed sets and rest | [Training](../lib/src/screens/training/training_screen.dart) |
| Workout player | List of exercise cards with one tap per set (✓; timed sets ▶ with a 3 s lead and "Done early"); weights carry forward within an exercise or come from Last time; undo, skip set/exercise, complete the rest as planned; rests and timed sets keep running while the phone is locked; one generic rest alert per phase, whose tap reopens the workout; finish sheet (save the done sets, log the rest as shown, or discard); local recovery | [Player](../lib/src/screens/training/training_player_screen.dart), [Training design](TRAINING-DESIGN.md#workout-player-list-2026-10-03) |
| Training log | "Log workout" for a free workout (today, yesterday or up to 30 days back, optional duration, exercises with sets or a time, note) and "Log as done" for the plan's shown workout; nothing is written before Add | [Log editor](../lib/src/screens/training/training_log_editor.dart) |
| Training history | Completed immutable sessions with actual values, previous results/Last time and deletion; records by exercise name across plans and logs (bodyweight sets earn reps records), named in the finish sheet and the detail; "History" per exercise shows the best set per workout. The week card counts done sessions ("4 done") | [History](../lib/src/screens/training/training_history_screen.dart) |
| Coach | Chat over SSE with full server-side approval before text is released; sessions, attached image, quota, and a shared nutrition context: today, diet and avoided foods, and a seven-day block (logged days, average kcal against the goal, protein days, the weekly check's weight trend, workouts; unlogged days marked as missing); answers and generated recipe pictures can be reported (reason only, no content); the daily limit comes from the account's plan and its reset shows in local time on the phone's clock; the composer shows the questions left today ("1/2 left today"; at 0 a "Mehr Fragen mit Premium" pill for Free) and the limit is remembered per account between starts, and an upgrade unlocks it at once; the context also names the weekly check's state (without figures) and the planned dishes for today and tomorrow; `/meal` (or the chip) opens the Food tab's Describe sheet prefilled without using a question; Today and Trends prepare questions that stay unsent; a failed load offers a retry; each bubble starts with its speaker for screen readers; with entries lacking protein the start card says "at most … protein left" | [Coach service](../lib/src/services/coach_chat_service.dart) |
| Coach recipes | `/recipe` proposal with recipe text and, for Premium, a generated picture (a Free card shows the full recipe and a quiet "KI-Bild mit Premium" line instead, also after a reload); the profile's diet, avoided foods and dislikes are hard rules of the request (a suspected conflict is flagged; no allergy guarantee); explicit confirmation saves the recipe; the request names the slot and what is still open today; the saved toast's "Open" shows it | [Recipe flow](../lib/src/screens/coach/coach_recipe.dart) |
| Coach training | `/plan` brief with goal/experience/equipment/frequency/duration/constraints; optional selected-plan discussion or adaptation; explicit adoption | [Training brief](../lib/src/screens/coach/coach_training_brief.dart) |
| Coach workout log | `/log` (typed, dictated or from Training's "Tell the Coach instead") turns a described finished workout into a draft card; one of the daily Coach requests. "Add to history" opens the log editor prefilled, and its Add is the confirmation; the card then reads Added or Removed from history | [Log card](../lib/src/screens/coach/coach_workout_log.dart) |
| Profile | Body data, daily goals, weight chart with trend, health connection and lifetime statistics; weigh-ins re-anchor the profile weight and live goals; a weekly check on Today proposes a calibrated calorie goal from logged intake and the weight trend, applied only after confirmation ([weight trend](WEIGHT-TREND.md)); a Nutrition section edits the diet form, 13 avoided foods (common allergens, pork, alcohol) and short dislikes; a weigh-in history edits, deletes (with undo) and dates weigh-ins, and the onboarding weight is the first weigh-in; a reached target holds within 1.5 kg of the weight trend, and the goals page names the hold and its end; a switch imports scale weigh-ins from Apple Health or Health Connect; an "Abo" section before "Verbindungen" shows Free or Premium, the status (renews on, ends on, payment problem, expired), the store, a test-purchase badge, today's usage against the limits and the actions "Mehr mit Premium", "Abo verwalten" and "Käufe wiederherstellen" | [Profile](../lib/src/screens/profile_screen.dart), [Premium](#free-and-premium) |
| Settings | Appearance (System, Light, Dark) and language, reminder (switch and time) and weigh-in reminder, "Open system settings" while notifications are blocked, AI & data (consent status, withdraw, consent again), Feedback & Support (mail with version and build), account changes ("Change password" hidden for Google-only accounts), an "Abo" row (Premium, Free, or the status of a subscription on hold, paused or pending) that opens the Premium screen or the store's subscription management, JSON export (copy or share as a file; device-only recipe photos are named as not included), sign-out with a confirmation that shows the signed-in address and names unsent changes and recipe photos that will be deleted (with photos to lose, the confirm button is red), verified account deletion (with an auto-renewing store subscription it warns that billing continues until cancelled in the store, with "Abo verwalten"; deletion is never blocked) | [Settings](../lib/src/screens/settings/settings_screen.dart) |
| Reminders | Local streak-at-risk notification at a chosen time (default 20:00, per account on the device), scheduled ahead; on a half-logged day it asks about the missing meals; its tap opens the add sheet for the current meal; an opt-in weigh-in reminder Monday and Thursday at 07:30 opens the weigh-in sheet (skipped once weighed that day); a language change re-plans both; app-icon shortcuts Photo, Barcode, Describe and Log weight; no server push channel | [Notifications](../lib/src/services/notification_service.dart) |
| AI consent | Before the first photo scan, description, Coach request or recipe import: one versioned consent per account that names the data, the providers (Anthropic; Google's image model through OpenRouter) and processing in the USA, with an unticked health-data checkbox (Art. 9); logged append-only on the server; a withdrawal in Settings stops every AI request until consent is given again | [Consent sheet](../lib/src/widgets/shared/ai_consent_sheet.dart), [backend](BACKEND.md#ai-consent-and-answer-reports) |

## Free and Premium

Premium is a store subscription that raises the daily AI limits; everything
without AI stays free for everyone: diary, barcode, search, favorites, own
products, recipes, meal plan, shopping list, training, trends (all ranges),
weekly check, reminders, health import and export. The server enforces the
limits per UTC day (reset 00:00 UTC, shown on the phone's clock) and reads
them from its configuration on every request, so they can change without an
app release. The values below are the seeded defaults
([contract](PREMIUM.md), [backend](BACKEND.md#premium-plans-and-store-subscriptions)).

| Per day | Free | Premium |
| --- | --- | --- |
| Coach questions (chat, photo, `/recipe`, `/plan`, `/log`; `/meal` stays free) | 2 | 20 |
| AI meal analyses (photo scan and Describe share one bucket) | 3 | 30 |
| Recipe imports | 1 | 10 |
| Shared AI capacity | 150 provider calls for all Free accounts together | not counted |
| AI picture with a Coach `/recipe` | no (the full recipe stays) | yes |
| Price (store price incl. VAT) | free | 7,99 EUR per month, or 49,99 EUR per year with a 7-day free trial on the yearly plan only |

- **Existing accounts** (created before the migration) keep the earlier
  limits (Coach 5, analyses 100, imports 20, picture included) until the
  operator sets an end date after announcing the new terms at least four
  weeks ahead; with Premium they get the higher value of both. Once that
  date is set, they see a one-time notice on Today with it and the new Free
  limits; an account with Premium sees the regular Premium limits instead,
  without an upgrade offer, and keeps the date and those limits as a note on
  its Profile. The window ended live on 2026-10-25 (only the owner's test
  accounts existed), so no account is legacy now.
- **Free AI at capacity:** when the shared Free capacity is used up, the
  Coach, the meal analysis and the recipe import say calmly that Free AI is
  at capacity and when it is back (local time), with no upgrade offer and
  no locked composer; such a denial uses no day slot, and barcode, search
  and favorites keep working. Premium is not affected.
- **Paywall:** once, as the last step of a fresh onboarding, before Today;
  already onboarded accounts never see it, and it never returns on app start.
  Yearly is preselected; the billed amount is the large number, the monthly
  equivalent and the savings come from the store's prices; directly above
  the purchase button stands what it charges (a trial's first charge date
  and price, otherwise the billed price). Close, system Back and "Weiter mit
  Free" choose Free.
  Restore, Terms and Privacy are on the screen. After a purchase, the
  success view lists the new daily limits.
- **Purchase screen:** the same screen opened from Profile, Settings, the
  Coach, the meal analysis, the recipe import or a locked recipe picture; an
  account that already has Premium, or whose store subscription is on hold,
  paused or pending, sees its status and "Abo verwalten" instead of a
  purchase button (a Google subscription on hold counts for at most 60 days
  past its end, a paused one for 92; then the screen sells again).
- **Profile and Settings:** the "Abo" section and row described above;
  "Abo verwalten" opens the store's subscription management (a purchase from
  the other platform is managed there).
- **At a limit:** an inline message, never a sheet while logging food. It
  names what still works and the reset time; for Free it offers "Mehr mit
  Premium" at most once per feature and UTC day (also across app restarts),
  afterwards only the wait message. Surfaces: the photo-scan and Describe error cards, the recipe
  import, the Coach banner, composer and info sheets. Only once the account
  moved to Premium after the denial does the scan or Describe card say
  "Willkommen bei Premium" and offer "Erneut versuchen" (the recipe import
  its analyze button). With two or fewer analyses left, the scan and
  Describe entry says "Heute noch 2 KI-Analysen".
- **Ending Premium** locks and deletes nothing; saved recipes and their
  on-device pictures stay, and the Free limits apply from the next request.
- Premium belongs to the Eatova account, not to the device or store: bought
  on Android, it counts on iOS for the same account. A store purchase binds
  to one account only; another Eatova account that presents it is told that
  the subscription belongs to a different Eatova account. On the App Store a
  newer purchase on the same Apple ID moves the subscription to the account
  that made it.

## Platform matrix

| Capability | Android | iOS |
| --- | --- | --- |
| App target | API 26+ | iOS 15+ |
| Health steps | Health Connect, read-only, foreground refresh; back to 30 days before the first grant without the history permission; an intro card per account | HealthKit read per account: asked on Today, never read or written before this account connected |
| Health weight history / write-back | After a one-time opt-in, new Health Connect weigh-ins are imported (READ_WEIGHT); no write-back | After a one-time opt-in, new weigh-ins from other sources (a scale) are imported; a recorded weigh-in is written with permission; an edit or delete replaces or removes Eatova's own sample, never a scale's |
| Health availability | Explicit unsupported/update/permission/no-data states | Explicit permission and read-evidence states |
| Coach dictation | Not exposed | Apple speech recognition: text appears while speaking and is added to the draft; German/English switch while listening; on-device where Apple offers it |
| Meal description dictation | The phone's speech recognition app opens as a system dialog (German/English chosen first); Eatova holds no microphone permission; the text arrives when the dialog closes | Apple speech recognition with food vocabulary; text appears while speaking |
| Rest alerts | Local notification; may arrive late (inexact scheduling) | Local notification; a Focus can silence it |
| Google sign-in | Native Credential Manager path, web fallback | Native Google SDK path, web fallback |
| Localization | German / English including auth | German / English including auth |
| Recipe pictures | Device-local | Device-local |
| Premium purchase | Google Play Billing: subscription `eatova_premium` with base plans `monthly` and `yearly`; "Abo verwalten" opens the Play subscription center | StoreKit 2: `eatova_premium_monthly` and `eatova_premium_yearly` in one group; "Abo verwalten" opens the system subscription sheet; needs the paid Apple Developer Program, not set up yet |

Health availability is independent of the app's minimum OS version. Permission
and an installed provider do not prove that step records exist. The app keeps
these states distinct. Sources: [platform factory](../lib/src/services/platform_health_service.dart),
[Android service](../lib/src/services/android_health_service.dart),
[Apple service](../lib/src/services/apple_health_service.dart).

## Data and interaction contracts

- Planning a meal does not count it as eaten. Consumption is an explicit,
  idempotent operation.
- The shopping receipt merges ingredients by a German and English vocabulary
  of common foods and their exact names; when in doubt it keeps two rows
  rather than merge different products, and a name still holding an amount
  it cannot read ("Reis (300 g gekocht)") keeps its own row. A row of one
  ingredient keeps the id of the earlier per-recipe line; a merged row has
  its own id over the week's meals including eaten ones. Eating a meal keeps
  what was bought ticked off; a meal added later makes a fresh, unchecked
  requirement, and removing a meal reopens the merged rows it was part of.
  Catalog recipes scale per serving; an own or Coach recipe planned for any
  number of servings other than one (e.g. 0.5 or 2) shows its amounts as
  written ("Originalrezept") and leaves them out of the total. No prices, no
  store aisles and no editable pantry.
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
- A day is complete from 50 % of the base daily goal. Trends averages and
  the weekly check use this rule; the streak still counts a day from one
  entry, and an entry for yesterday continues it while today is unlogged.
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
  enum is not an exposed Sign in with Apple product flow. Sign-out ends the
  Google sign-in and account deletion revokes it (Android can only clear its
  credential state).
- The AI consent is enforced in the app, not yet by the Edge Functions, so
  older installed builds keep working until they are retired.
- Premium needs the store products, the server's store credentials and the
  live rollout ([store setup](OPERATIONS.md#premium-store-setup)); until then
  the purchase screen reports the store as unavailable and Free keeps
  working. Without the optional store notifications a refund or cancellation
  reaches the account only at the next restore or re-check. When the plan
  lookup fails, the server applies the Free limits, also to Premium accounts;
  a request only those limits would refuse gets a retryable error instead of
  a limit notice or an upgrade offer.
  Deleting the account does not cancel a store subscription.
- Sign-in and password recovery match the exact spelling of the address.
  Once the alias guard is live, confirming an email change to another
  spelling of an existing account's address fails with the generic
  server-error text.
- Dietary preference can be chosen during onboarding and changed later in the
  Profile's Nutrition section, together with avoided foods and dislikes.
- JSON export is available through **Today → avatar (Profile) → gear
  (Settings) → Export data**, as a copy or a shared file. It is not an
  import/restore feature. Every section is read page by page until the server
  has no more rows; outside the diary a section stops at 100,000 rows.
  Unreadable or capped sections are identified.
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
Since 2026-10-25 a confirmation is a decision card anchored at the bottom,
with one lit action, a quiet cancel and a red fill for destructive actions;
floating surfaces separate by light and shadow instead of hairlines, and
buttons press without ripples
([handoff](PROJECT_HANDOFF.md#decision-cards-buttons-paywall-and-one-account-per-mailbox-2026-10-25)).

The [design guide index](README.md#design-contracts-and-previews) links to the
current contracts and actual Flutter previews.
