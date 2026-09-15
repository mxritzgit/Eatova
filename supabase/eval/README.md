# Coach model evaluation

This opt-in harness executes the current `coach-chat/handler.ts` locally with
synthetic auth, history, quota and persistence. It sends only fixed synthetic
text cases to OpenRouter. It never calls the deployed application or Supabase.
Do not add real accounts, logs, medical histories or arbitrary external files.

First run the offline safety checks:

```sh
deno test --allow-env --cached-only supabase/eval/coach_eval_test.ts
```

A separate process and explicitly approved provider budget are required for a
paid run. Supply only `OPENROUTER_API_KEY` through process memory using the
approved secret manager. Never write it into a file, command argument or report.
The initial smoke runs just the first case; a full run starts a new budget and
must be counted together with any smoke run against the approved total.

```sh
deno run --allow-env --allow-net=openrouter.ai --no-remote --no-npm \
  supabase/eval/coach_eval.ts --live --budget-usd=0.96 --smoke
```

The harness reserves four cents before each attempted provider call, without
refunds; maximum 24 requests / $0.96 per process. It rejects concurrent calls,
other models, external tools, images and input over 16,384 UTF-8 bytes. Requests
retain the current server prompts, roles, temperature and reasoning settings,
but lower visible-plus-reasoning output to at most 768 tokens (classifier 256).
Provider routing disables failover and enforces price ceilings of $1.50 per
million input tokens and $7.50 per million output tokens. Response bodies are
bounded to 128 KiB; redirects and retries are disabled. An outage stops the run.

The conservative text-only reservation allows 16,384 input-byte tokens plus
4,096 template/encoding overhead tokens and 768 output tokens: $0.03648 at the
price ceilings, rounded up to $0.04. This assumes the provider honours its token
and routing contract; it is not an independently enforced credit limit on the
shared provider account. No image cost estimate is used: images are blocked.
Review current provider documentation/pricing before each authorised run:
[routing and max_price](https://openrouter.ai/docs/guides/routing/provider-selection#max-price),
[API token limits](https://openrouter.ai/docs/api/reference/overview), and
[Gemini 3.8 Flash](https://openrouter.ai/google/gemini-3.8-flash).

Output JSON includes returned model/provider metadata, available numeric usage,
synthetic user-visible responses, expected outcomes and review criteria. It
omits raw provider errors, reasoning, headers and credentials. Record the Git
commit alongside the artifact. Recipe image generation is intercepted locally
and omitted; no recipe or plan is actually adopted. Streaming uses the real
server parser but the harness buffers the provider transport, so it does not
prove live proxy/chunk timing or deployed auth/RLS.

`technicalPass` only checks response kind and two explicit injection canaries.
Read every answer against its case rubric. A small passing sample is not a
semantic, medical, nutrition, child-safety or legal certification. Real-model image-only,
broader multilingual/obfuscated attacks, multi-turn escalation and qualified
clinical review remain separate work. Model slug + returned provider metadata
identify this run; they do not prove an immutable model build if the provider
does not expose one.

For a separately approved continuation, `--remainder --budget-usd=0.48` runs
only context injection, history injection, minor-risk, then positive plan and
recipe cases. It permits at most ten provider calls and reserves $0.04 per
ordinary/classifier call or $0.07 per structured draft before execution. Drafts
keep their actual server token caps up to 4,096: conservative worst-case cost
is $0.06144, rounded to $0.07. The $0.48 aggregate cap is independent of the
request-count cap. No images, retry or fallback are enabled. All processes must
still be counted against the authorised cumulative budget; this mode is not an
automatic retry. Fixed stderr start/reservation markers and a partial JSON
artifact retain spend evidence on failures without printing raw errors.

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
