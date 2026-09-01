// P6-03 (review 2026-08-29): the rate-limit WINDOWS of search-key must survive
// an operator override.
//
// positiveIntFromEnv caps at EDGE_RATE_LIMIT_MAX_LIMIT (10000) unless the
// caller passes its own `max`. A window beyond ~2.8 h — a day window, say —
// therefore used to fall back to the code default with nothing said anywhere,
// which is the more dangerous direction: the operator believes the tighter
// setting is live. _shared/env_rpc_bounds_test.ts pins the parser; this file
// pins the PRODUCTION caller, which is what was actually missing.
//
// index.ts reads its env at module load, so the test gets its own module
// instance via a cache-busting query on the import specifier (string LITERAL —
// a computed one would need --allow-read, which CI does not grant), with
// Deno.serve intercepted like in wire_response_contract_test.ts.

const BASE_URL = "https://supabase.test.invalid";
const USER_ID = "11111111-1111-4111-8111-111111111111";
// Assembled at runtime: a literal next to `KEY` trips the gitleaks
// generic-api-key rule, which scans the HISTORY (see tenant_token_test.ts).
const MIRROR_KEY = ["test", "search", "only"].join("-") + "-window-" + String(123456789);

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("EATOVA_MIRROR_SEARCH_KEY", MIRROR_KEY);
Deno.env.set("EATOVA_MIRROR_BASE_URL", "https://eatova.test.invalid/meili");

type Handler = (request: Request) => Response | Promise<Response>;
type JsonRecord = Record<string, unknown>;

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

interface FetchStub {
  /** The batch element the function sent for `scope`. */
  params(scope: string): JsonRecord | undefined;
  restore(): void;
}

function installFetch(): FetchStub {
  const consumes: JsonRecord[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.includes("/auth/v1/user")) {
      return Promise.resolve(new Response(JSON.stringify({ id: USER_ID }), { status: 200 }));
    }
    // P6-02: both gates arrive as ONE call with an ordered `p_gates` array;
    // the reply carries one element per gate.
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limits")) {
      const body = JSON.parse(typeof init?.body === "string" ? init.body : "{}") as JsonRecord;
      const gates = (body.p_gates ?? []) as JsonRecord[];
      for (const gate of gates) consumes.push(gate);
      return Promise.resolve(
        new Response(
          JSON.stringify(gates.map((gate) => {
            const windowSeconds = Number(gate.window_seconds);
            return {
              allowed: true,
              limit: Number(gate.limit),
              remaining: Number(gate.limit) - 1,
              resetAt: new Date(Date.now() + windowSeconds * 1000).toISOString(),
              windowSeconds,
            };
          })),
          { status: 200 },
        ),
      );
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    return Promise.reject(new Error(`Unerwarteter fetch auf ${url}`));
  }) as typeof globalThis.fetch;

  return {
    params: (scope: string) => consumes.find((entry) => entry.scope === scope),
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

// One module instance per configuration; the specifiers must be string
// literals.
const LOADERS: Record<string, () => Promise<unknown>> = {
  "day-windows": () => import("./index.ts?p6=day-windows"),
  "over-bound": () => import("./index.ts?p6=over-bound"),
};

async function loadHandler(tag: keyof typeof LOADERS, env: Record<string, string>): Promise<Handler> {
  let handler: Handler | null = null;
  const original = Object.getOwnPropertyDescriptor(Deno, "serve");
  assert(original !== undefined, "Deno.serve existiert nicht");
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    value: (...args: unknown[]) => {
      handler = args.find((a) => typeof a === "function") as Handler;
      return {
        finished: Promise.resolve(),
        shutdown: () => Promise.resolve(),
        ref: () => {},
        unref: () => {},
        addr: { transport: "tcp", hostname: "127.0.0.1", port: 0 },
      };
    },
  });
  for (const [name, value] of Object.entries(env)) Deno.env.set(name, value);
  try {
    await LOADERS[tag]();
  } finally {
    for (const name of Object.keys(env)) Deno.env.delete(name);
    Object.defineProperty(Deno, "serve", original!);
  }
  assert(handler !== null, "index.ts hat Deno.serve nie aufgerufen");
  return handler!;
}

function request(): Request {
  return new Request(`${BASE_URL}/functions/v1/search-key`, {
    method: "GET",
    headers: {
      authorization: "Bearer eyJhbGciOiJIUzI1NiJ9.test.token",
      "cf-connecting-ip": "203.0.113.7",
    },
  });
}

Deno.test("P6-03: gesetzte Tagesfenster kommen bei der RPC an statt still auf den Default zu fallen", async () => {
  const stub = installFetch();
  try {
    const serve = await loadHandler("day-windows", {
      SEARCH_KEY_USER_WINDOW_SECONDS: "86400",
      SEARCH_KEY_IP_WINDOW_SECONDS: "86400",
    });
    assertEquals((await serve(request())).status, 200, "Status");
    // Without the explicit max these were 3600 / 600 — the operator's tighter
    // setting was dead and nothing said so.
    assertEquals(stub.params("search-key:user")?.window_seconds, 86400, "Nutzer-Fenster");
    assertEquals(stub.params("search-key:ip")?.window_seconds, 86400, "IP-Fenster");
  } finally {
    stub.restore();
  }
});

Deno.test("P6-03: ueber der RPC-Obergrenze bleibt es beim Default (und warnt)", async () => {
  const stub = installFetch();
  const warnings: string[] = [];
  const originalWarn = console.warn;
  console.warn = (...args: unknown[]) => {
    warnings.push(args.map((a) => JSON.stringify(a)).join(" "));
  };
  try {
    // 172800 s = 2 days; consume_edge_rate_limit throws above 86400, so the
    // fallback is right — being told about it is the new part.
    const serve = await loadHandler("over-bound", { SEARCH_KEY_USER_WINDOW_SECONDS: "172800" });
    assertEquals((await serve(request())).status, 200, "Status");
    assertEquals(stub.params("search-key:user")?.window_seconds, 3600, "Default-Fenster");
    const joined = warnings.join("\n");
    assert(joined.includes("SEARCH_KEY_USER_WINDOW_SECONDS"), `keine Warnung: ${joined}`);
    // E2 (Review 2026-08-31): der Rohwert steht seit der CWE-532-Schwaerzung
    // nicht mehr drin — Grund, Laenge und Grenze sagen dasselbe aus.
    assert(!joined.includes("172800"), `verworfener Rohwert im Log: ${joined}`);
    assert(joined.includes("out of range"), `Grund fehlt in der Warnung: ${joined}`);
    assert(joined.includes("86400"), `die verletzte Grenze fehlt in der Warnung: ${joined}`);
  } finally {
    console.warn = originalWarn;
    stub.restore();
  }
});
