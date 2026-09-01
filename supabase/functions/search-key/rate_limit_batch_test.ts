// P6-02 (perf audit 2026-09-01): the two application gates of `search-key`
// travel in ONE consume_edge_rate_limits roundtrip instead of two sequential
// consume_edge_rate_limit calls.
//
// The whole risk of that change sits in the REPLY. The RPC stops at the first
// denial, so it answers with one element per gate ACTUALLY consumed and the
// array may be SHORTER than the input. If the caller ever read a missing
// element as "allowed", a denied IP gate would open the user gate that was
// never consumed — the endpoint would hand out search credentials to exactly
// the caller the limiter just rejected. This file pins the mapping:
//
//   - one call carries both gates, in order, with their own numbers;
//   - a denial answers with THAT gate's 429 and Retry-After, unchanged;
//   - a short reply whose last element is allowed is an outage (500), never a
//     pass.
//
// The deadline half of the change lives in deadline_test.ts (a hanging BATCH
// still fails closed inside the budget); the fail bucket keeps the single-gate
// RPC and is pinned by auth_fail_gate_test.ts.
//
// index.ts reads its env at module load and calls Deno.serve; both handled like
// in tenant_token_test.ts (cache-busting import with a string LITERAL,
// intercepted serve). `deno test --allow-env`, no network.

const BASE_URL = "https://supabase.test.invalid";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const CLIENT_IP = "203.0.113.7";
// Assembled at runtime: a literal next to `KEY` trips the gitleaks
// generic-api-key rule, which scans the HISTORY (see tenant_token_test.ts).
const MIRROR_KEY = ["test", "search", "only"].join("-") + "-batch-" + String(123456789);

// The production defaults both gates carry; the batch must not blur them.
const IP_LIMIT = 120;
const IP_WINDOW = 600;
const USER_LIMIT = 20;
const USER_WINDOW = 3600;

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

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

interface StubOptions {
  /** Reply of the batched RPC. Default: every gate allowed. */
  batchReply?: (gates: JsonRecord[]) => unknown;
}

interface FetchStub {
  /** `p_gates` of every batched call, in call order. */
  batches: JsonRecord[][];
  /** RAW request bodies of the batched calls; PostgREST passes arguments BY
   *  NAME, so the envelope itself is part of the contract. */
  batchBodies: string[];
  /** Calls to the SINGLE-gate RPC — must stay at zero on this path. */
  singleGateCalls: number;
  restore(): void;
}

function installFetch(options: StubOptions = {}): FetchStub {
  const original = globalThis.fetch;
  const stub: FetchStub = {
    batches: [],
    batchBodies: [],
    singleGateCalls: 0,
    restore: () => {
      globalThis.fetch = original;
    },
  };
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.includes("/auth/v1/user")) {
      return Promise.resolve(jsonRes({ id: USER_ID }));
    }
    // The plural check FIRST: the single-gate URL is a prefix of the batch URL,
    // so the other order would swallow every batched call.
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limits")) {
      const raw = typeof init?.body === "string" ? init.body : "{}";
      stub.batchBodies.push(raw);
      const gates = (JSON.parse(raw).p_gates ?? []) as JsonRecord[];
      stub.batches.push(gates);
      const reply = options.batchReply ?? ((all: JsonRecord[]) => all.map((gate) => erlaubt(gate)));
      return Promise.resolve(jsonRes(reply(gates)));
    }
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
      stub.singleGateCalls++;
      return Promise.resolve(jsonRes({ allowed: true, limit: 30, remaining: 29, resetAt: reset(3600), windowSeconds: 3600 }));
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    return Promise.reject(new Error(`Unerwarteter fetch auf ${url}`));
  }) as typeof globalThis.fetch;
  return stub;
}

function reset(windowSeconds: number): string {
  return new Date(Date.now() + windowSeconds * 1000).toISOString();
}

/** One allowed element in the shape the RPC returns. */
function erlaubt(gate: JsonRecord): JsonRecord {
  const limit = Number(gate.limit);
  const windowSeconds = Number(gate.window_seconds);
  return { allowed: true, limit, remaining: limit - 1, resetAt: reset(windowSeconds), windowSeconds };
}

/** One denied element; `remaining` is 0, as the RPC reports it. */
function abgelehnt(gate: JsonRecord): JsonRecord {
  const limit = Number(gate.limit);
  const windowSeconds = Number(gate.window_seconds);
  return { allowed: false, limit, remaining: 0, resetAt: reset(windowSeconds), windowSeconds };
}

/** One index.ts instance for this file; the specifier must be a string LITERAL
 *  (a computed one needs --allow-read, which CI does not grant). */
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
    await import("./index.ts?p6=batch");
  } finally {
    Object.defineProperty(Deno, "serve", original!);
  }
  assert(handler !== null, "index.ts hat Deno.serve nie aufgerufen");
  cachedHandler = handler;
  return handler!;
}

function request(): Request {
  return new Request(`${BASE_URL}/functions/v1/search-key`, {
    method: "GET",
    headers: { authorization: "Bearer eyJhbGciOiJIUzI1NiJ9.test.token", "cf-connecting-ip": CLIENT_IP },
  });
}

