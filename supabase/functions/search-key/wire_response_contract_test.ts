// Wire test for the `search-key` response envelope.
//
// `index.ts` returns `{ mirrorBaseUrl, searchKey, ttlSeconds }`. Renaming a
// field (e.g. to snake_case) makes the Dart client in
// `lib/src/services/search_credentials.dart` return `null` — and by the
// fetcher's contract `null` means "keep what you have", not "disable". Key
// rotation would then be permanently and silently dead, with nothing turning
// red.
//
// `test/services/search_credentials_test.dart` never crosses the JSON
// boundary (it injects its own fetcher and even uses the snake_case
// PERSISTENCE format), so it cannot catch this.
//
// This test loads `index.ts` unchanged (intercepting Deno.serve to grab the
// real handler), feeds it a real Request, and runs the real body through a
// replica of the Dart parser, asserting it does not yield `null`.
//
// WHAT THIS FILE CAN AND CANNOT SEE. It runs the REAL function against a
// REPLICA client, so it catches a rename on the SERVER side only. KLIENT_FELDER
// below is a constant in this file, not a reading of the Dart source, so a
// rename in the CLIENT cannot turn it red — this file would keep asserting the
// old names against a function that still emits them, and stay green while the
// contract broke.
//
// That other direction lives in `test/wire_search_key_envelope_test.dart`,
// which runs inside `flutter test` (a required check, with file access):
// it EXTRACTS the field names from `search_credentials.dart`, requires
// `index.ts` to emit every one of them, and additionally serves a body built from
// the FUNCTION's names to the REAL `EdgeFunctionSearchKeyFetcher` over
// loopback. Between the two files each side is once real and once replicated.
//
// This file previously carried a sixth test that read the Dart source itself.
// It asked `Deno.permissions.query` for read access and returned silently
// without it — and CI runs `deno test --allow-env` (see
// .github/workflows/security.yml), so it never once executed there while still
// reporting `ok`. It was removed rather than granted `--allow-read`: the Dart
// test states the same thing more sharply (extraction instead of a hand-written
// constant), and the whole Deno suite deliberately runs without file access —
// `tenant_token_test.ts` documents its string-literal import specifiers on
// exactly that basis.
//
// Runs with `deno test --allow-env` like CI. No network: `Deno.serve` never
// executes.

const BASE_URL = "https://supabase.test.invalid";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const USER_TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test.token";
const MIRROR_URL = "https://eatova.test.invalid/meili";
const MIRROR_KEY = "test-search-only-key-0123456789";
const TTL = "43200";

/** Fields the Dart client reads from the body. Mirrored by hand from
 *  lib/src/services/search_credentials.dart, `_fetch()`; kept in step by
 *  test/wire_search_key_envelope_test.dart, which reads that source for real. */
const KLIENT_FELDER = {
  baseUrl: "mirrorBaseUrl",
  searchKey: "searchKey",
  ttl: "ttlSeconds",
} as const;

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("EATOVA_MIRROR_SEARCH_KEY", MIRROR_KEY);
Deno.env.set("EATOVA_MIRROR_BASE_URL", MIRROR_URL);
Deno.env.set("EATOVA_SEARCH_KEY_TTL_SECONDS", TTL);

type Handler = (request: Request) => Response | Promise<Response>;

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(
      `${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`,
    );
  }
}

