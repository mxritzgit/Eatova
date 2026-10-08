# Coach model evaluation

This opt-in harness executes the current `coach-chat/handler.ts` locally with
synthetic auth, history, quota and persistence. It sends only fixed synthetic
text cases to the Claude Messages API (`claude-sonnet-5-5`), the deployed
default. It never calls the deployed application or Supabase. Do not add real
accounts, logs, medical histories or arbitrary external files.

First run the offline safety checks:

```sh
deno test --allow-env --cached-only supabase/eval/coach_eval_test.ts
```

A separate process and explicitly approved provider budget are required for a
paid run. Supply only `ANTHROPIC_API_KEY` through process memory using the
approved secret manager. Never write it into a file, command argument or report.
The initial smoke runs just the first case; a full run starts a new budget and
must be counted together with any smoke run against the approved total.

```sh
deno run --allow-env --allow-net=api.anthropic.com --no-remote --no-npm \
  supabase/eval/coach_eval.ts --live --budget-usd=2.06 --smoke
```

The run evaluates the deployed configuration: the harness removes
`CLAUDE_MODEL` and `COACH_EFFORT` from its own process, so the handler uses its
defaults (model `claude-sonnet-5-5`, effort `high`, adaptive thinking). If
production pins either secret, this run does not cover that value. Requests
keep the server's prompts, roles, cache breakpoints, thinking, effort, output
schemas and output caps. Thinking counts against `max_tokens`, so the harness
does not lower them: classifier 1,024, answer 4,096, recipe and /log drafts
4,096, plan 5,000 tokens (a structured draft above 5,000 would be lowered).
The harness rejects concurrent calls, other hosts or models, tools, MCP,
fallbacks, sampling or routing fields, images and documents, and input over
16,384 UTF-8 bytes (system prompt, messages and output schema together; the
largest synthetic request measured 7,480). Response bodies are bounded to the
server's own 512 KiB; redirects, retries and fallbacks are disabled. An outage
stops the run.

Each call reserves its cost before it is sent, without refunds, at Claude
Sonnet 5.5 list prices ($2.00 per million input tokens, $10.00 output, $2.50
cache write, $0.20 cache read). The reservation is an upper bound: the input
is text, a token covers at least one byte, so the request's bytes plus 4,096
overhead tokens bound its input tokens, all priced at the cache-write rate;
the full output cap is priced as output. Rounded up to whole cents:

| Call | Current requests | At the 16,384-byte input limit |
|---|---|---|
| Classifier (1,024) | 4 cents (about 4.0 KB) | 7 cents |
| Answer (4,096) | 7 cents (about 7.0-7.5 KB) | 10 cents |
| Recipe / log draft (4,096) | 6 / 7 cents (2.2 / 6.3 KB) | 10 cents |
| Plan (5,000) | 7 cents (3.8 KB) | 11 cents |

