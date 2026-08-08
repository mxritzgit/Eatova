# Privacy Policy — Eatova

_Last updated: 2026-08-08_

> The authoritative, always-current version of this policy (in German, covering
> both the app and the website) lives at
> **[eatova.de/datenschutz](https://eatova.de/datenschutz)**. This file is the
> repository mirror of that policy; where the two differ, the published German
> version governs.

Eatova ("the app") is a fitness, recovery, and nutrition tracker. This policy
explains what data the app processes, why, and the rights you have over it. It is
written to satisfy GDPR (Art. 13/15–20) and the Apple App Store / Google Play
health-data requirements.

**Controller:** Moritz Gietl, Zellweg 6a, 92540 Altendorf, Germany ·
support@eatova.de

## What data we process

You enter and the app stores the following, tied to your account:

- **Account / sign-in:** your email address, and either a password or — if you
  choose "Continue with Google" or "Sign in with Apple" — the identity token
  that provider issues for you (see "Google Sign-In" and "Apple" below).
- **Profile / body metrics:** name, email, weight, height, age, biological sex,
  activity level, goal weight, and your daily targets (calories, macros, steps,
  water, sleep).
- **Nutrition log:** meals you log (name, calories, macros, portion, barcode/brand
  where applicable), favorites, and your own recipes.
- **Health & wellness log:** weight history, sleep entries, caffeine intake,
  water and step counts, and your logging streak (the run of consecutive days on
  which you logged a meal).
- **Coach chat:** the messages you send to the in-app AI coach and its replies.
  You may optionally attach a photo to a coach message (for example a meal or a
  progress picture); it is sent to the AI provider only to generate that reply and
  is not stored afterwards. So the coach can give specific rather than generic
  advice, each coach message is automatically accompanied by a short snapshot of
  your current targets and progress — your body weight and goal weight, today's
  calorie balance and remaining macros, and a short list of the meals you logged
  today (meal slot, name and calories, truncated to fit a fixed length limit).
- **Apple Health (optional, iOS only):** if you grant permission, the app reads
  your step count, body-weight history, and sleep duration from Apple Health to
  fill in and keep your targets and logs current. With the same permission it
  also writes back to Apple Health: a body-weight entry when you record a
  weigh-in. It reads and writes only these categories and accesses no other
  Apple Health data.
- **Voice input (optional, iOS only):** if you use the coach's microphone button,
  audio is captured only while the microphone is active (tap to start, tap again
  to stop) and is converted to text by Apple's speech recognition. Only the resulting text is sent to the coach — the
  app neither stores the audio recording nor sends it to our servers.

In addition, and **not** tied to your account:

- **Crash diagnostics:** the builds we publish contain the Sentry crash-reporting
  SDK. When the app hits an error it sends a technical report — the error type,
  an allow-listed technical detail such as a database status code, the Dart stack
  trace, and standard device/app context (device model, OS version, app version,
  build environment). Before anything leaves the device it passes a filter that
  works as an allow-list: unknown error objects are reduced to their type name
  alone. Your name, email address, body metrics, meals, weight history and coach
  messages are not part of a crash report. See "Sentry" below.
- **Technical request data:** our server endpoints (Supabase Edge Functions) and
  our product-search index receive the IP address your device connects from, as
  every internet service does. We store it only for abuse and cost protection —
  see "Retention".

We do **not** collect advertising identifiers, location data, or contacts, and
the app contains **no advertising SDK and no product-analytics or tracking SDK**.
The only third-party telemetry component in the app is the crash reporter named
above; it reports errors, not usage.

**Photos:** every photo the app sends out — whether taken in-app or picked from
your gallery, for meal analysis or for the coach — is re-encoded on your device
first and its entire metadata container is discarded. GPS coordinates, capture
time and camera/device identifiers written by the system camera are removed on
the device, before the photo is uploaded.

## Where it is stored and who processes it

- **Supabase** (Postgres + Auth, EU region) hosts your account and all the data
  above. Every row is protected by row-level security so it is only accessible to
  your authenticated account.
- **OpenRouter** routes your AI requests to the underlying model providers, solely
  to generate the response: coach-chat messages — together with the profile/progress
  snapshot and any photo you attach, as described above — are answered by **xAI's
  Grok**, and the photo you submit for AI meal analysis is processed by a model of
  **Google's Gemini family**. These requests run through our server (Supabase Edge
  Functions); your API traffic is not used to train models under the configured
  API terms.
