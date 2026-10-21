// No network permission: authorization is deliberately absent in these tests.
// Exact allowed origins on preflight and 401 responses are pinned for all
// functions in ../_shared/cors_origin_contract_test.ts; this file keeps the
// coach-specific Vary and per-request origin cases.
//
// handler.ts reads the allowed origins once at module load. Environment
// variables are process-wide and outlive this file in a suite run, so the
// list is restored right after the import instead of leaking into later files.
const previousOrigins = Deno.env.get("EATOVA_ALLOWED_ORIGINS");
Deno.env.set("EATOVA_ALLOWED_ORIGINS", "https://allowed.example,https://second.example");
Deno.env.set("SUPABASE_URL", "https://synthetic.invalid");
Deno.env.set("SUPABASE_ANON_KEY", "synthetic-public");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "synthetic-service");
Deno.env.set("ANTHROPIC_API_KEY", "synthetic-anthropic");
Deno.env.set("OPENROUTER_API_KEY", "synthetic-provider");
const { handleRequest } = await import("./handler.ts");
if (previousOrigins === undefined) Deno.env.delete("EATOVA_ALLOWED_ORIGINS");
else Deno.env.set("EATOVA_ALLOWED_ORIGINS", previousOrigins);

function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
function request(origin: string | undefined, method = "POST") {
  return new Request("https://synthetic.invalid/functions/v1/coach-chat", {
    method, headers: origin === undefined ? {} : { Origin: origin },
  });
}

Deno.test("Coach CORS: unlisted, null and absent origins never receive access", async () => {
  for (const origin of ["https://allowed.example.evil.test", "https://evil.test", "null", undefined]) {
    for (const method of ["OPTIONS", "POST"]) {
      const response = await handleRequest(request(origin, method));
      assert(response.headers.get("Access-Control-Allow-Origin") === null, "Unlisted origin gained access");
      assert(response.headers.get("Vary")?.split(",").some((v) => v.trim().toLowerCase() === "origin"), "Vary must include Origin even for a denied origin");
    }
  }
});

Deno.test("Coach CORS: concurrent requests do not share mutable origin state", async () => {
  const origins = ["https://allowed.example", "https://evil.test", "https://second.example", undefined];
  const responses = await Promise.all(origins.map((origin) => handleRequest(request(origin))));
  responses.forEach((response, index) => assert(response.headers.get("Access-Control-Allow-Origin") ===
    (index === 0 || index === 2 ? origins[index] : null), "Origin crossed request boundary"));
});
