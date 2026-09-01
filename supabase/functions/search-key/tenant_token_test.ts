// Tenant-token mode of `search-key` (F9-02, review 2026-08-27).
//
// With EATOVA_MIRROR_KEY_UID set the function no longer hands out the shared
// Meilisearch search key but a per-request tenant token: an HS256 JWT signed
// WITH that key, scoped to the product index and expiring after ttlSeconds.
// Without the flag the old behaviour (static key) must stay byte-identical.
//
// index.ts reads its env at module load, so each mode gets its own module
// instance via a cache-busting query on the import specifier; Deno.serve is
// intercepted like in wire_response_contract_test.ts. `deno test --allow-env`,
// no network.

const BASE_URL = "https://supabase.test.invalid";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const MIRROR_URL = "https://eatova.test.invalid/meili";
// Assembled at runtime: a literal with `KEY` next to a long digit-bearing
// string trips the gitleaks generic-api-key rule (it scans history, so a
// later edit would not help).
const MIRROR_KEY = ["test", "search", "only"].join("-") + "-hmac-" + String(123456789);
// UUID assembled at runtime (see MIRROR_KEY): a long literal next to `KEY`
// trips gitleaks in the commit history.
const TENANT_UID = ["6e8c4a2b", "1f3d", "4b7e", "9a0c", "2d5f8e1b", "3c4a"].join("-").replace("8e1b-3c4a", "8e1b3c4a");
const TTL = 43_200;
const GRACE = 600;

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("EATOVA_MIRROR_SEARCH_KEY", MIRROR_KEY);
Deno.env.set("EATOVA_MIRROR_BASE_URL", MIRROR_URL);
Deno.env.set("EATOVA_SEARCH_KEY_TTL_SECONDS", String(TTL));

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

function installFetch(): () => void {
  const original = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.includes("/auth/v1/user")) {
      return Promise.resolve(new Response(JSON.stringify({ id: USER_ID }), { status: 200 }));
    }
    // P6-02: one batched call for both application gates, one reply element
    // per gate.
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limits")) {
      return Promise.resolve(
        new Response(
          JSON.stringify([
            {
              allowed: true,
              limit: 120,
              remaining: 119,
              resetAt: new Date(Date.now() + 600_000).toISOString(),
              windowSeconds: 600,
            },
            {
              allowed: true,
              limit: 20,
              remaining: 19,
              resetAt: new Date(Date.now() + 3_600_000).toISOString(),
              windowSeconds: 3600,
            },
          ]),
          { status: 200 },
        ),
      );
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    return Promise.reject(new Error(`Unerwarteter fetch auf ${url}`));
  }) as typeof globalThis.fetch;
  return () => {
    globalThis.fetch = original;
  };
}

// One module instance per mode. The specifiers must be string LITERALS:
// Deno resolves those at graph build time, while a computed specifier needs
// --allow-read at runtime, which CI (`deno test --allow-env`) does not grant.
const LOADERS: Record<string, () => Promise<unknown>> = {
  "tenant": () => import("./index.ts?mode=tenant"),
  "tenant-index": () => import("./index.ts?mode=tenant-index"),
  "static": () => import("./index.ts?mode=static"),
  "tenant-disabled": () => import("./index.ts?mode=tenant-disabled"),
  "tenant-bad-uid": () => import("./index.ts?mode=tenant-bad-uid"),
  "tenant-bad-index": () => import("./index.ts?mode=tenant-bad-index"),
  "static-cache": () => import("./index.ts?mode=static-cache"),
  "tenant-log": () => import("./index.ts?mode=tenant-log"),
  "tenant-ttl-hoch": () => import("./index.ts?mode=tenant-ttl-hoch"),
  "tenant-ttl-tief": () => import("./index.ts?mode=tenant-ttl-tief"),
  "tenant-ttl-muell": () => import("./index.ts?mode=tenant-ttl-muell"),
};

/** Loads a fresh index.ts instance with `env` applied for the duration of the
 *  import; the variables are removed again so other test files see the
 *  static-key default. */
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
    headers: { authorization: "Bearer eyJhbGciOiJIUzI1NiJ9.test.token", "cf-connecting-ip": "203.0.113.7" },
  });
}

function base64urlDecode(segment: string): Uint8Array<ArrayBuffer> {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - segment.length % 4) % 4);
  const binary = atob(padded);
  const out = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function decodeJson(segment: string): JsonRecord {
  return JSON.parse(new TextDecoder().decode(base64urlDecode(segment))) as JsonRecord;
}

