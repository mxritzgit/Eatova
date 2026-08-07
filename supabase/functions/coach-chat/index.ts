// Eatova Coach-Chat Edge Function - Entrypoint.
//
// Bewusst nur die Deno.serve-Verdrahtung: die komplette Request-Logik
// (3-Schichten-Safety, Rate-Limits, Quota, Persistenz) liegt in handler.ts,
// damit sie in handler_test.ts end-to-end getestet werden kann, ohne einen
// Server zu starten. Doku zu den Layern steht im Kopf von handler.ts.
//
//   handler.ts     - handleRequest() + alle HTTP-/Supabase-/LLM-Helfer
//   guardrails.ts  - Layer-2-Kategorien und -Weichen (rein, testbar)
//   prefilter.ts   - Layer-1-Blocklist (rein, testbar)

import { handleRequest } from "./handler.ts";

Deno.serve(handleRequest);