/** Answers the three Supabase calls `search-key` makes internally. */
function installFetch(options: { rateLimitBody?: unknown } = {}): () => void {
  const original = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request): Promise<Response> => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.href
      : input.url;

    if (url.includes("/auth/v1/user")) {
      return Promise.resolve(
        new Response(JSON.stringify({ id: USER_ID }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      );
    }
    // P6-02: the two application gates travel as ONE batched call, so the
    // reply is an ARRAY with one element per gate.
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limits")) {
      return Promise.resolve(
        new Response(
          JSON.stringify(
            options.rateLimitBody ?? [
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
            ],
          ),
          { status: 200, headers: { "content-type": "application/json" } },
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

/** Captures the handler passed to `Deno.serve` instead of binding a port, so
 *  the test runs without `--allow-net` against the real index.ts handler. */
let handler: Handler | null = null;

async function ladeHandler(): Promise<Handler> {
  if (handler) return handler;

  // `Deno.serve` is a getter without a setter but configurable, hence
  // defineProperty; the descriptor is restored exactly afterwards.
  const original = Object.getOwnPropertyDescriptor(Deno, "serve");
  assert(original !== undefined, "Deno.serve existiert nicht");

  Object.defineProperty(Deno, "serve", {
    configurable: true,
    value: (...args: unknown[]) => {
      const kandidat = args.find((a) => typeof a === "function");
      assert(
        typeof kandidat === "function",
        "Deno.serve wurde ohne Handler-Funktion aufgerufen",
      );
      handler = kandidat as Handler;
      // An HttpServer-shaped object so nothing trips over it.
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
    await import("./index.ts");
  } finally {
    Object.defineProperty(Deno, "serve", original!);
  }

  assert(handler !== null, "index.ts hat Deno.serve nie aufgerufen");
  return handler!;
}

function anfrage(): Request {
  return new Request(`${BASE_URL}/functions/v1/search-key`, {
    method: "GET",
    headers: {
      authorization: `Bearer ${USER_TOKEN}`,
      apikey: "test-anon-key",
      "cf-connecting-ip": "203.0.113.7",
    },
  });
}

/**
 * Faithful replica of `EdgeFunctionSearchKeyFetcher._fetch()`
 * (search_credentials.dart). Returns `null` in exactly the same cases as the
 * client, where `null` means "keep what you have" — i.e. no rotation, ever.
 */
function clientParse(
  status: number,
  body: string,
): { baseUrl: string; searchKey: string; ttlSeconds: number } | null {
  if (status < 200 || status >= 300) return null;
  let decoded: unknown;
  try {
    decoded = JSON.parse(body);
  } catch {
    return null;
  }
  if (typeof decoded !== "object" || decoded === null) return null;
  const map = decoded as Record<string, unknown>;
  const baseUrl = map[KLIENT_FELDER.baseUrl];
  const searchKey = map[KLIENT_FELDER.searchKey];
  if (typeof baseUrl !== "string" || typeof searchKey !== "string") return null;
  const ttlRaw = map[KLIENT_FELDER.ttl];
  return {
    baseUrl: baseUrl.trim(),
    searchKey: searchKey.trim(),
    // The client falls back to 12 h for a missing or mistyped TTL.
    ttlSeconds: typeof ttlRaw === "number" ? Math.round(ttlRaw) : 43200,
  };
}

Deno.test("search-key: der Client kann die echte Antwort ueberhaupt lesen", async () => {
  const wiederherstellen = installFetch();
  try {
    const serve = await ladeHandler();
    const antwort = await serve(anfrage());
    const koerper = await antwort.text();

    assertEquals(antwort.status, 200, "Status");

    const gelesen = clientParse(antwort.status, koerper);
    assert(
      gelesen !== null,
      "Der Dart-Client haette hier `null` bekommen — und `null` heisst " +
        "'behalte, was du hast'. Die Key-Rotation waere damit still und " +
        "dauerhaft tot. Body war: " + koerper,
    );
    assertEquals(gelesen!.baseUrl, MIRROR_URL, "mirrorBaseUrl");
    assertEquals(gelesen!.searchKey, MIRROR_KEY, "searchKey");
    assertEquals(gelesen!.ttlSeconds, Number(TTL), "ttlSeconds");
  } finally {
    wiederherstellen();
  }
});

Deno.test("search-key: kein Feld traegt eine zweite Schreibweise", async () => {
  const wiederherstellen = installFetch();
  try {
    const serve = await ladeHandler();
    const antwort = await serve(anfrage());
    const map = JSON.parse(await antwort.text()) as Record<string, unknown>;
    const schluessel = Object.keys(map);

    for (const feld of Object.values(KLIENT_FELDER)) {
      assert(
        schluessel.includes(feld),
        `Der Body traegt "${feld}" nicht. Vorhanden: ${schluessel.join(", ")}. ` +
          "Ein umbenanntes Feld macht die Rotation still und dauerhaft tot.",
      );
    }
    // snake_case is the likely rename: every other Supabase payload here uses
    // it.
    for (const verboten of ["mirror_base_url", "search_key", "ttl_seconds"]) {
      assert(
        !schluessel.includes(verboten),
        `Der Body traegt "${verboten}". Der Client liest camelCase — eine ` +
          "zweite Schreibweise bedeutet, dass eine der beiden Seiten falsch ist.",
      );
    }
  } finally {
    wiederherstellen();
  }
});

Deno.test("search-key: ttlSeconds und cache-control laufen nicht auseinander", async () => {
  const wiederherstellen = installFetch();
  try {
    const serve = await ladeHandler();
    const antwort = await serve(anfrage());
    const map = JSON.parse(await antwort.text()) as Record<string, unknown>;

    const cacheControl = antwort.headers.get("cache-control") ?? "";
    assertEquals(
      cacheControl,
      `private, max-age=${map[KLIENT_FELDER.ttl]}`,
      "cache-control muss der ausgelieferten TTL folgen",
    );
    assert(
      !cacheControl.includes("public"),
      "Der Body traegt einen Credential — er darf nie in einen geteilten Cache",
    );
    // `private, max-age` erlaubt einen Treffer aus dem Cache. Ohne
    // Authorization im Cache-Schluessel kann der Treffer einem ANDEREN Nutzer
    // gehoeren — dieselbe URL, dieselbe Methode, anderes Token. Das war der
    // Grund fuer den Header und die einzige Zusicherung, die ihn haelt.
    const vary = antwort.headers.get("vary") ?? "";
    assert(
      vary.toLowerCase().split(",").map((teil) => teil.trim()).includes("authorization"),
      `Authorization gehoert in den Cache-Schluessel, vary war "${vary}"`,
    );
  } finally {
    wiederherstellen();
  }
});

Deno.test("search-key: der Key steht nie im Log", async () => {
  const wiederherstellen = installFetch();
  const gesammelt: string[] = [];
  const echtesLog = console.log;
  console.log = (...args: unknown[]) => {
    gesammelt.push(args.map((a) => JSON.stringify(a)).join(" "));
  };
  try {
    const serve = await ladeHandler();
    await serve(anfrage());
    const zeilen = gesammelt.join("\n");
    assert(
      !zeilen.includes(MIRROR_KEY),
      `Der Search-Key ist im Log gelandet: ${zeilen}`,
    );
  } finally {
    console.log = echtesLog;
    wiederherstellen();
  }
});

Deno.test(
  "Sentinel-Rest E6: kaputter Rate-Limit-Shape -> 500 rate_limit_unavailable statt erfundenem 429",
  async () => {
    // `data.allowed === true` turned an empty or reshaped RPC body into
    // `allowed: false`, so the client got a 429 with invented rateLimit
    // numbers. A broken shape is a limiter outage, not a limit. Since P6-02
    // the batched reply must be an ARRAY — an object is exactly that case.
    const handlerFn = await ladeHandler();
    const restore = installFetch({ rateLimitBody: {} });
    try {
      const res = await handlerFn(anfrage());
      assertEquals(res.status, 500, "Status");
      const body = JSON.parse(await res.text()) as Record<string, unknown>;
      assertEquals(body.error, "rate_limit_unavailable", "Fehlercode");
    } finally {
      restore();
    }
  },
);
