// Eatova Coach-Chat Edge Function - Entrypoint.
//
// Only the Deno.serve wiring: all request logic (3-layer safety, rate
// limits, quota, persistence) lives in handler.ts so handler_test.ts can
// drive it end-to-end without starting a server. Layer docs: handler.ts.
//
//   handler.ts     - handleRequest() + all HTTP/Supabase/LLM helpers
//   guardrails.ts  - layer-2 categories and branches (pure, testable)
//   prefilter.ts   - layer-1 blocklist (pure, testable)

import { handleRequest } from "./handler.ts";

Deno.serve(handleRequest);