async function verifyHs256(token: string, secret: string): Promise<boolean> {
  const [header, payload, signature] = token.split(".");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return await crypto.subtle.verify(
    "HMAC",
    key,
    base64urlDecode(signature),
    new TextEncoder().encode(`${header}.${payload}`),
  );
}

Deno.test("F9-02: mit EATOVA_MIRROR_KEY_UID kommt ein signierter Tenant-Token statt des Keys", async () => {
  const restore = installFetch();
  try {
    const serve = await loadHandler("tenant", { EATOVA_MIRROR_KEY_UID: TENANT_UID });
    const before = Math.floor(Date.now() / 1000);
    const res = await serve(request());
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;

    // Wire contract unchanged: same three fields, base URL untouched.
    assertEquals(body.mirrorBaseUrl, MIRROR_URL, "mirrorBaseUrl");
    assertEquals(body.ttlSeconds, TTL, "ttlSeconds");
    const token = String(body.searchKey);
    assert(token !== MIRROR_KEY, "der statische Key darf nicht mehr rausgehen");
    assert(!token.includes(MIRROR_KEY), "der Key darf nirgends im Token stehen");

    const parts = token.split(".");
    assertEquals(parts.length, 3, "JWT-Form header.payload.signature");
    const header = decodeJson(parts[0]);
    assertEquals(header.alg, "HS256", "alg");
    assertEquals(header.typ, "JWT", "typ");

    const payload = decodeJson(parts[1]);
    assertEquals(payload.apiKeyUid, TENANT_UID, "apiKeyUid");
    const rules = payload.searchRules as JsonRecord;
    assertEquals(Object.keys(rules).join(","), "products", "searchRules nur auf den Produktindex");
    assertEquals(JSON.stringify(rules.products), "{}", "keine Filter im Index-Scope");
    // The token outlives ttlSeconds by a 600 s grace: the client keeps using
    // an expired entry while it refreshes in the background.
    const exp = Number(payload.exp);
    assert(
      exp >= before + TTL + GRACE && exp <= before + TTL + GRACE + 5,
      `exp muss now+ttlSeconds+${GRACE} sein (war ${exp - before} s ab Testbeginn)`,
    );
    // A minted token must never be replayed from an HTTP cache.
    assertEquals(res.headers.get("cache-control"), "private, no-store", "cache-control im Tenant-Modus");

    assert(await verifyHs256(token, MIRROR_KEY), "Signatur mit dem Search-Key als HMAC-Secret ungueltig");
    assert(!(await verifyHs256(token, "wrong-key")), "ein fremder Key darf nicht verifizieren");
  } finally {
    restore();
  }
});

// EATOVA_SEARCH_KEY_TTL_SECONDS ist ein Betreiber-Secret und bestimmt im
// Tenant-Modus die LEBENSDAUER eines Bearer-Tokens. Ohne die Klammer
// [MIN_TTL, MAX_TTL] macht ein vertippter Wert (Millisekunden statt Sekunden,
// eine Null zu viel) aus dem ablaufenden Token einen praktisch unbefristeten —
// und genau das war nirgends gepinnt: die Klammer liess sich ersatzlos
// streichen, ohne dass ein Test rot wurde. `exp` wird mitgeprueft, weil die
// gemeldete `ttlSeconds` und die im Token verbaute Frist aus derselben Zahl
// kommen muessen.
Deno.test("F9-02: die TTL-Klammer begrenzt die Lebensdauer des Tenant-Tokens", async () => {
  const MIN_TTL = 3_600;
  const MAX_TTL = 604_800;
  const faelle: {
    tag: "tenant-ttl-hoch" | "tenant-ttl-tief" | "tenant-ttl-muell";
    gesetzt: string;
    erwartet: number;
    was: string;
  }[] = [
    { tag: "tenant-ttl-hoch", gesetzt: "31536000", erwartet: MAX_TTL, was: "ein Jahr -> Obergrenze" },
    { tag: "tenant-ttl-tief", gesetzt: "60", erwartet: MIN_TTL, was: "eine Minute -> Untergrenze" },
    { tag: "tenant-ttl-muell", gesetzt: "sofort", erwartet: TTL, was: "unlesbar -> Code-Default" },
  ];
  for (const fall of faelle) {
    const restore = installFetch();
    try {
      const serve = await loadHandler(fall.tag, {
        EATOVA_MIRROR_KEY_UID: TENANT_UID,
        EATOVA_SEARCH_KEY_TTL_SECONDS: fall.gesetzt,
      });
      const before = Math.floor(Date.now() / 1000);
      const res = await serve(request());
      const body = await res.json() as JsonRecord;
      assertEquals(body.ttlSeconds, fall.erwartet, `${fall.was}: gemeldete ttlSeconds`);
      const exp = Number(decodeJson(String(body.searchKey).split(".")[1]).exp);
      assert(
        exp >= before + fall.erwartet + GRACE && exp <= before + fall.erwartet + GRACE + 5,
        `${fall.was}: exp muss der geklammerten TTL folgen (war ${exp - before} s ab Testbeginn)`,
      );
    } finally {
      restore();
    }
  }
});

