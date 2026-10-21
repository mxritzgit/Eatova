// Tests for the shared HTTP helpers (http.ts). The exact-origin rule is pinned
// for every handler by cors_origin_contract_test.ts, the JSON/override path by
// search-key/wire_response_contract_test.ts; these pin what only shows here.

import { allowedOriginsFromEnv, responseHeaders } from "./http.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

const ALLOWED = "https://app.test.invalid";

function request(origin?: string): Request {
  return new Request("https://edge.test.invalid/fn", { headers: origin ? { origin } : {} });
}

Deno.test("http: EATOVA_ALLOWED_ORIGINS is a trimmed list; unset means none", () => {
  const previous = Deno.env.get("EATOVA_ALLOWED_ORIGINS");
  try {
    Deno.env.set("EATOVA_ALLOWED_ORIGINS", ` ${ALLOWED} ,, https://second.test.invalid `);
    assertEquals(allowedOriginsFromEnv(), [ALLOWED, "https://second.test.invalid"], "Liste");
    Deno.env.delete("EATOVA_ALLOWED_ORIGINS");
    assertEquals(allowedOriginsFromEnv(), [], "ungesetzt");
  } finally {
    if (previous === undefined) Deno.env.delete("EATOVA_ALLOWED_ORIGINS");
    else Deno.env.set("EATOVA_ALLOWED_ORIGINS", previous);
  }
});

Deno.test("http: security headers always, Allow-Origin only for an allowed origin, never credentials", () => {
  const allowed = responseHeaders(request(ALLOWED), { methods: "POST, OPTIONS", origins: [ALLOWED] });
  assertEquals(allowed.get("access-control-allow-origin"), ALLOWED, "Allow-Origin");
  assertEquals(allowed.get("vary"), "Origin", "Vary");
  assertEquals(allowed.get("access-control-allow-methods"), "POST, OPTIONS", "Methoden");
  for (const [name, value] of [
    ["cache-control", "no-store"],
    ["x-content-type-options", "nosniff"],
    ["x-frame-options", "DENY"],
    ["referrer-policy", "no-referrer"],
    ["access-control-allow-headers", "authorization, apikey, content-type, x-client-info"],
  ]) {
    assertEquals(allowed.get(name), value, name);
  }
  assert(allowed.get("content-security-policy")?.includes("default-src 'none'"), "CSP");
  const foreign = responseHeaders(request("https://evil.test.invalid"), { methods: "GET, OPTIONS", origins: [ALLOWED] });
  assertEquals(foreign.get("access-control-allow-origin"), null, "fremde Origin");
  assertEquals(foreign.get("vary"), null, "kein Vary ohne Allow-Origin");
  for (const headers of [allowed, foreign]) {
    assert(!headers.has("access-control-allow-credentials"), "keine Cookie-Credentials");
  }
});
