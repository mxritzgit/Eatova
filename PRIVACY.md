# Privacy Policy — Eatova

_Last updated: 2026-08-05_

> The authoritative, always-current version of this policy (in German, covering
> both the app and the website) lives at
> **[eatova.de/datenschutz](https://eatova.de/datenschutz)**.

Eatova ("the app") is a fitness, recovery, and nutrition tracker. This policy
explains what data the app processes, why, and the rights you have over it. It is
written to satisfy GDPR (Art. 13/15–20) and the Apple App Store / Google Play
health-data requirements.

**Controller:** Moritz Gietl, Zellweg 6a, 92540 Altendorf, Germany ·
support@eatova.de

## What data we process

You enter and the app stores the following, tied to your account:

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

We do **not** collect advertising identifiers, location, or contacts, and the app
contains no third-party analytics or ad SDKs.

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
- **OpenFoodFacts** is queried for public product/nutrition data when you
  search or scan a barcode. Your identity is not sent with these queries.
- **Apple Speech Recognition** converts your spoken coach questions to text if you
  use voice input. The app requests on-device recognition, so on devices where Apple
  provides an offline model for your language the audio never leaves your phone.
  Where no on-device model is available, Apple processes the audio on its servers
  instead; see Apple's privacy policy. In either case only the resulting transcript
  reaches our systems, never the audio.

API keys for these services live only on our server, never in the app.

## Why (legal basis)

We process this data to provide the tracking features you ask for — i.e. to perform
the service you signed up for (GDPR Art. 6(1)(b)), and, for the optional Apple Health
read/write, voice input, and AI features, on the basis of the explicit permission you
grant in-app (Art. 6(1)(a), Art. 9 for health data).

## Your rights

You can, at any time:

- **Access / export** your data (see in-app export, and you may request a full copy
  by email).
- **Correct** any value directly in the app.
- **Delete** your account and all associated data — in-app via Profile → Account
  löschen, which removes your auth record and cascades to every table.
- **Withdraw consent** for Apple Health or voice input (in iOS Settings → Privacy)
  or AI features (by not using them).

To exercise a right or ask a question, contact **support@eatova.de**. You also
have the right to lodge a complaint with your data-protection authority.

## Retention

Data is kept until you delete it or delete your account. Coach-chat history is kept
so you can revisit conversations; you can delete individual chat sessions in-app.

## Children

Eatova is not directed at children under 16 and should not be used by them.
The app enforces this age limit technically: a profile age below 16 cannot be
entered in the app, and the database rejects such values as well (minimum age
16, in line with Art. 8 GDPR for consent involving health data under Art. 9).

## Changes

We will update the "Last updated" date above when this policy changes. Material
changes will be surfaced in-app.
