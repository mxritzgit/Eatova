// Pre-auth fail limiter of `search-key` (F-28-1, review 2026-08-28).
//
// The gateway's verify_jwt stops random garbage, but a signature-valid yet
// revoked token (signed-out session, deleted account — free via OTP signup)
// reaches the function and used to cost an uncapped /auth/v1/user
// introspection. Like coach-chat, failures are now capped per IP through
// ../_shared/auth_fail_gate.ts BEFORE anything else happens.
//
// index.ts reads its env at module load and calls Deno.serve; both are
// handled like in tenant_token_test.ts (cache-busting import, intercepted
// serve). `deno test --allow-env`, no network.

const BASE_URL = "https://supabase.test.invalid";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const MIRROR_URL = "https://eatova.test.invalid/meili";
const MIRROR_KEY = "test-search-only-key-0123456789";
const ANON_KEY = "test-anon-key";
const CLIENT_IP = "203.0.113.7";

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", ANON_KEY);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("EATOVA_MIRROR_SEARCH_KEY", MIRROR_KEY);
Deno.env.set("EATOVA_MIRROR_BASE_URL", MIRROR_URL);

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

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

interface StubOptions {
  /** HTTP status of the /auth/v1/user lookup (default: 200 with a user). */
  authStatus?: number;
  /** Budget of search-key:auth-fail; the stub counts like the atomic RPC. */
  authFailBudget?: number;
  /** HTTP status of the consume for the auth-fail scope (limiter outage). */
  authFailGateStatus?: number;
  /** `id` the auth lookup reports on a 200. The id becomes the subject of the
   *  user gate, so an unusable one must not get that far. */
  authUserId?: unknown;
}

interface FetchStub {
  authLookups: number;
  /** Every consumed gate in order, always in the single-gate `p_*` shape.
   *  Since P6-02 the two application gates arrive as ONE batched
   *  consume_edge_rate_limits call and are unpacked here, while the fail
   *  bucket keeps the single-gate RPC on purpose (../_shared/auth_fail_gate.ts
   *  consumes only AFTER a failed lookup). */
  gates: JsonRecord[];
  /** Outbound gate CALLS, not gates: this is what P6-02 halves. */
  gateCalls: number;
  restore: () => void;
}

function installFetch(options: StubOptions = {}): FetchStub {
  const original = globalThis.fetch;
  const stub: FetchStub = {
    authLookups: 0,
    gates: [],
    gateCalls: 0,
    restore: () => {
      globalThis.fetch = original;
    },
  };
  let authFailConsumes = 0;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.includes("/auth/v1/user")) {
      stub.authLookups++;
      if (options.authStatus !== undefined) {
        return Promise.resolve(jsonRes({ message: "invalid token" }, options.authStatus));
      }
      return Promise.resolve(
        jsonRes("authUserId" in options ? { id: options.authUserId } : { id: USER_ID }),
      );
    }
    // P6-02: the batched application gates. Recorded in the same `p_*` shape
    // as the single-gate RPC so the assertions below stay about the gates
    // themselves, not about how many roundtrips carry them. Checked first —
    // the single-gate URL is a prefix of this one.
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limits")) {
      stub.gateCalls++;
      const gates = (JSON.parse(String(init?.body)).p_gates ?? []) as JsonRecord[];
      return Promise.resolve(jsonRes(gates.map((gate) => {
        stub.gates.push({
          p_scope: gate.scope,
          p_subject: gate.subject,
          p_limit: gate.limit,
          p_window_seconds: gate.window_seconds,
        });
        const limit = Number(gate.limit);
        const windowSeconds = Number(gate.window_seconds);
        return {
          allowed: true,
          limit,
          remaining: limit - 1,
          resetAt: new Date(Date.now() + windowSeconds * 1000).toISOString(),
          windowSeconds,
        };
      })));
    }
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
      stub.gateCalls++;
      const params = JSON.parse(String(init?.body)) as JsonRecord;
      stub.gates.push(params);
      const limit = Number(params.p_limit);
      const windowSeconds = Number(params.p_window_seconds);
      const resetAt = new Date(Date.now() + windowSeconds * 1000).toISOString();
      if (params.p_scope === "search-key:auth-fail") {
        if (options.authFailGateStatus !== undefined) {
          return Promise.resolve(jsonRes({ message: "limiter down" }, options.authFailGateStatus));
        }
        authFailConsumes++;
        const budget = options.authFailBudget ?? Number.POSITIVE_INFINITY;
        return Promise.resolve(jsonRes({
          allowed: authFailConsumes <= budget,
          limit,
          remaining: Math.max(limit - authFailConsumes, 0),
          resetAt,
          windowSeconds,
        }));
      }
      return Promise.resolve(jsonRes({ allowed: true, limit, remaining: limit - 1, resetAt, windowSeconds }));
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    return Promise.reject(new Error(`Unerwarteter fetch auf ${url}`));
  }) as typeof globalThis.fetch;
  return stub;
}

/** One index.ts instance for this file: the module evaluates (and calls
 *  Deno.serve) only once per specifier, and every test here wants the same
 *  env. The specifier must be a string LITERAL (see tenant_token_test.ts). */
let cachedHandler: Handler | null = null;

async function loadHandler(): Promise<Handler> {
  if (cachedHandler) return cachedHandler;
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
  try {
    await import("./index.ts?mode=auth-fail");
  } finally {
    Object.defineProperty(Deno, "serve", original!);
  }
  assert(handler !== null, "index.ts hat Deno.serve nie aufgerufen");
  cachedHandler = handler;
  return handler!;
}

