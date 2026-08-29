// Tests for the shared pre-auth fail limiter (auth_fail_gate.ts).
//
// The regression (F-28-1, review 2026-08-28): search-key and analyze-meal
// introspected every non-anon bearer at /auth/v1/user with no cap on
// FAILURES, so a flood of signature-valid but revoked tokens was unbounded
// GoTrue amplification. coach-chat had the gate inline; this is that gate,
// shared, with the same numbers (30 failures / h / IP).
//
// The helper is a DAMPER, not an auth boundary: a limiter outage must never
// block the 401 and must never throw. No external test dependencies and no
// network: globalThis.fetch is replaced.

import {
  AUTH_FAIL_LIMIT,
  AUTH_FAIL_WINDOW_SECONDS,
  authFailGate,
} from "./auth_fail_gate.ts";

const SUPABASE_URL = "https://supabase.test.invalid";
const SERVICE_KEY = "test-service-role-key-0123456789";
const RPC_URL = `${SUPABASE_URL}/rest/v1/rpc/consume_edge_rate_limit`;
const OPTIONS = {
  supabaseUrl: SUPABASE_URL,
  serviceKey: SERVICE_KEY,
  scope: "test-fn:auth-fail",
  subject: "ip:203.0.113.7",
};

type JsonRecord = Record<string, unknown>;

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

type FetchAufruf = { url: string; init?: RequestInit };

/** Replaces globalThis.fetch with `antwort` and records the calls. */
function installFetch(antwort: () => Promise<Response>): {
  aufrufe: FetchAufruf[];
  restore: () => void;
} {
  const original = globalThis.fetch;
  const aufrufe: FetchAufruf[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    aufrufe.push({ url, init });
    return antwort();
  }) as typeof globalThis.fetch;
  return {
    aufrufe,
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

/** Captures console.error so the diagnostic line is checkable without
 *  cluttering the test output. */
function installErrorLog(): { zeilen: string[]; restore: () => void } {
  const original = console.error;
  const zeilen: string[] = [];
  console.error = (...args: unknown[]) => {
    zeilen.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
  };
  return {
    zeilen,
    restore: () => {
      console.error = original;
    },
  };
}

/** Same for console.warn — the shared-bucket signal (P6-05) lives there. */
function installWarnLog(): { zeilen: string[]; restore: () => void } {
  const original = console.warn;
  const zeilen: string[] = [];
  console.warn = (...args: unknown[]) => {
    zeilen.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
  };
  return {
    zeilen,
    restore: () => {
      console.warn = original;
    },
  };
}

function rpcAntwort(body: JsonRecord, status = 200): () => Promise<Response> {
  return () =>
    Promise.resolve(
      new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } }),
    );
}

function erlaubt(): () => Promise<Response> {
  return rpcAntwort({
    allowed: true,
    limit: AUTH_FAIL_LIMIT,
    remaining: AUTH_FAIL_LIMIT - 1,
    resetAt: new Date(Date.now() + AUTH_FAIL_WINDOW_SECONDS * 1000).toISOString(),
    windowSeconds: AUTH_FAIL_WINDOW_SECONDS,
  });
}

Deno.test("Erfolgsfall: ein Consume mit Scope, Subject, 30/h-Default und Service-Key", async () => {
  const fetchStub = installFetch(erlaubt());
  const log = installErrorLog();
  try {
    const result = await authFailGate(OPTIONS);
    assertEquals(result.limited, false, "unter dem Budget ist nichts gedrosselt");
    assertEquals(fetchStub.aufrufe.length, 1, "genau ein RPC-Aufruf");
    const [aufruf] = fetchStub.aufrufe;
    assertEquals(aufruf.url, RPC_URL, "RPC-URL");
    assertEquals(aufruf.init?.method, "POST", "Methode");
    const params = JSON.parse(String(aufruf.init?.body)) as JsonRecord;
    assertEquals(params.p_scope, OPTIONS.scope, "Scope");
    assertEquals(params.p_subject, OPTIONS.subject, "Subject");
    // The numbers coach-chat pinned; all three functions must share them.
    assertEquals(params.p_limit, 30, "konservatives Limit (30/h)");
    assertEquals(params.p_window_seconds, 3600, "Stunden-Fenster");
    assertEquals(AUTH_FAIL_LIMIT, 30, "exportierte Konstante");
    assertEquals(AUTH_FAIL_WINDOW_SECONDS, 3600, "exportierte Konstante");
    const headers = new Headers(aufruf.init?.headers);
    // The RPC is granted to service_role only; PostgREST needs apikey AND
    // Authorization.
    assertEquals(headers.get("apikey"), SERVICE_KEY, "apikey-Header");
    assertEquals(headers.get("authorization"), `Bearer ${SERVICE_KEY}`, "authorization-Header");
    assertEquals(headers.get("content-type"), "application/json", "content-type-Header");
    assertEquals(log.zeilen.length, 0, `kein Log im Erfolgsfall: ${JSON.stringify(log.zeilen)}`);
  } finally {
    log.restore();
    fetchStub.restore();
  }
});

