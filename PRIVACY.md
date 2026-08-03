# Privacy Policy — FitPilot

_Last updated: 2026-06-09_

FitPilot ("the app") is a fitness, recovery, and nutrition tracker. This policy
explains what data the app processes, why, and the rights you have over it. It is
written to satisfy GDPR (Art. 13/15–20) and the Apple App Store / Google Play
health-data requirements.

**Controller:** Moritz Gietl · moritz.gietl@gmail.com

## What data we process

You enter and the app stores the following, tied to your account:

- **Profile / body metrics:** name, email, weight, height, age, biological sex,
  activity level, goal weight, and your daily targets (calories, macros, steps,
  water, sleep).
- **Nutrition log:** meals you log (name, calories, macros, portion, barcode/brand
  where applicable), favorites, and your own recipes.
- **Health & wellness log:** weight history, sleep entries, caffeine intake, mood,
  habits, water and step counts, and your completed workout days / streak.
- **Coach chat:** the messages you send to the in-app AI coach and its replies.
  You may optionally attach a photo to a coach message (for example a meal or a
  progress picture); it is sent to the AI provider only to generate that reply and
  is not stored afterwards. So the coach can give specific rather than generic
  advice, each coach message is automatically accompanied by a short snapshot of
  your current targets and progress — your body weight and goal weight, today's
  calorie balance and remaining macros, and your workout streak.
- **Apple Health (optional, iOS only):** if you grant permission, the app reads
  your step count, body-weight history, and sleep duration from Apple Health to
  fill in and keep your targets and logs current. With the same permission it
  also writes back to Apple Health: a body-weight entry when you record a weigh-in,
  and a workout entry when you complete a training session. It reads and writes
  only these categories and accesses no other Apple Health data.
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
  Grok**, and the photo you submit for AI meal analysis is processed by **OpenAI's
  GPT-4o-mini**. These requests run through our server (Supabase Edge Functions);
  your API traffic is not used to train models under the configured API terms.
- **OpenFoodFacts** is queried for public product/nutrition data when you
  search or scan a barcode. Your identity is not sent with these queries.
- **Apple Speech Recognition** converts your spoken coach questions to text if you
  use voice input. To do so Apple may process the audio on its servers; see Apple's
  privacy policy. Only the resulting transcript reaches our systems, never the audio.

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

To exercise a right or ask a question, contact **moritz.gietl@gmail.com**. You also
have the right to lodge a complaint with your data-protection authority.

## Retention

Data is kept until you delete it or delete your account. Coach-chat history is kept
so you can revisit conversations; you can delete individual chat sessions in-app.

## Children

FitPilot is not directed at children under 16 and should not be used by them.

## Changes

We will update the "Last updated" date above when this policy changes. Material
changes will be surfaced in-app.
