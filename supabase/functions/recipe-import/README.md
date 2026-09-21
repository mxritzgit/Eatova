# Recipe import

Authenticated, preview-only extraction for the app's incoming share sheet.
The function never writes recipes or chat history; the client saves selected
candidates only after explicit confirmation.

`POST /functions/v1/recipe-import` accepts only
`{"text":"shared URL and/or recipe text","locale":"de"}`. Locale is `de` or
`en`; text is nonempty, at most 20,000 characters / 90,000 request-body bytes.
The response is `{status, source, candidates, warnings}`:

- `ready`: one or more candidates, at most six, in source order. The client
  previews one directly and asks the user to choose when there are several.
- `needs_text`: the source is unavailable or lacks ingredients/instructions.
- `no_recipe`: available text contains no extractable recipe.

`source` contains `url` (nullable), optional `title` and `author`. Candidates
contain `id`, `title`, `description`, `portion`, `ingredients`, `preparation`,
optional `variant_label`, nullable `servings`, `nutrition_estimated:false`, and
nullable `calories_kcal`, `protein_g`, `carbs_g`, `fat_g`, `estimated_g`.
IDs hash normalized source ingredient/preparation text, independent of translated
titles. Ingredient/preparation fields and variant labels must be verbatim source
quotes. Unknown nutrition stays null; copied values require an explicit
per-serving basis and matching nutrient labels. No calorie estimates are generated.
Warnings are only `nutrition_missing`, `source_incomplete`, `truncated`. The last
also means some additional recipes could not be represented completely; it never
authorizes silently completing them.

Public TikTok captions are obtained from the official
[oEmbed endpoint](https://developers.tiktok.com/docs/en/embed-videos).
Canonical video links and `vm.tiktok.com`, `vt.tiktok.com`, and `/t/` short links
are supported with exact host/path checks and at most four manual redirects.
More than one distinct shared URL prevents automatic source selection. Tracking
parameters, HTML, thumbnails, video, comments, audio and other linked pages are
not loaded. Private/deleted posts, unavailable metadata, other platforms and
video-only instructions require the user to paste recipe text. TikTok's
[Display API](https://developers.tiktok.com/docs/en/tiktok-api-v2-video-query)
requires creator authorization and cannot read arbitrary shared creators' videos.

Authentication uses the project's verified user endpoint plus JWT user-context
binding. Import gates allow 60 requests per IP / 10 minutes, 20 per account /
hour and 20 extraction attempts per account / UTC day. Each model call also
requires the existing non-refundable `coach_recipe` provider reservation,
sharing the global/account provider-call budget and kill switch with other AI
features. It does not consume a coach chat message slot. No new database schema
is required. Existing provider-budget and rate-limit migrations must be deployed.

Existing `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, and
`OPENROUTER_API_KEY` configuration is used. Optional `RECIPE_IMPORT_MODEL`
overrides `COACH_MODEL_ANSWER` / the existing Gemini default. Deployment must
retain the Supabase JWT gateway verification. Total handler budget is 55 seconds;
source fetching has a 10-second ceiling and model calls a 35-second ceiling.

Errors are machine codes: `invalid_request` / `invalid_json` (400), `unauthorized`
(401), `payload_too_large` (413), `unsupported_content_type` (415), `rate_limited`
or `ai_budget_exhausted` (429), `provider_unavailable` /
`provider_invalid_response` (502), `auth_unavailable`, `rate_limit_unavailable`,
`ai_budget_unavailable`, `ai_disabled`, `not_configured` (503), and
`request_timeout` (504). Response bodies and logs never include upstream bodies,
captions, bearer tokens or exception details.

Tests stub every outbound request and run with `deno test --allow-env` without
network permission. Live TikTok availability and model extraction quality are
not established by these unit tests.
