// Eatova photo calorie analysis edge function - entrypoint.
//
// Only the Deno.serve wiring; all request logic lives in handler.ts so it can
// be tested without starting a server. Same split as coach-chat.
//
//   handler.ts   - handleRequest() + HTTP/Supabase/provider helpers
//   normalize.ts - model response normalisation (pure, testable)

import { handleRequest } from './handler.ts';

Deno.serve(handleRequest);