Deno.test("P6-02: beide Tore reisen in EINEM Aufruf, in Reihenfolge und mit ihren eigenen Zahlen", async () => {
  const handler = await loadHandler();
  const stub = installFetch();
  try {
    assertEquals((await handler(request())).status, 200, "Status");
    assertEquals(stub.batches.length, 1, "genau ein Gate-Aufruf statt zwei");
    assertEquals(stub.singleGateCalls, 0, "kein Einzel-Gate mehr auf dem Erfolgspfad");

    // PostgREST nimmt das Argument BEIM NAMEN: der Body muss
    // {"p_gates": [...]} sein, kein blankes Array. Eine nachgiebige Attrappe
    // wuerde auf beides 200 antworten — live scheitert nur das eine.
    const rohkoerper = JSON.parse(stub.batchBodies[0]) as JsonRecord;
    assertEquals(Array.isArray(rohkoerper), false, "der Body ist kein blankes Array");
    assertEquals(Object.keys(rohkoerper).join(","), "p_gates", "genau der benannte RPC-Parameter");
    assertEquals(Array.isArray(rohkoerper.p_gates), true, "p_gates traegt das Array");

    const gates = stub.batches[0];
    assertEquals(gates.length, 2, "beide Tore im Batch");
    // Order is contract, not cosmetics: the RPC stops at the first denial, so
    // swapping these would consume the user gate for an IP flood.
    assertEquals(gates[0].scope, "search-key:ip", "1. Tor");
    assertEquals(gates[0].subject, `ip:${CLIENT_IP}`, "IP-Subject");
    assertEquals(gates[0].limit, IP_LIMIT, "IP-Limit");
    assertEquals(gates[0].window_seconds, IP_WINDOW, "IP-Fenster");
    assertEquals(gates[1].scope, "search-key:user", "2. Tor");
    assertEquals(gates[1].subject, USER_ID, "Nutzer-Subject");
    assertEquals(gates[1].limit, USER_LIMIT, "Nutzer-Limit");
    assertEquals(gates[1].window_seconds, USER_WINDOW, "Nutzer-Fenster");
  } finally {
    stub.restore();
  }
});

Deno.test("P6-02: lehnt das IP-Tor ab, kommt genau die IP-Antwort — und das Nutzer-Tor wird nie verbraucht", async () => {
  const handler = await loadHandler();
  // The RPC stops AT the denial: one element for two gates. The second gate
  // has no row, so it must not be read at all.
  const stub = installFetch({ batchReply: (gates) => [abgelehnt(gates[0])] });
  try {
    const res = await handler(request());
    assertEquals(res.status, 429, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "rate_limited", "Fehlercode");
    const limit = body.rateLimit as JsonRecord;
    // The IP gate's own numbers — the user gate's 20/3600 here would mean the
    // wrong gate answered.
    assertEquals(limit.limit, IP_LIMIT, "gemeldetes Limit");
    assertEquals(limit.windowSeconds, IP_WINDOW, "gemeldetes Fenster");
    const retryAfter = Number(res.headers.get("retry-after"));
    assert(
      retryAfter > IP_WINDOW - 10 && retryAfter <= IP_WINDOW,
      `Retry-After muss aus dem IP-resetAt kommen, war ${retryAfter}`,
    );
    // No second roundtrip anywhere: the user gate was neither batched again
    // nor consumed on its own.
    assertEquals(stub.batches.length, 1, "kein Nachschlag-Aufruf");
    assertEquals(stub.singleGateCalls, 0, "kein Einzel-Consume fuer das Nutzer-Tor");
  } finally {
    stub.restore();
  }
});

Deno.test("P6-02: lehnt das Nutzer-Tor ab, kommt die Nutzer-Antwort", async () => {
  const handler = await loadHandler();
  const stub = installFetch({ batchReply: (gates) => [erlaubt(gates[0]), abgelehnt(gates[1])] });
  try {
    const res = await handler(request());
    assertEquals(res.status, 429, "Status");
    const limit = (await res.json() as JsonRecord).rateLimit as JsonRecord;
    assertEquals(limit.limit, USER_LIMIT, "gemeldetes Limit");
    assertEquals(limit.windowSeconds, USER_WINDOW, "gemeldetes Fenster");
    const retryAfter = Number(res.headers.get("retry-after"));
    assert(
      retryAfter > USER_WINDOW - 10 && retryAfter <= USER_WINDOW,
      `Retry-After muss aus dem Nutzer-resetAt kommen, war ${retryAfter}`,
    );
    assertEquals(stub.batches.length, 1, "ein Aufruf");
  } finally {
    stub.restore();
  }
});

Deno.test("P6-02: eine kurze Antwort ohne Ablehnung ist ein Ausfall, kein 'erlaubt'", async () => {
  // The dangerous shape: one element for two gates, and it says allowed. The
  // second gate was never consumed — reading the missing element as a pass
  // would hand out the key without ever having measured the user limit.
  const handler = await loadHandler();
  const stub = installFetch({ batchReply: (gates) => [erlaubt(gates[0])] });
  try {
    const res = await handler(request());
    assertEquals(res.status, 500, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "rate_limit_unavailable", "Fehlercode");
    assertEquals("searchKey" in body, false, "kein Key im Ausfall");
  } finally {
    stub.restore();
  }
});

