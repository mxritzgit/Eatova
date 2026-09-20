# Privacy Policy — Eatova

_Repository data-flow update: 2026-09-14_

> The published German policy for the app and website lives at
> **[eatova.de/datenschutz](https://eatova.de/datenschutz)**. This repository
> document reflects the current app source. The public policy was separately
> corrected on 2026-09-14 at 21:34 UTC after explicit publication approval and a
> live model-configuration check. See the [publication evidence](docs/BACKEND.md#published-privacy-documentation-follow-up).
> Provider contracts, account privacy/retention settings and legal requirements
> remain separate verification needs.

Eatova ("the app") is a nutrition, meal-planning and training app with an AI coach.
This document explains its data flows and the existing privacy-policy terms.
No new store build was installed as part of that backend and website publication.

**Controller:** Moritz Gietl, Zellweg 6a, 92540 Altendorf, Germany ·
support@eatova.de

## What data we process

You enter and the app stores the following, tied to your account:

- **Account / sign-in:** your email address, and either a password or — if you
  choose "Continue with Google" — the identity token Google issues for you (see
  "Google Sign-In" below). We email you an eight-digit one-time code, valid for
  ten minutes, for: confirming your address after sign-up, resetting a
  forgotten password, changing your password while signed in, changing your
  email address (two codes — one to the old, one to the new address, both
  required), and confirming account deletion (see "Delete" under "Your
  rights").
- **Profile / body metrics:** name, email, weight, height, age, biological sex,
  activity level, goal weight, weight goal (lose/hold/gain), dietary preference,
  and your daily targets (calories, macros and steps). Water and sleep goals
  are no longer active profile controls.
- **Nutrition log:** meals you log (name, calories, macros, portion, barcode/brand
  where applicable, and whether the values came from the AI scan, a barcode, the
  product search or your own manual entry), favorites, and your own recipes,
  including preparation, structured ingredients and serving calculations.
  If you add a **photo of your own recipe**, it is re-encoded on your device and
  its entire metadata container discarded first (see "Photos" below), and the
  result is stored **only on your device**, in the app's own directory — it is
  never uploaded to our servers, and a second device shows that recipe with a
  placeholder. Like other app documents, this on-device copy is included in your
  operating system's device backup if you use one (on iOS: the iCloud backup of
  your device). On Android, Eatova is excluded from cloud backups entirely —
  neither a Google Drive backup nor an `adb` backup ever contains app data.
  What Android does still do is carry the pictures over in a **direct
  device-to-device transfer** to your own new phone, so you keep them when you
  switch devices; the app's encrypted local cache and your login session are
  excluded even there. See "Retention" for when it is deleted.
- **Meal planning and shopping:** planned dates, meal slots, recipe snapshots,
  servings, consumption links and weekly shopping-item check states. Scheduling
  a meal alone does not add it to your eaten-food diary.
- **Training:** saved plans/workouts/exercises and completed workout snapshots,
  including actual repetitions, weight or duration where recorded. A paused
  session checkpoint is kept encrypted on this device. Deleting completed
  history keeps an account-scoped identifier receipt, without the deleted
  workout content, to stop an older offline copy from restoring it. These
  receipts are included in account export and deleted with the account.
- **Weight & progress:** your weight history and your logging streak (the run of
  consecutive days on which you logged a meal), plus lifetime counters (meals
  logged, weigh-ins recorded). Accounts created before August 2026 may still
  carry legacy totals from earlier water/step/workout logging. Those legacy
  counters are distinct from the current completed-workout history. They remain
  part of export and account deletion where present.
- **Coach chat:** the messages you send to the in-app AI coach and its replies.
  You may optionally attach a photo to a coach message (for example a meal or a
  progress picture); it is sent to the AI provider only to generate that reply and
  is not stored afterwards. So the coach can give specific rather than generic
  advice, each coach message is automatically accompanied by a short snapshot of
  your current targets and progress — your body weight and goal weight, today's
  calorie balance and remaining macros, and a short list of the meals you logged
  today (meal slot, name and calories, truncated to fit a fixed length limit),
  as well as per-slot nutrition totals. Recent messages from the same chat can
  accompany the request. Before sending any reply text to the app, the server
  buffers and checks the generated reply. Approved text is then delivered in
  short chunks over the streaming connection, or a safe refusal is returned.
  Only approved assistant replies or refusal messages are stored in chat history.
  Canceling before approval leaves no partial assistant reply; your question
  may remain in the chat. After approval, history may already contain the full
  checked reply even if a dropped connection prevents your device from receiving
  all of it.
- **Coach training briefs:** when you request a plan, you can provide your goal,
  experience, available equipment, frequency, duration and constraints. You may
  explicitly attach the selected plan for discussion or adaptation. This context
  is sent to the AI service for that request; the generated proposal is stored
  with the chat and becomes a saved plan only after adoption.
- **Recipe generator (the `/recipe` command in the coach):** the dish you ask for is sent to
  the AI provider as a normal coach message and is stored in your chat history
  like any other. The recipe that comes back (title, description, ingredients,
  preparation, nutrition values) is stored with that chat message so the card
  survives a restart; it becomes one of your own recipes only if you confirm it.
  A picture of the dish is generated for the card by a separate **AI image
  model**; the prompt for it contains only the generated title and description,
  never your original wording. The generated image is stored **only on your
  device** — it is never uploaded to our servers, and a second device shows the
  card with a placeholder. Like other app documents, this on-device copy is
  included in your operating system's device backup if you use one (on iOS:
  the iCloud backup of your device); on Android it is excluded from cloud
  backups entirely and only a direct device-to-device transfer to your own new
  phone carries it across — exactly as described for your own recipe photos
  above. See "Where it is stored and who processes it" and
  "Transfers outside the EU/EEA": this feature involves a transfer to the USA.
- **Apple Health (optional, iOS only):** if you grant permission, the app reads
  your step count and body-weight history from Apple Health.
  With the same permission it also writes back to Apple Health: a body-weight
  entry when you record a weigh-in. It reads and writes only these categories
  and accesses no other Apple Health data. The step count is used on the device
  for the day's display and the calories-burned estimate; it is not stored on
  our servers.
- **Voice input (optional, iOS only):** if you use the coach's microphone button,
  audio is captured only while the microphone is active (tap to start, tap again
  to stop) and is converted to text by Apple's speech recognition. Only the resulting text is sent to the coach — the
  app neither stores the audio recording nor sends it to our servers.
- **Health Connect (optional, Android only):** with permission, the app reads
  aggregated steps during foreground refreshes for the selected day's display
  and activity estimate. It does not request Android weight access or write
  health records. Step counts are not persisted to our servers. Availability,
  permission and an empty source are handled as distinct states.

In addition, and **not** tied to your account:

- **Crash diagnostics:** builds configured with a Sentry DSN enable the
  crash-reporting SDK; a missing/empty DSN leaves it inactive. This is a build
  setting, not an in-app consent toggle. On an error an enabled build sends a
  technical report — the error type,
  an allow-listed technical detail such as a database status code, the Dart stack
  trace, and standard device/app context (device model, OS version, app version,
  build environment). Before anything leaves the device it passes a filter that
  works as an allow-list: unknown error objects are reduced to their type name
  alone. Your name, email address, body metrics, meals, weight history and coach
  messages are not part of a crash report. See "Sentry" below.
- **Technical request data:** our server endpoints (Supabase Edge Functions) and
  our product-search index receive the IP address your device connects from, as
  every internet service does. We store it only for abuse and cost protection —
  see "Retention". The rate-limit records written by our endpoints do not hold
  the address in clear text: they keep a **SHA-256 hash** of it together with a
  request counter.

We do **not** collect advertising identifiers, location data, or contacts, and
the app contains **no advertising SDK and no product-analytics or tracking SDK**.
The only third-party telemetry component in the app is the crash reporter named
above; it reports errors, not usage. Its automatic session tracking — which
would report every app start and every return to the foreground — is switched
off in the app's configuration.

**Photos:** every photo the app sends out — whether taken in-app or picked from
your gallery, for meal analysis or for the coach — is re-encoded on your device
first and its entire metadata container is discarded. GPS coordinates, capture
time and camera/device identifiers written by the system camera are removed on
the device, before the photo is uploaded.

## Where it is stored and who processes it

- **Supabase** (Postgres + Auth, EU region) hosts your account and all the data
  above, except what is marked as device-only there (recipe pictures, the step
  count). Every row is protected by row-level security so it is only accessible
  to your authenticated account. On your device the app additionally keeps an
  offline copy of supported account data, including diary, weight, profile,
  recipes, plans, shopping checks and workout history. It is encrypted with a
  key held in the operating system's keystore; pending writes use an
  account-scoped durable outbox.
- **OpenRouter** routes your AI requests to the underlying model providers, solely
  to generate the response. The current source configures Google's Gemini
  family for these requests:
  - coach-chat messages — together with the profile/progress snapshot and any
    photo you attach, as described above — use **Gemini 3.8 Flash**, as does the
    safety/topic classifier;
  - a recipe you ask the coach for is drafted by the same Gemini model,
    from your wording alone (no profile snapshot, no photo);
  - training requests use Gemini 3.8 Flash with the explicit brief and any
    selected-plan context;
  - meal photos use Gemini 3.8 Flash for analysis; recipe pictures use a separate
    image-generation model, `google/gemini-3.1-flash-image`.

  Server settings can override these defaults. The exact configuration names
  and dated rollout evidence are in [Backend](docs/BACKEND.md#ai-configuration).
  The classifier receives the message text, not the profile snapshot, chat
  history or attached image. Ordinary chat can include up to ten recent messages.

  All of these run through our server (Supabase Edge Functions). We rely on
  OpenRouter's and the underlying providers' data-use terms to keep your API
  traffic out of model training; our server does not send a per-request
  opt-out parameter, so this rests on OpenRouter account configuration and
  provider policy rather than on something our code enforces.
- **Google Sign-In** (optional). If you sign in with Google, Google processes
  your Google account identifier, email address, name and the device/connection
  data involved in the sign-in in order to issue the identity token we exchange
  for an Eatova session. Email/password sign-in does not use Google's
  authentication service; the optional Gemini AI features are separate.
- **Our own product-search index** (Meilisearch, `eatova.de/meili`, on a server
  we operate in Germany) answers product and barcode searches from a copy of the
  public Open Food Facts database. It receives the search term or barcode and the
  IP address of your device; **no account identifier and no profile data are
  sent.** If the index is unavailable or switched off, the same query goes
  straight to Open Food Facts instead.
- **OpenFoodFacts** is queried for public product/nutrition data when you
  search or scan a barcode, and whenever our own index is not used. Your identity
  is not sent with these queries.
- **Sentry** (`ingest.de.sentry.io`, EU region — reports are sent to and stored
  in the EU) receives the crash diagnostics described above. The SDK is
  configured to send no personal data by default (`sendDefaultPii = false`), to
  attach neither screenshots nor the on-screen view hierarchy, to run neither
  session replay nor performance tracing, and to keep the SDK's automatic
  session tracking off (`enableAutoSessionTracking = false`), so no app starts,
  foreground changes or other usage signals are sent; only errors are reported.
  Every report and every diagnostic breadcrumb additionally passes the
  allow-list filter described above before it is sent.
- **Apple Speech Recognition** converts your spoken coach questions to text if you
  use voice input. The app requests on-device recognition, so on devices where Apple
  provides an offline model for your language the audio never leaves your phone.
  Where no on-device model is available, Apple processes the audio on its servers
  instead; see Apple's privacy policy. In either case only the resulting transcript
  reaches our systems, never the audio.

Management, service-role and AI provider credentials remain server-side.
The app contains public Supabase client configuration and a limited product
search fallback. Runtime search credentials can be either a search-only key or
an expiring, index-scoped tenant token, depending on server configuration. They
provide access to public product data and can be rotated independently of a build.

## Transfers outside the EU/EEA

The published service policy places the main hosted data in the EU: Supabase runs in an EU region, the
crash reports go to Sentry's EU ingest endpoint, and our product-search index
runs on a server in Germany.

The configured AI path involves recipients in, or routing to, the United States:

- **OpenRouter, Inc.** (San Francisco, USA) — the router your AI requests pass
  through,
- **Google** (USA) — the provider of the Gemini models for Coach/classification,
  recipes, training drafts, meal analysis and recipe pictures. This entry is about the
  Gemini models only; Google Sign-In is a separate service provided to users in
  the EU by Google's European entity.

These AI transfers happen when you use coach chat, a coach recipe/training
proposal or AI meal analysis. The published policy identifies the
**Standard Contractual Clauses** adopted by the EU
Commission (Art. 46(2)(c) GDPR). Despite these safeguards, a residual risk
remains that US authorities can access data held by US providers, and that your
rights may be harder to enforce there than in the EU. If you do not want this,
simply do not use the coach and the AI meal scan; every other feature of the app
works without them.

Apple's speech recognition may also process audio on Apple's servers where no
on-device model is available for your language (see above).

## Why (legal basis)

We process this data to provide the tracking features you ask for — i.e. to perform
the service you signed up for (GDPR Art. 6(1)(b)), and, for optional Apple Health
read/write, Health Connect steps, voice input and AI features, on the basis of the permission you
grant in-app (Art. 6(1)(a), Art. 9 for health data).

Crash diagnostics and the short-lived storage of the hashed IP address for rate
limiting rest on our legitimate interest in a stable app and in protecting our
servers from abuse and runaway cost (Art. 6(1)(f)).

## Your rights

You can, at any time:

- **Access / export** your data. The in-app export (Today → Settings →
  Export data) requests a JSON copy of your stored data directly
  from our servers — every table that belongs to your account: profile, food
  diary, favorites, recipes, weight log, lifetime statistics, training plans,
  meal plans, shopping checks, training history/deletion receipts, coach chats
  and daily coach quota counters. The app can copy the full returned JSON;
  native file sharing is not wired. Device-only pictures and unsynced changes
  are not part of this server export. The diary is paginated; other sections
  have a 10,000-row client limit and may be capped lower by the server. Missing
  or truncated sections are explicitly identified. You can also request your
  data by email.
- **Correct** supported editable values in the app, or contact us for other
  corrections; completed training history is intentionally immutable.
- **Delete** your account and all associated data — in-app via Today →
  Settings → Delete account, which removes your auth record; every app
  table hangs off it with `on delete cascade` and is deleted with it. You
  confirm the deletion with an eight-digit one-time code emailed to you, on top
  of typing the confirmation word — deletion is immediate and irreversible
  once confirmed, there is no grace period.
- **Withdraw health/voice permission** in the platform privacy settings or
  Health Connect permissions; stop sending new AI requests by not using those
  features. Account/data deletion is available as described above.

To exercise a right or ask a question, contact **support@eatova.de**. You also
have the right to lodge a complaint with your data-protection authority.

## Retention

Data is kept until you delete it or delete your account. Coach-chat history is kept
so you can revisit conversations; you can delete individual chat sessions in-app.

Exceptions:

- the **rate-limit records** that hold the hashed IP address are deleted after
  two days. The deletion is performed by the server endpoints themselves as part
  of a later request, not by a scheduler, so a record can outlive the two days by
  the length of a quiet period.
- **crash reports** are kept only as long as needed to diagnose and fix the
  error. The period is set and enforced by the crash-reporting service, not by
  this app.
- the **pictures of recipes** — both the picture generated for a coach recipe
  and a photo you took of one of your own recipes — live only in the app's own
  directory on your device. A single picture is deleted when you delete the
  recipe it belongs to; all of them are deleted when you sign out, when a
  different account signs in on this device, and when you delete your account.
  Because they never reach our servers, this deletion on the device is the only
  one they need. A copy that your operating system's device backup has already
  taken is governed by that backup, not by the app.
- a technical **request-deduplication marker** (a request ID, no content) is
  written when certain counters are updated, so a retried request cannot be
  counted twice. Markers older than 30 days are removed on the next new counter
  update for the same account, or when the account is deleted. A duplicate retry
  does not trigger this cleanup; inactive accounts can retain older markers.
- the **daily coach counters** — one number per day recording how many coach
  messages you used, so the daily limit can be enforced. They hold no message
  content. Counters older than 90 days are deleted; the current day's counter is
  never deleted, because it is the one the limit is being counted against. As
  with the rate-limit records above, the deletion is performed by the server
  endpoints themselves as part of a later request rather than by a scheduler, so
  a counter can outlive the 90 days by the length of a quiet period. Until they
  are deleted, these counters are part of the data export you can request.
- **daily AI-provider usage** records contain your account identifier, UTC day
  and the number of reserved provider calls, without prompts, images or answers.
  They enforce an independent limit that is not refunded after a failed call.
  Records older than 30 days are removed on the first permitted provider call
  of a later UTC day; inactivity or disabled AI processing can delay cleanup.
  Account deletion removes that account's records. Your own records are included
  in the data export. Separate global counters contain only daily totals and no
  account identifier; the same request-triggered cleanup applies to them.

Recipe version history preserves previous versions and deleted recipes so you
can inspect and restore them. Deleting the current recipe removes it from the
active collection; its history remains until account deletion. Recipe history
is included in the in-app data export. Recipe pictures remain on the device.

Sync operation receipts retain request fingerprints, identifiers and original
results to prevent duplicate changes after an uncertain connection. Depending
on the operation, a result can include recipe content, a planned meal or
counters. These records and deletion markers have no automatic expiry and are
removed with the account. Operational replay metadata is available through an
authorized data-access request; the in-app export contains the user-data sections
described above and reports sections it could not fully retrieve.

Other data has no automatic expiry and is kept until you delete it or delete
your account.

Training-history deletion receipts retain only the account/history identifiers
needed to reject stale replays; they remain until account deletion. Local
checkpoints/outbox data are isolated to the account and cleared with account
cleanup. Provider-side retention is governed by the applicable service terms,
not by deleting a local copy alone.

## Children

Eatova is not directed at children under 16 and should not be used by them.
The app enforces this age limit technically: a profile age below 16 cannot be
entered in the app, and the database rejects such values as well (minimum age
16, in line with Art. 8 GDPR for consent involving health data under Art. 9).

## Changes

The date at the top identifies this repository update. Changes to the published
policy and any required in-app notice have a separate publication process; the
verified website publication is recorded in [Backend](docs/BACKEND.md#published-privacy-documentation-follow-up).