- **Google Sign-In** (optional). If you sign in with Google, Google processes
  your Google account identifier, email address, name and the device/connection
  data involved in the sign-in in order to issue the identity token we exchange
  for an Eatova session. If you sign in with email and password, or with Apple,
  Google is not involved at all.
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
  attach neither screenshots nor the on-screen view hierarchy, and to run
  neither session replay nor performance tracing; only errors are reported.
  Every report and every diagnostic breadcrumb additionally passes the
  allow-list filter described above before it is sent.
- **Sign in with Apple** (optional, iOS). If you use it, Apple processes the
  sign-in and issues the identity token we exchange for an Eatova session.
- **Apple Speech Recognition** converts your spoken coach questions to text if you
  use voice input. The app requests on-device recognition, so on devices where Apple
  provides an offline model for your language the audio never leaves your phone.
  Where no on-device model is available, Apple processes the audio on its servers
  instead; see Apple's privacy policy. In either case only the resulting transcript
  reaches our systems, never the audio.

The API keys that can write, spend money or read other people's data live only on
our server, never in the app. The one key shipped with the app is the
**search-only** key for our product-search index: it can run searches against the
public product index and nothing else. It is resolved at runtime so it can be
rotated without breaking installed builds.

## Transfers outside the EU/EEA

Most of the processing above stays in the EU: Supabase runs in an EU region, the
crash reports go to Sentry's EU ingest endpoint, and our product-search index
runs on a server in Germany.

Three recipients are, or route to, the United States:

- **OpenRouter, Inc.** (San Francisco, USA) — the router your AI requests pass
  through,
- **xAI** (USA) — the provider of the Grok model that answers coach messages,
- **Google** (USA) — the provider of the Gemini model that analyses meal photos.
  This entry is about the Gemini model only; Google Sign-In is a separate service
  provided to users in the EU by Google's European entity.

These transfers only happen when you use an AI feature (coach chat or AI meal
scan). They are based on the **Standard Contractual Clauses** adopted by the EU
Commission (Art. 46(2)(c) GDPR). Despite these safeguards, a residual risk
remains that US authorities can access data held by US providers, and that your
rights may be harder to enforce there than in the EU. If you do not want this,
simply do not use the coach and the AI meal scan; every other feature of the app
works without them.

Apple's speech recognition may also process audio on Apple's servers where no
on-device model is available for your language (see above).

## Why (legal basis)

We process this data to provide the tracking features you ask for — i.e. to perform
the service you signed up for (GDPR Art. 6(1)(b)), and, for the optional Apple Health
read/write, voice input, and AI features, on the basis of the explicit permission you
grant in-app (Art. 6(1)(a), Art. 9 for health data).

Crash diagnostics and the short-lived storage of your IP address for rate limiting
rest on our legitimate interest in a stable app and in protecting our servers from
abuse and runaway cost (Art. 6(1)(f)).

## Your rights

You can, at any time:

- **Access / export** your data. The in-app export (Profile → Daten exportieren)
  loads a complete JSON copy of your stored data directly from our servers —
  every table that belongs to your account (profile, food diary, favorites,
  recipes, weight log, coach-chat history, statistics), satisfying Art. 15/20.
  If a section cannot be fetched, the export lists it by name instead of
  silently omitting it. You can also ask us by email at any time and we will
  send you a copy.
- **Correct** any value directly in the app.
- **Delete** your account and all associated data — in-app via Profile → Konto
  löschen, which removes your auth record and cascades to every table.
- **Withdraw consent** for Apple Health or voice input (in iOS Settings → Privacy)
  or AI features (by not using them).

To exercise a right or ask a question, contact **support@eatova.de**. You also
have the right to lodge a complaint with your data-protection authority.

## Retention

Data is kept until you delete it or delete your account. Coach-chat history is kept
so you can revisit conversations; you can delete individual chat sessions in-app.

Two exceptions with a fixed, short life:

- the **rate-limit records** that hold your IP address are deleted after two days;
- **crash reports** are kept only as long as needed to diagnose and fix the error,
  and are subject to the retention period of the crash-reporting service.

## Children

Eatova is not directed at children under 16 and should not be used by them.
The app enforces this age limit technically: a profile age below 16 cannot be
entered in the app, and the database rejects such values as well (minimum age
16, in line with Art. 8 GDPR for consent involving health data under Art. 9).

## Changes

We will update the "Last updated" date above when this policy changes. Material
changes will be surfaced in-app.
