// E1 (Review 2026-08-31): search-key haengt nicht mehr unbegrenzt an einem
// stockenden Supabase.
//
// Der Befund: der GoTrue-Lookup, beide consume_edge_rate_limit-Aufrufe und der
// geteilte Fail-Bucket liefen ohne AbortSignal. Stockte einer davon, blockierte
// die Function bis zum Plattform-Kill — waehrend der Client nach 10 s aufgibt
// (HttpTimeoutPolicy.mirror in lib/src/services/eatova_http.dart). Deshalb hat
// die Function jetzt eine eigene Wanduhr (REQUEST_BUDGET_MS, eine Sekunde unter
// dem Client) und pro Aufruf die 5 s, die analyze-meal fuer dieselben zwei
// Server verwendet.
//
// index.ts liest seine Env beim Modul-Laden und ruft Deno.serve; beides wie in
// rate_limit_window_test.ts (Cache-brechender Import mit STRING-LITERAL,
// abgefangenes Deno.serve). Die Attrappe haengt nur gegen ein Signal und
// schlaegt ohne Signal laut fehl; zusaetzlich laeuft jede Anfrage gegen eine
// Haenger-Wache, damit ein zurueckgedrehter Fix rot wird statt die Suite
// einzufrieren. `deno test --allow-env`, kein Netz.

const BASE_URL = "https://supabase.test.invalid";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const CLIENT_IP = "203.0.113.7";
// Zur Laufzeit zusammengesetzt: ein Literal neben `KEY` faellt in die
// gitleaks-Regel, und die prueft die HISTORIE (siehe tenant_token_test.ts).
const MIRROR_KEY = ["test", "search", "only"].join("-") + "-deadline-" + String(123456789);

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("EATOVA_MIRROR_SEARCH_KEY", MIRROR_KEY);
Deno.env.set("EATOVA_MIRROR_BASE_URL", "https://eatova.test.invalid/meili");

/** Wache: so lange darf eine Anfrage insgesamt brauchen. */
const HANG_GUARD_MS = 1_500;

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

/** Haengender Aufruf: loest nie von selbst auf, rejectet mit signal.reason
 *  beim Abbruch. OHNE Signal schlaegt er laut fehl — die Regressionswache. */