Deno.test("Limit und Fenster sind pro Aufruf uebersteuerbar", async () => {
  const fetchStub = installFetch(erlaubt());
  try {
    await authFailGate({ ...OPTIONS, limit: 5, windowSeconds: 60 });
    const params = JSON.parse(String(fetchStub.aufrufe[0].init?.body)) as JsonRecord;
    assertEquals(params.p_limit, 5, "Limit");
    assertEquals(params.p_window_seconds, 60, "Fenster");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("Budget erschoepft -> limited mit Retry-After aus resetAt", async () => {
  const resetAt = new Date(Date.now() + 90_000).toISOString();
  const fetchStub = installFetch(rpcAntwort({
    allowed: false,
    limit: 30,
    remaining: 0,
    resetAt,
    windowSeconds: 3600,
  }));
  try {
    const result = await authFailGate(OPTIONS);
    assert(result.limited, "ueber dem Budget muss gedrosselt werden");
    if (!result.limited) return;
    assertEquals(result.limit, 30, "limit");
    assertEquals(result.remaining, 0, "remaining");
    assertEquals(result.resetAt, resetAt, "resetAt wird durchgereicht");
    assertEquals(result.windowSeconds, 3600, "windowSeconds");
    // ceil of the remaining seconds; a few ms elapse between stub and check.
    assert(
      result.retryAfterSeconds >= 85 && result.retryAfterSeconds <= 90,
      `Retry-After aus resetAt, war ${result.retryAfterSeconds}`,
    );
  } finally {
    fetchStub.restore();
  }
});

Deno.test("unlesbares resetAt -> Retry-After faellt auf die Fensterlaenge zurueck", async () => {
  const fetchStub = installFetch(rpcAntwort({
    allowed: false,
    limit: 30,
    remaining: 0,
    resetAt: "kaputt",
    windowSeconds: 3600,
  }));
  try {
    const result = await authFailGate(OPTIONS);
    assert(result.limited, "gedrosselt");
    if (!result.limited) return;
    assertEquals(result.retryAfterSeconds, 3600, "Fallback = Fenster");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("Limiter-HTTP-Fehler blockiert die 401 nicht: limited=false, mit Status geloggt", async () => {
  // A damper, not an auth boundary: without the limiter the caller still
  // answers 401, it just loses the flood protection.
  const fetchStub = installFetch(() => Promise.resolve(new Response("boom", { status: 500 })));
  const log = installErrorLog();
  try {
    const result = await authFailGate(OPTIONS);
    assertEquals(result.limited, false, "ein Limiter-Ausfall darf nie drosseln");
    assert(
      log.zeilen.some((zeile) => zeile.includes("consume_edge_rate_limit") && zeile.includes("500")),
      `Status 500 muss diagnostizierbar sein, Zeilen: ${JSON.stringify(log.zeilen)}`,
    );
  } finally {
    log.restore();
    fetchStub.restore();
  }
});

Deno.test("REGRESSION: ein rejectender fetch schlaegt nicht nach aussen durch", async () => {
  // The gate runs on the 401 path of every function; a thrown TypeError
  // there would turn "wrong token" into a 500.
  const fetchStub = installFetch(() => Promise.reject(new TypeError("error sending request for url")));
  const log = installErrorLog();
  try {
    const result = await authFailGate(OPTIONS);
    assertEquals(result.limited, false, "Netzwerkfehler = kein Limit");
    assert(
      log.zeilen.some((zeile) => zeile.includes("consume_edge_rate_limit")),
      `der geschluckte Fehler muss geloggt werden, Zeilen: ${JSON.stringify(log.zeilen)}`,
    );
  } finally {
    log.restore();
    fetchStub.restore();
  }
});

Deno.test("E6: 200 ohne lesbares allowed ist ein Limiter-Ausfall, kein Limit", async () => {
  const fetchStub = installFetch(rpcAntwort({ ok: true }));
  const log = installErrorLog();
  try {
    const result = await authFailGate(OPTIONS);
    assertEquals(result.limited, false, "kaputte Antwortform darf nie drosseln");
    assert(
      log.zeilen.some((zeile) => zeile.includes("ohne lesbares allowed")),
      `Antwortform muss diagnostizierbar sein, Zeilen: ${JSON.stringify(log.zeilen)}`,
    );
  } finally {
    log.restore();
    fetchStub.restore();
  }
});

// --- P6-05: der geteilte Bucket ohne Client-IP -----------------------------
//
// Without an IP header every function's failures share ONE bucket
// ("uid:anon"), so its exhaustion answers 429 to callers who never failed
// themselves. The numbers stay as they are (see the file header for why); what
// was missing is the operator's signal for the moment it starts happening.

Deno.test("P6-05: erschoepfter anon-Sammelbucket meldet sich beim Betreiber", async () => {
  const fetchStub = installFetch(rpcAntwort({
    allowed: false,
    limit: 30,
    remaining: 0,
    resetAt: new Date(Date.now() + 1800_000).toISOString(),
    windowSeconds: 3600,
  }));
  const warn = installWarnLog();
  try {
    const result = await authFailGate({ ...OPTIONS, subject: "uid:anon" });
    assert(result.limited, "der Bucket drosselt weiterhin");
    const zeilen = warn.zeilen.join("\n");
    assert(zeilen.includes("uid:anon"), `der geteilte Bucket muss benannt sein: ${zeilen}`);
    assert(zeilen.includes("401"), `die Verwechslungsgefahr muss dranstehen: ${zeilen}`);
    assert(zeilen.includes(OPTIONS.scope), `die Function muss erkennbar sein: ${zeilen}`);
    // Deliberately unchanged: same limit and window as the per-IP bucket, one
    // set of numbers for all three functions.
    const params = JSON.parse(String(fetchStub.aufrufe[0].init?.body)) as JsonRecord;
    assertEquals(params.p_limit, 30, "Limit bleibt");
    assertEquals(params.p_window_seconds, 3600, "Fenster bleibt");
  } finally {
    warn.restore();
    fetchStub.restore();
  }
});

Deno.test("P6-05: der IP-Bucket bleibt still — sein 429 trifft den Verursacher", async () => {
  const fetchStub = installFetch(rpcAntwort({
    allowed: false,
    limit: 30,
    remaining: 0,
    resetAt: new Date(Date.now() + 1800_000).toISOString(),
    windowSeconds: 3600,
  }));
  const warn = installWarnLog();
  try {
    const result = await authFailGate(OPTIONS);
    assert(result.limited, "gedrosselt");
    assertEquals(warn.zeilen.length, 0, `keine Warnung fuer den IP-Bucket: ${warn.zeilen.join("\n")}`);
  } finally {
    warn.restore();
    fetchStub.restore();
  }
});

Deno.test("P6-05: der ungedrosselte anon-Bucket warnt nicht bei jedem Fehlschlag", async () => {
  const fetchStub = installFetch(erlaubt());
  const warn = installWarnLog();
  try {
    await authFailGate({ ...OPTIONS, subject: "uid:anon" });
    assertEquals(warn.zeilen.length, 0, `nur die Erschoepfung ist ein Ereignis: ${warn.zeilen.join("\n")}`);
  } finally {
    warn.restore();
    fetchStub.restore();
  }
});

Deno.test("der Service-Key steht nie in der Fehlerzeile", async () => {
  const faelle: (() => Promise<Response>)[] = [
    () => Promise.reject(new TypeError(`error sending request for ${RPC_URL}`)),
    () => Promise.resolve(new Response(SERVICE_KEY, { status: 401 })),
    // Broken shape: the diagnostic must name the shape, not dump the body.
    rpcAntwort({ echo: SERVICE_KEY }),
  ];
  for (const fall of faelle) {
    const fetchStub = installFetch(fall);
    const log = installErrorLog();
    try {
      await authFailGate(OPTIONS);
      const zeilen = log.zeilen.join("\n");
      assert(!zeilen.includes(SERVICE_KEY), `der Service-Key ist im Log gelandet: ${zeilen}`);
    } finally {
      log.restore();
      fetchStub.restore();
    }
  }
});