function request(token = "eyJhbGciOiJIUzI1NiJ9.test.token", withIp = true): Request {
  const headers: Record<string, string> = { authorization: `Bearer ${token}` };
  if (withIp) headers["cf-connecting-ip"] = CLIENT_IP;
  return new Request(`${BASE_URL}/functions/v1/search-key`, { method: "GET", headers });
}

Deno.test("F-28-1: wiederholte Auth-Fehlschlaege verbrauchen das Fail-Bucket bis 429", async () => {
  const handler = await loadHandler();
  const stub = installFetch({ authStatus: 401, authFailBudget: 2 });
  try {
    const first = await handler(request());
    assertEquals(first.status, 401, "1. Fehlversuch: Status");
    const second = await handler(request());
    assertEquals(second.status, 401, "2. Fehlversuch: Status");
    const third = await handler(request());
    assertEquals(third.status, 429, "3. Fehlversuch: Status");
    const body = await third.json() as JsonRecord;
    assertEquals(body.error, "rate_limited", "Fehlercode");
    assert(third.headers.get("retry-after") !== null, "retry-after fehlt");

    assertEquals(stub.authLookups, 3, "Auth-Lookups");
    assertEquals(stub.gates.length, 3, "nur das Fail-Bucket wurde konsumiert");
    assert(stub.gates.every((g) => g.p_scope === "search-key:auth-fail"), "keine ip/user-Gates auf dem Fehlschlag-Pfad");
    assertEquals(stub.gates[0].p_limit, 30, "konservatives Limit (30/h)");
    assertEquals(stub.gates[0].p_window_seconds, 3600, "Stunden-Fenster");
    assertEquals(stub.gates[0].p_subject, `ip:${CLIENT_IP}`, "Subject = Client-IP");
  } finally {
    stub.restore();
  }
});

Deno.test("F-28-1: ohne IP-Header landet der Fehlschlag im dokumentierten anon-Fallback", async () => {
  const handler = await loadHandler();
  const stub = installFetch({ authStatus: 401, authFailBudget: 5 });
  try {
    const res = await handler(request(undefined, false));
    assertEquals(res.status, 401, "Status");
    assertEquals(stub.gates[0]?.p_subject, "uid:anon", "Fallback-Subject");
  } finally {
    stub.restore();
  }
});

Deno.test("F-28-1: erfolgreiche Auth beruehrt das Fail-Bucket nicht", async () => {
  const handler = await loadHandler();
  const stub = installFetch({ authFailBudget: 0 });
  try {
    const res = await handler(request());
    assertEquals(res.status, 200, "Status");
    assertEquals(
      stub.gates.map((g) => g.p_scope).join(","),
      "search-key:ip,search-key:user",
      "nur die beiden Anwendungs-Gates",
    );
    // P6-02: dieselben zwei Tore, aber in EINEM Roundtrip.
    assertEquals(stub.gateCalls, 1, "ein Gate-Aufruf fuer beide Tore");
  } finally {
    stub.restore();
  }
});

Deno.test("F-28-1: der Anon-Key kostet weder Lookup noch Consume", async () => {
  // Rejected locally, so it must not be able to fill the fail bucket either.
  const handler = await loadHandler();
  const stub = installFetch({ authFailBudget: 0 });
  try {
    const res = await handler(request(ANON_KEY));
    assertEquals(res.status, 401, "Status");
    assertEquals(stub.authLookups, 0, "kein Auth-Lookup");
    assertEquals(stub.gates.length, 0, "kein Consume");
  } finally {
    stub.restore();
  }
});

Deno.test("F-28-1: eine 200 OHNE brauchbare Id ist kein Login — und kein Fail-Bucket-Treffer", async () => {
  // Die dritte Antwortform von GoTrue: HTTP 200, aber nichts Verwertbares im
  // Body. Zwei Zusicherungen an einer Stelle, beide waren ungepinnt:
  //   * es ist KEIN Login — die Id wird zum Subject des Nutzer-Tors, eine
  //     leere oder abgeschnittene faende jeder Aufrufer im selben Bucket
  //     wieder;
  //   * es ist auch KEIN Fehlschlag im Sinne des Fail-Buckets: hier wurde
  //     nichts verstaerkt, und ein kaputter Auth-Server duerfte sonst ganze
  //     IPs mit 429 belegen (Regel in ../_shared/auth_fail_gate.ts).
  for (const id of [undefined, "", "kurz", 12345, null]) {
    const handler = await loadHandler();
    const stub = installFetch({ authUserId: id, authFailBudget: 0 });
    try {
      const res = await handler(request());
      assertEquals(res.status, 401, `id=${JSON.stringify(id)}: Status`);
      assertEquals(
        (await res.json() as JsonRecord).error,
        "invalid_user_token",
        `id=${JSON.stringify(id)}: Fehlercode`,
      );
      assertEquals(stub.gates.length, 0, `id=${JSON.stringify(id)}: kein Consume`);
    } finally {
      stub.restore();
    }
  }
});

Deno.test("F-28-1: Limiter-Ausfall am Fail-Bucket blockiert die 401 nicht", async () => {
  const handler = await loadHandler();
  const stub = installFetch({ authStatus: 401, authFailGateStatus: 500 });
  try {
    const res = await handler(request());
    assertEquals(res.status, 401, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "invalid_user_token", "Fehlercode");
    assertEquals(stub.gates.length, 1, "der Consume wurde versucht");
  } finally {
    stub.restore();
  }
});