Deno.test("P6-02: mehr Elemente als Tore ist ebenfalls ein Ausfall", async () => {
  // An array longer than the input cannot be mapped to gates at all — same
  // class as the reshaped body in wire_response_contract_test.ts (E6).
  const handler = await loadHandler();
  const stub = installFetch({
    batchReply: (gates) => [erlaubt(gates[0]), erlaubt(gates[1]), erlaubt(gates[1])],
  });
  try {
    const res = await handler(request());
    assertEquals(res.status, 500, "Status");
    assertEquals((await res.json() as JsonRecord).error, "rate_limit_unavailable", "Fehlercode");
  } finally {
    stub.restore();
  }
});

Deno.test("P6-02: ein Element ohne lesbares allowed bleibt ein Ausfall, kein erfundenes 429", async () => {
  const handler = await loadHandler();
  const stub = installFetch({ batchReply: (gates) => [erlaubt(gates[0]), { limit: USER_LIMIT }] });
  try {
    const res = await handler(request());
    assertEquals(res.status, 500, "Status");
    assertEquals((await res.json() as JsonRecord).error, "rate_limit_unavailable", "Fehlercode");
  } finally {
    stub.restore();
  }
});

// ---------------------------------------------------------------------------
// A6 (review 2026-09-01): the shape guards above were pinned only where a
// broken reply CHANGES the answer by itself. Three shapes did not: an empty
// array, a reply mapped to the wrong gate, and defaults read from the wrong
// gate. All three are silent — they answer 429 or 500 either way, just with
// the wrong numbers or the wrong reason — which is exactly why they need their
// own tests.
// ---------------------------------------------------------------------------

Deno.test("A6: ein leeres Ergebnis-Array ist ein Ausfall, kein internal_error", async () => {
  // The RPC answered 200 with `[]`: not one gate consumed, and nothing to read.
  // Without the explicit length check this runs into the short-reply check
  // BELOW the loop, which reads results[-1] and throws a TypeError — the
  // outer catch then answers the generic 500 internal_error. Same status,
  // wrong reason: the client and the operator would look for a bug in the key
  // path instead of at the limiter.
  const handler = await loadHandler();
  const stub = installFetch({ batchReply: () => [] });
  try {
    const res = await handler(request());
    assertEquals(res.status, 500, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "rate_limit_unavailable", "Fehlercode");
    assertEquals("searchKey" in body, false, "kein Key im Ausfall");
  } finally {
    stub.restore();
  }
});

Deno.test("A6: Element n gehoert zu Tor n — die Absage kommt mit den Zahlen ihres eigenen Tors", async () => {
  // Elements WITHOUT numbers: limit, window and resetAt then come from the gate
  // the element belongs to, and that is the only channel in which the mapping
  // is visible at all. With full numbers per element (the tests above) a
  // reversed mapping answers exactly the same 429 — it would hand the IP
  // gate's Retry-After to a user-gate denial and nobody would notice.
  const handler = await loadHandler();
  const stub = installFetch({ batchReply: () => [{ allowed: true }, { allowed: false }] });
  try {
    const res = await handler(request());
    assertEquals(res.status, 429, "Status");
    const limit = (await res.json() as JsonRecord).rateLimit as JsonRecord;
    assertEquals(limit.limit, USER_LIMIT, "gemeldetes Limit");
    assertEquals(limit.windowSeconds, USER_WINDOW, "gemeldetes Fenster");
    const retryAfter = Number(res.headers.get("retry-after"));
    assert(
      retryAfter > USER_WINDOW - 10 && retryAfter <= USER_WINDOW,
      `Retry-After muss aus dem Nutzer-Fenster stammen, war ${retryAfter}`,
    );
  } finally {
    stub.restore();
  }
});

Deno.test("A6: die Vorgabewerte einer Absage kommen aus IHREM Tor, nicht aus einem anderen", async () => {
  // Counter-check with the SHORT reply: one bare element for two gates. The
  // RPC stopped at the IP gate, so limit, window and Retry-After have to be
  // the IP gate's — a Retry-After of an hour for a ten-minute IP window would
  // lock a client out six times longer than the limiter ever measured.
  const handler = await loadHandler();
  const stub = installFetch({ batchReply: () => [{ allowed: false }] });
  try {
    const res = await handler(request());
    assertEquals(res.status, 429, "Status");
    const limit = (await res.json() as JsonRecord).rateLimit as JsonRecord;
    assertEquals(limit.limit, IP_LIMIT, "gemeldetes Limit");
    assertEquals(limit.windowSeconds, IP_WINDOW, "gemeldetes Fenster");
    const retryAfter = Number(res.headers.get("retry-after"));
    assert(
      retryAfter > IP_WINDOW - 10 && retryAfter <= IP_WINDOW,
      `Retry-After muss aus dem IP-Fenster stammen, war ${retryAfter}`,
    );
  } finally {
    stub.restore();
  }
});