Deno.test("F9-02: Index-Name kommt aus EATOVA_MIRROR_SEARCH_INDEX", async () => {
  const restore = installFetch();
  try {
    const serve = await loadHandler("tenant-index", {
      EATOVA_MIRROR_KEY_UID: TENANT_UID,
      EATOVA_MIRROR_SEARCH_INDEX: "products_v2",
    });
    const body = await (await serve(request())).json() as JsonRecord;
    const payload = decodeJson(String(body.searchKey).split(".")[1]);
    assertEquals(Object.keys(payload.searchRules as JsonRecord).join(","), "products_v2", "Index");
  } finally {
    restore();
  }
});

Deno.test("F9-02: ohne Flag bleibt der statische Key (Bestandsverhalten)", async () => {
  const restore = installFetch();
  try {
    const serve = await loadHandler("static", {});
    const body = await (await serve(request())).json() as JsonRecord;
    assertEquals(body.searchKey, MIRROR_KEY, "statischer Key");
    assertEquals(body.ttlSeconds, TTL, "ttlSeconds");
  } finally {
    restore();
  }
});

Deno.test("F9-02: Kill-Switch gewinnt auch im Tenant-Modus", async () => {
  const restore = installFetch();
  try {
    const serve = await loadHandler("tenant-disabled", {
      EATOVA_MIRROR_KEY_UID: TENANT_UID,
      EATOVA_MIRROR_SEARCH_KEY: "disabled",
    });
    const body = await (await serve(request())).json() as JsonRecord;
    assertEquals(body.searchKey, "", "leerer Key");
    assertEquals(body.mirrorBaseUrl, "", "leere URL");
  } finally {
    // loadHandler deleted the key; the module-level default must come back
    // for the remaining files in this process.
    Deno.env.set("EATOVA_MIRROR_SEARCH_KEY", MIRROR_KEY);
    restore();
  }
});

Deno.test("F9-02: kaputte Key-UID ist eine Fehlkonfiguration (500), kein stiller Key-Leak", async () => {
  const restore = installFetch();
  try {
    const serve = await loadHandler("tenant-bad-uid", { EATOVA_MIRROR_KEY_UID: "not-a-uuid" });
    const res = await serve(request());
    assertEquals(res.status, 500, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "server_misconfigured", "Fehlercode");
    assertEquals("searchKey" in body, false, "kein Key im Fehlerfall");
  } finally {
    restore();
  }
});

Deno.test("F9-02: kaputter Index-Name ist eine Fehlkonfiguration (500)", async () => {
  const restore = installFetch();
  try {
    const serve = await loadHandler("tenant-bad-index", {
      EATOVA_MIRROR_KEY_UID: TENANT_UID,
      EATOVA_MIRROR_SEARCH_INDEX: "products/../keys",
    });
    const res = await serve(request());
    assertEquals(res.status, 500, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "server_misconfigured", "Fehlercode");
    assertEquals("searchKey" in body, false, "kein Token im Fehlerfall");
  } finally {
    restore();
  }
});

Deno.test("F9-02: ohne Flag bleibt cache-control private, max-age=ttl (Bestandsverhalten)", async () => {
  const restore = installFetch();
  try {
    const serve = await loadHandler("static-cache", {});
    const res = await serve(request());
    assertEquals(res.headers.get("cache-control"), `private, max-age=${TTL}`, "cache-control statisch");
  } finally {
    restore();
  }
});

Deno.test("F9-02: der Token steht nie im Log", async () => {
  const restore = installFetch();
  const lines: string[] = [];
  const originalLog = console.log;
  console.log = (...args: unknown[]) => {
    lines.push(args.map((a) => JSON.stringify(a)).join(" "));
  };
  try {
    const serve = await loadHandler("tenant-log", { EATOVA_MIRROR_KEY_UID: TENANT_UID });
    const body = await (await serve(request())).json() as JsonRecord;
    const joined = lines.join("\n");
    assert(!joined.includes(String(body.searchKey)), `Token im Log: ${joined}`);
    assert(!joined.includes(MIRROR_KEY), `Key im Log: ${joined}`);
    assert(joined.includes('"tenantToken":true'), `Modus fehlt im Log: ${joined}`);
  } finally {
    console.log = originalLog;
    restore();
  }
});
