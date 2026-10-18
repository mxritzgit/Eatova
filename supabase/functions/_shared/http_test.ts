// Tests for the shared HTTP helpers (http.ts). The cross-handler CORS contract
// lives in cors_origin_contract_test.ts; these pin the building blocks.

import { allowedOrigin, allowedOriginsFromEnv, HttpError, jsonResponse, responseHeaders } from "./http.ts";

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

Deno.test("http: only an exact origin is allowed", () => {
  for (const origin of [
    undefined, "null", `${ALLOWED}.attacker.invalid`, "https://sub.app.test.invalid",
    "http://app.test.invalid", "https://app.test.invalid:444", `${ALLOWED}/`, "*",
  ]) {
    assertEquals(allowedOrigin(request(origin), [ALLOWED]), null, `abgelehnt: ${origin}`);
  }
  assertEquals(allowedOrigin(request(ALLOWED), [ALLOWED]), ALLOWED, "exakt");
  assertEquals(allowedOrigin(undefined, [ALLOWED]), null, "ohne Request");
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

Deno.test("http: jsonResponse sets the JSON type and lets extra headers win", async () => {
  const base = responseHeaders(request(ALLOWED), { methods: "GET, OPTIONS", origins: [ALLOWED] });
  const response = jsonResponse({ ok: true }, 200, base, {
    "cache-control": "private, max-age=60",
    "vary": "Origin, Authorization",
  });
  assertEquals(response.status, 200, "Status");
  assertEquals(response.headers.get("content-type"), "application/json; charset=utf-8", "Typ");
  assertEquals(response.headers.get("cache-control"), "private, max-age=60", "Override");
  assertEquals(response.headers.get("vary"), "Origin, Authorization", "Vary-Override");
  assertEquals(await response.json(), { ok: true }, "Body");
  assertEquals(base.get("cache-control"), "no-store", "Basis-Header bleiben unveraendert");
});

Deno.test("http: HttpError carries status, code and the public text", () => {
  const error = new HttpError(503, "auth_unavailable", "Bitte erneut versuchen.");
  assert(error instanceof Error, "ein Error");
  assertEquals([error.status, error.code, error.publicMessage, error.message], [503, "auth_unavailable", "Bitte erneut versuchen.", "auth_unavailable"], "Felder");
});
