import { handleRequest as coach } from "../coach-chat/handler.ts";
import { handleRequest as analyze } from "../analyze-meal/handler.ts";
import { userToken } from "./auth_test_fixtures.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const BASE = "https://auth-context.invalid";
type Handler = (request: Request) => Response | Promise<Response>;
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}
Deno.env.set("SUPABASE_URL", BASE);
Deno.env.set("SUPABASE_ANON_KEY", "synthetic-anon");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "synthetic-service");
Deno.env.set("OPENROUTER_API_KEY", "synthetic-provider");
Deno.env.set("EATOVA_MIRROR_SEARCH_KEY", "synthetic-search");
Deno.env.delete("EATOVA_MIRROR_KEY_UID");

let search: Handler | undefined;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: true, value: (handler: Handler) => { search = handler; return {}; } });
try { await import("../search-key/index.ts?user-token-context"); }
finally { Object.defineProperty(Deno, "serve", serve); }
assert(search, "Search handler was not captured");

const cases = [
  { name: "normal audience", token: () => userToken(USER), admitted: true },
  { name: "single audience array", token: () => userToken(USER, { aud: ["authenticated"] }), admitted: true },
  { name: "other audience", token: () => userToken(USER, { aud: "service_role" }), admitted: false },
  { name: "additional audience", token: () => userToken(USER, { aud: ["authenticated", "other"] }), admitted: false },
  { name: "missing audience", token: () => userToken(USER, { aud: undefined }), admitted: false },
  { name: "identity mismatch", token: () => userToken(OTHER), admitted: false },
  { name: "missing expiration", token: () => userToken(USER, { exp: undefined }), admitted: false },
  { name: "non-numeric expiration", token: () => userToken(USER, { exp: "never" }), admitted: false },
  { name: "opaque bearer", token: () => "opaque-synthetic-bearer", admitted: false },
  { name: "Auth rejects matching claims", token: () => userToken(USER), admitted: false, authStatus: 401 },
];
for (const [name, handler] of [["coach-chat", coach], ["analyze-meal", analyze], ["search-key", search]] as const) {
  for (const test of cases) {
    Deno.test(`${name}: verified token context - ${test.name}`, async () => {
      const original = globalThis.fetch;
      let lookups = 0;
      let applicationGates = 0;
      let unexpected = 0;
      globalThis.fetch = ((resource: string | URL | Request, init?: RequestInit) => {
        const url = String(resource);
        if (url === `${BASE}/auth/v1/user`) {
          lookups++;
          return Promise.resolve(json({ id: USER }, test.authStatus ?? 200));
        }
        if (url.endsWith("/consume_edge_rate_limit")) {
          return Promise.resolve(json({ allowed: true, limit: 120, remaining: 119, resetAt: new Date(Date.now() + 600_000).toISOString(), windowSeconds: 600 }));
        }
        if (url.endsWith("/consume_edge_rate_limits")) {
          applicationGates++;
          const gate = JSON.parse(String(init?.body)).p_gates[0];
          return Promise.resolve(json([{ allowed: false, limit: gate.limit, remaining: 0,
            resetAt: new Date(Date.now() + gate.window_seconds * 1000).toISOString(), windowSeconds: gate.window_seconds }]));
        }
        unexpected++;
        return Promise.reject(new Error("Protected data or provider call was not authorized by this probe"));
      }) as typeof globalThis.fetch;
      try {
        const method = name === "search-key" ? "GET" : "POST";
        const response = await handler(new Request(`${BASE}/functions/v1/${name}`, {
          method, headers: { authorization: `Bearer ${test.token()}`, "content-type": "application/json" },
          ...(method === "POST" ? { body: JSON.stringify({ message: "Synthetic request", imageBase64: "invalid" }) } : {}),
        }));
        const body = await response.json();
        assert(response.status === (test.admitted ? 429 : 401), `${name}/${test.name}: unexpected status ${response.status}`);
        assert(lookups === 1, "Context checks must not substitute for Auth verification");
        assert(applicationGates === (test.admitted ? 1 : 0), "Rejected context must stop before application operations");
        assert(unexpected === 0, "Unexpected side effect");
        assert(!("searchKey" in body), "Rejected request leaked search credentials");
      } finally {
        globalThis.fetch = original;
      }
    });
  }
}