Batch caps assume every call at the input limit. The standard batch allows 24
calls and $2.06: 12 classifiers, 9 answers (refusal cases may pass their
classifier), the recipe and 2 plans (`injury-plan` too). With the current
prompts all 24 calls reserve $1.31 (measured offline on 2026-10-08). Cache
reads and shorter answers make the real spend lower still; neither number is
an estimate of it. This assumes the provider honours its
token contract; it is not an independently enforced credit limit on the shared
provider account. No image cost estimate is used: images are blocked. Review
current [pricing](https://platform.claude.com/docs/en/about-claude/pricing) and
[model documentation](https://platform.claude.com/docs/en/about-claude/models/overview)
before each authorised run.

Output JSON (`schemaVersion` 2) includes per call the route, input bytes,
output cap, reservation, returned model, `stop_reason` values and the numeric
usage counters (`input_tokens`, `output_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens`), plus synthetic user-visible responses,
expected outcomes and review criteria. It omits raw provider errors, thinking,
headers and credentials. Record the Git commit alongside the artifact. Recipe
images still go to OpenRouter: the harness sets a placeholder key in its own
process so the handler reaches that call, which is refused locally and counted
as `imagesSkipped`; no OpenRouter request leaves the process and no recipe or
plan is actually adopted. Streaming uses the real server parser but the harness
buffers the provider transport, so it does not prove live proxy/chunk timing or
deployed auth/RLS.

`technicalPass` only checks response kind and two explicit injection canaries.
Read every answer against its case rubric. A small passing sample is not a
semantic, medical, nutrition, child-safety or legal certification. Real-model image-only,
broader multilingual/obfuscated attacks, multi-turn escalation and qualified
clinical review remain separate work. The model id and returned model identify
this run; they do not prove an immutable model build.

For a separately approved continuation, `--remainder --budget-usd=0.86` runs
only context injection, history injection, minor-risk, then positive plan and
recipe cases: at most ten provider calls and $0.86 (5 classifiers, 3 answers,
recipe and plan at the input limit). The dollar cap is independent of the
request-count cap. No images, retry or fallback are enabled. All processes must
still be counted against the authorised cumulative budget; this mode is not an
automatic retry. Fixed stderr start/reservation markers and a partial JSON
artifact retain spend evidence on failures without printing raw errors.

The 2026-09-15 results in `results/` were produced by the earlier OpenRouter
harness (Gemini Flash, 768-token answer cap) and do not describe the current
configuration.

## /log batch

`--log --budget-usd=4.08` runs `COACH_LOG_EVAL_CASES`: the 22 workout-log
cases E1-E22 (English app unless noted, `local_date` 2026-10-03, a Saturday)
and two English-app chat cases with mixed or workout-report input. Each log
case sends `mode: "log"` and its `local_date` like the app, and the runner
freezes the server clock to that day so the calendar stays fixed on any run
date. Each case reserves a classifier call and an extraction (log cases) or an
answer (chat cases), both at their real 4,096-token cap. At most 48 calls and
$4.08: 24 classifiers at 7 cents and 24 extractions or answers at 10 cents at
the input limit; the current requests reserve 4 + 7 cents per case, $2.64 for
all 48 calls.

```sh
deno run --allow-env --allow-net=api.anthropic.com --no-remote --no-npm \
  supabase/eval/coach_eval.ts --live --log --budget-usd=4.08
```

Besides `technicalPass` (the response kind), every case with an `expect`
rubric reports `expectationPass` and `expectationFailures`: date, other days,
duration, title and note patterns, injection canaries, the D4 safety line (and
its absence on gym slang such as E16) and the exact sets after the server
transform (for example 225 lb stored as 102.06 kg). Names and notes vary
between runs, so they are matched loosely; read the replies against each
case's `review` text as well. The offline test
feeds the ideal extraction from the shared fixture
(`functions/coach-chat/fixtures/workout_log_cases.json`) through the real
handler and must pass every rubric.

D4 does not rest on the classifier alone: a finished-workout report that
mentions pain usually classifies as `fitness`, so the extraction returns a
server-only `health_mention` flag (never stored) that adds the safety line
too. The offline test classifies E22 as `fitness` and passes only through
that flag. A live run is still the proof that the real model sets it: treat
a failed E22 (and E16, E19) as a deploy blocker.

## Offline handler boundary matrix

`supabase/functions/coach-chat/handler_boundary_test.ts` exercises the actual
handler with synthetic auth/database records and scripted provider replies:

```sh
deno test --allow-env supabase/functions/coach-chat/handler_boundary_test.ts
```

It covers image-only and caption routing, measured image types, classifier
failures/refusals, selected-plan notes, multi-turn history authority, overlapping
account A/B requests, ownership-scoped persistence, cancellation/refunds and
sanitized transport diagnostics. Legitimate captions, ordinary plan discussion,
connected-client outage refunds and completed-proposal recovery are controls.
No external network permission or provider key is required.

These are enforcement tests: a scripted `injection` verdict proves that the
handler stops subsequent work, not that a real model detects the attack. The
tiny PNG tests image transport, not OCR or interpretation of embedded text.
The paid text-only harness above is unchanged and still blocks images.
Buffered provider calls already in flight retain their deadlines and may finish
after disconnect; completed proposals can be recovered from owned history.
Cancellation stops subsequent provider-budget reservations and never restores
the daily slot. These local tests do not prove deployed disconnect propagation,
platform concurrency limits, end-to-end latency or provider billing cessation.