function haengtBisAbbruch(signal: AbortSignal | null | undefined): Promise<Response> {
  return new Promise((_, reject) => {
    if (!signal) {
      reject(new Error("haengender Supabase-Call ohne AbortSignal — die Frist (E1) fehlt"));
      return;
    }
    if (signal.aborted) {
      reject(signal.reason);
      return;
    }
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
}

async function ohneHaenger(work: Promise<Response> | Response): Promise<Response> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const wache = new Promise<"HAENGT">((resolve) => {
    timer = setTimeout(() => resolve("HAENGT"), HANG_GUARD_MS);
  });
  try {
    const result = await Promise.race([Promise.resolve(work), wache]);
    assert(result !== "HAENGT", `Anfrage haengt laenger als ${HANG_GUARD_MS} ms — die Frist (E1) greift nicht`);
    return result as Response;
  } finally {
    clearTimeout(timer);
  }
}

interface StubOptions {
  /** URL-Fragment, dessen Aufruf haengt. */
  stall?: string;
  /** Scope, dessen consume_edge_rate_limit haengt. */
  stallGateScope?: string;
  /** HTTP-Status des /auth/v1/user-Lookups. */
  authStatus?: number;
}

interface RecordedCall {
  url: string;
  body: string;
  hasSignal: boolean;
}

interface FetchStub {
  calls: RecordedCall[];
  gateScopes(): string[];
  restore(): void;
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const scopes: string[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    calls.push({
      url,
      body: typeof init?.body === "string" ? init.body : "",
      hasSignal: Boolean(init?.signal),
    });
    if (options.stall !== undefined && url.includes(options.stall)) {
      return haengtBisAbbruch(init?.signal);
    }
    if (url.includes("/auth/v1/user")) {
      if (options.authStatus !== undefined) {
        return Promise.resolve(jsonRes({ message: "invalid token" }, options.authStatus));
      }
      return Promise.resolve(jsonRes({ id: USER_ID }));
    }
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
      const params = JSON.parse(typeof init?.body === "string" ? init.body : "{}") as JsonRecord;
      scopes.push(String(params.p_scope));
      if (options.stallGateScope !== undefined && params.p_scope === options.stallGateScope) {
        return haengtBisAbbruch(init?.signal);
      }
      const windowSeconds = Number(params.p_window_seconds);
      return Promise.resolve(jsonRes({
        allowed: true,
        limit: Number(params.p_limit),
        remaining: Number(params.p_limit) - 1,
        resetAt: new Date(Date.now() + windowSeconds * 1000).toISOString(),
        windowSeconds,
      }));
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    return Promise.reject(new Error(`Unerwarteter fetch auf ${url}`));
  }) as typeof globalThis.fetch;

  return {
    calls,
    gateScopes: () => scopes,
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

// Eine Modul-Instanz pro Konfiguration; die Specifier muessen String-Literale
// sein (ein berechneter braeuchte --allow-read, das die CI nicht gewaehrt).
const LOADERS: Record<string, () => Promise<unknown>> = {
  // Kurze Frist pro Aufruf, reichlich Budget: prueft die Frist am Einzelcall.
  "call-cap": () => import("./index.ts?e1=call-cap"),
  // Umgekehrt: reichlich pro Aufruf, kurzes Gesamtbudget — prueft die Wanduhr.
  "budget": () => import("./index.ts?e1=budget"),
};

const ENV: Record<string, Record<string, string>> = {
  "call-cap": { SEARCH_KEY_SUPABASE_TIMEOUT_MS: "40", SEARCH_KEY_REQUEST_BUDGET_MS: "3000" },
  "budget": { SEARCH_KEY_SUPABASE_TIMEOUT_MS: "120000", SEARCH_KEY_REQUEST_BUDGET_MS: "200" },
};

/** Ein Handler je Konfiguration: das Modul wird pro Specifier genau einmal
 *  ausgewertet, ein zweiter Import ruft Deno.serve nicht noch einmal. */
const cache = new Map<string, Handler>();

async function loadHandler(tag: keyof typeof LOADERS): Promise<Handler> {
  const cached = cache.get(tag);
  if (cached) return cached;
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
  const env = ENV[tag];
  for (const [name, value] of Object.entries(env)) Deno.env.set(name, value);
  try {
    await LOADERS[tag]();
  } finally {
    // Sofort wieder weg: die Datei teilt sich den Prozess mit den anderen
    // search-key-Tests, deren Modul-Instanzen die kurzen Fristen nicht wollen.
    for (const name of Object.keys(env)) Deno.env.delete(name);
    Object.defineProperty(Deno, "serve", original!);
  }
  assert(handler !== null, "index.ts hat Deno.serve nie aufgerufen");
  cache.set(tag, handler!);
  return handler!;
}

function request(token = "eyJhbGciOiJIUzI1NiJ9.test.token"): Request {
  return new Request(`${BASE_URL}/functions/v1/search-key`, {
    method: "GET",
    headers: { authorization: `Bearer ${token}`, "cf-connecting-ip": CLIENT_IP },
  });
}

Deno.test("E1: ein haengendes Rate-Limit faellt geschlossen statt den Key auszuliefern", async () => {
  const serve = await loadHandler("call-cap");
  const stub = installFetch({ stallGateScope: "search-key:ip" });
  try {
    const res = await ohneHaenger(serve(request()));
    assertEquals(res.status, 500, "Status");
    const body = await res.json() as JsonRecord;
    // Ein stockender Limiter ist ein Ausfall, kein gemessenes Limit — und der
    // Endpunkt darf ohne seine Tore kein Suchmaterial herausgeben.
    assertEquals(body.error, "rate_limit_unavailable", "Fehlercode");
    assert(!JSON.stringify(body).includes(MIRROR_KEY), "der Key darf nicht in der Fehlerantwort stehen");
  } finally {
    stub.restore();
  }
});

Deno.test("E1: ein haengender Auth-Lookup meldet 503 statt 401", async () => {
  const serve = await loadHandler("call-cap");
  const stub = installFetch({ stall: "/auth/v1/user" });
  try {
    const res = await ohneHaenger(serve(request()));
    // 401 waere die falsche Antwort: der stockende Auth-Server ist ein
    // Ausfall, kein abgelehntes Token.
    assertEquals(res.status, 503, "Status");
    assertEquals((await res.json() as JsonRecord).error, "auth_unavailable", "Fehlercode");
    // Und ein langsamer Auth-Server darf das Fail-Bucket nicht fuellen, sonst
    // beantwortet er fremde 401 mit 429.
    assertEquals(stub.gateScopes().join(","), "", "kein Consume auf dem Ausfall-Pfad");
  } finally {
    stub.restore();
  }
});

Deno.test("E1: ein haengendes Fail-Bucket blockiert die ehrliche 401 nicht", async () => {
  const serve = await loadHandler("call-cap");
  const stub = installFetch({ authStatus: 401, stallGateScope: "search-key:auth-fail" });
  try {
    const res = await ohneHaenger(serve(request()));
    assertEquals(res.status, 401, "Status");
    assertEquals((await res.json() as JsonRecord).error, "invalid_user_token", "Fehlercode");
    assertEquals(stub.gateScopes().join(","), "search-key:auth-fail", "der Consume wurde versucht");
    // Explizit, weil der Helfer JEDEN Fehler schluckt: ohne diese Zusicherung
    // saehe eine entfernte Frist genauso aus wie eine wirksame.
    const gateCall = stub.calls.find((call) => call.body.includes("search-key:auth-fail"));
    assertEquals(gateCall?.hasSignal, true, "der geteilte Gate bekommt die Frist des Aufrufers");
  } finally {
    stub.restore();
  }
});

Deno.test("E1: das Anfrage-Budget deckelt auch einen grosszuegigen Einzelcall", async () => {
  // Die zweite Haelfte der Frist: selbst mit 120 s pro Aufruf gibt die
  // Function nach ihrem eigenen Budget auf. In Produktion sind das 9 s, eine
  // Sekunde unter dem 10-s-Deckel des Clients — wer zuerst aufgibt, bestimmt,
  // ob der Nutzer eine ehrliche Fehlermeldung oder einen Timeout sieht.
  const serve = await loadHandler("budget");
  const stub = installFetch({ stallGateScope: "search-key:ip" });
  const start = Date.now();
  try {
    const res = await ohneHaenger(serve(request()));
    assertEquals(res.status, 500, "Status");
    assertEquals((await res.json() as JsonRecord).error, "rate_limit_unavailable", "Fehlercode");
    const dauer = Date.now() - start;
    assert(dauer < 1_000, `das Budget hat nicht gegriffen: ${dauer} ms`);
  } finally {
    stub.restore();
  }
});

Deno.test("E1: JEDER ausgehende Aufruf einer erfolgreichen Anfrage traegt eine Frist", async () => {
  // Wache gegen den naechsten fetch ohne Frist: Auth, IP-Tor, Nutzer-Tor und
  // das Aufraeumen in einem Durchlauf.
  const serve = await loadHandler("call-cap");
  const stub = installFetch();
  try {
    const res = await ohneHaenger(serve(request()));
    assertEquals(res.status, 200, "Status");
    const ohneFrist = stub.calls.filter((call) => !call.hasSignal).map((call) => call.url);
    assertEquals(ohneFrist.join("\n"), "", "Aufrufe ohne AbortSignal");
    assert(stub.calls.length >= 4, `zu wenige Aufrufe im Durchlauf: ${stub.calls.length}`);
  } finally {
    stub.restore();
  }
});
