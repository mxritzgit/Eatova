# Coach recipe generation: Sentry investigation, 2026-09-13

## Production evidence

[FLUTTER-D](https://eatova.sentry.io/issues/146536999/) contains two events;
[FLUTTER-E](https://eatova.sentry.io/issues/146537042/) contains the retry event.
All three report `FunctionsHttpException status=502` in
`CoachChatService.requestRecipe`, tagged `coach.recipe.http`, from iOS release
`1.1.0 (3)`. The extra retry frame accounts for the separate issue group.

Read-only Supabase logs correlate these requests with `coach-chat` version 45:

| UTC on September 12 | Recipe output length | Server result |
| --- | ---: | --- |
| 01:53:01 | 783 characters | Unreadable draft, HTTP 502 |
| 01:53:45 | 328 characters | Unreadable draft, HTTP 502 |
| 01:54:09 | 484 characters | Unreadable draft, HTTP 502 |

The confirmed failure is unusable recipe JSON, before image generation. These
events do not establish a Food UI regression. The old recipe diagnostic retained
only output length, so the historical provider completion reason and raw output
cannot be recovered from these logs. Do not present token exhaustion as a
retrospectively proven fact for those requests.

## Change

The recipe call still used 900 output tokens without reasoning control, although
the ordinary Coach answer received reasoning headroom in PR #76. Reasoning uses
the same completion budget; excluding it from the response does not free tokens
([OpenRouter contract](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)).

Recipe drafts now have 3,072 output tokens and low reasoning effort, with internal
reasoning excluded from the response. A bounded provider fixture reproduces the
old 502 when reasoning and recipe JSON exceed 900 tokens. The corrected handler
delivers and persists the full proposal with one quota claim and one draft call.

Explicit `finish_reason=length` prevents delivering even syntactically valid
partial recipe JSON. An explicit JSON refusal remains authoritative and retains
its existing quota policy. Failure diagnostics retain only character count and
an allowlisted completion category. Malformed provider envelopes use a fixed
diagnostic instead of a parser message that could quote private provider text.
Body timeouts retain their existing HTTP 504 handling.

Authentication, ownership, rate limits, explicit recipe adoption, local-only
generated images, and the existing provider-error refund paths are unchanged.
There are no automatic paid retries or continuation calls.

## Verification and delivery

Two new regressions were run against the old handler and failed: insufficient
completion room returned 502, and parseable length-limited JSON was accepted.
Both pass after the fix. Additional cases preserve charged refusals and prevent
provider text or arbitrary metadata from reaching diagnostics.

The full 507-test Deno suite, Deno lint and all three function entrypoint checks
pass. Strict Flutter analysis passes with fatal infos and warnings. All 4,372
Flutter tests pass with dummy defines; total line coverage is 27,473 / 29,439
(93.32%). The CI calculation excludes generated localization and yields 25,323 /
26,629 (95.10%), above the required 88% floor. No Flutter application code or
dependencies changed.

Changes are prepared on `fix/coach-recipe-completion`, based on main `f523419`.
Review is a direct diff and boundary review; no independent agent review was run.
With the user's Supabase write authorization, `coach-chat` was deployed as v46
ACTIVE with JWT verification enabled. The downloaded production modules match
the tested source. The previous v45 source was backed up and matched base HEAD;
other function versions are unchanged. No migration or new app build is needed.

Two authenticated requests against v46 used a disposable synthetic account and
the real provider: German and English recipes returned HTTP 200 in 19.41 s and
15.86 s, both including an image. Required recipe fields were populated, the
stored chat proposals exactly matched the response, and each request used one
daily quota slot. No `user_recipes` row was created without adoption. The temporary
account and its chat sessions, messages, quota rows and recipes were deleted;
their absence was verified. This is a bounded live check, not evidence of
long-term provider reliability or a newly installed device build.

The user authorized push and protected-main merge of `fix/coach-recipe-completion`.
The branch's pull request records the final Git delivery and CI results. Production
v46 was deployed before Git delivery; its source must remain identical to the
reviewed fix when merging. Existing Sentry events remain as historical evidence.

Sanitized local log evidence and check output are ignored under
`.agents/sentry-2026-09-13/`. No user message, generated recipe, credential,
device identifier or account identifier is copied into this document.
