import { handleRequest as coach } from "../coach-chat/handler.ts";
import { handleRequest as analyze } from "../analyze-meal/handler.ts";
import { PNG_BASE64 } from "../analyze-meal/image_fixtures.ts";
import { userToken } from "./auth_test_fixtures.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const BASE = "https://request-fields.invalid";
const unexpectedFields = ["user_id", "tenant_id", "isAdmin", "isPremium", "role", "premium", "credits", "model", "messages", "tools", "__proto__", "unknownField"];
Deno.env.set("SUPABASE_URL", BASE);
Deno.env.set("SUPABASE_ANON_KEY", "synthetic-anon");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "synthetic-service");
Deno.env.set("OPENROUTER_API_KEY", "synthetic-provider");

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

for (const [name, handler] of [["coach-chat", coach], ["analyze-meal", analyze]] as const) {
  for (const field of unexpectedFields) {
    Deno.test(`${name}: rejects request field ${field} before protected effects`, async () => {
      const original = globalThis.fetch;
      let sideEffects = 0;
      let attempts = 0;
      globalThis.fetch = ((resource: string | URL | Request, init?: RequestInit) => {
        const url = String(resource);
        if (url === `${BASE}/auth/v1/user`) return Promise.resolve(json({ id: USER }));
        if (url.endsWith("/prune_edge_rate_limits")) return Promise.resolve(new Response(null, { status: 204 }));
        if (url.endsWith("/consume_edge_rate_limits")) {
          const gates = JSON.parse(String(init?.body)).p_gates;
          for (const gate of gates) {
            if (!String(gate.scope).endsWith(":ip") && !String(gate.scope).endsWith(":user")) sideEffects++;
            else attempts++;
          }
          return Promise.resolve(json(gates.map((gate: Record<string, number>) => ({ allowed: true,
            limit: gate.limit, remaining: gate.limit - 1, windowSeconds: gate.window_seconds,
            resetAt: new Date(Date.now() + gate.window_seconds * 1000).toISOString() }))));
        }
        sideEffects++;
        return Promise.resolve(json({ error: "synthetic operation must not be reached" }, 500));
      }) as typeof globalThis.fetch;
      try {
        const body = name === "coach-chat" ? { message: "How can I begin training?", [field]: "synthetic" }
          : { imageBase64: PNG_BASE64, [field]: "synthetic" };
        const response = await handler(new Request(`${BASE}/functions/v1/${name}`, {
          method: "POST", headers: { authorization: `Bearer ${userToken(USER)}`, "content-type": "application/json" },
          body: JSON.stringify(body),
        }));
        const data = await response.json();
        check(response.status === 400 && data.error === "invalid_body", "Unknown fields must return a neutral protocol error");
        check(attempts === 2, "Invalid requests still count against the attempt limits");
        check(sideEffects === 0, "Invalid fields reached a session, day quota, or provider operation");
      } finally {
        globalThis.fetch = original;
      }
    });
  }
}
