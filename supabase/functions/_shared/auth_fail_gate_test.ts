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
  AUTH_FAIL_CACHE_MAX_ENTRIES,
  AUTH_FAIL_LIMIT,
  AUTH_FAIL_TOKEN_TTL_MS,
  AUTH_FAIL_WINDOW_SECONDS,
  authFailCacheSizesForTests,
  authFailGate,
  forgetAuthFailure,
  knownAuthFailure,
  resetAuthFailCacheForTests,
  setAuthFailClockForTests,
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
  // P7-02: every stub starts from a cold isolate (empty auth-fail caches).
  resetAuthFailCacheForTests();
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
    assert(zeilen.includes("uid-Bucket"), `der geteilte Bucket muss benannt sein: ${zeilen}`);
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

// P6-04c (Gegenprobe 2026-08-29): the warning above names the BUCKET, not the
// subject. Today every caller passes clientIpSubject(req, "anon"), so the
// subject is the constant "uid:anon" — but the same helper turns a verified
// user id into "uid:<uuid>", and the old line would have written that id into
// function_logs the moment one caller changed its fallback (CWE-532).
Deno.test("P6-04c: eine echte User-ID im Subject landet nicht im Log", async () => {
  const userId = "11111111-1111-4111-8111-111111111111";
  const fetchStub = installFetch(rpcAntwort({
    allowed: false,
    limit: 30,
    remaining: 0,
    resetAt: new Date(Date.now() + 1800_000).toISOString(),
    windowSeconds: 3600,
  }));
  const warn = installWarnLog();
  try {
    await authFailGate({ ...OPTIONS, subject: `uid:${userId}` });
    const zeilen = warn.zeilen.join("\n");
    assert(zeilen.includes("uid-Bucket"), `der Bucket muss benannt bleiben: ${zeilen}`);
    assert(!zeilen.includes(userId), `User-ID im Log: ${zeilen}`);
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

// --- E1 (Review 2026-08-31): die Frist gehoert in den geteilten Helfer ------
//
// Der fetch trug kein AbortSignal. Der Gate laeuft auf dem 401-Pfad ALLER drei
// Functions, also hielt ein stockendes PostgREST die Anfrage offen, bis die
// Plattform das Isolate killte — waehrend der Client laengst aufgegeben hatte.
// Die Frist kann nur der Aufrufer kennen (er weiss, was von seinem Budget noch
// uebrig ist), deshalb ist `signal` optional und wird durchgereicht.

/** Haengender RPC-Aufruf: loest nie von selbst auf und rejectet mit
 *  signal.reason beim Abbruch, wie ein echter fetch gegen einen toten Server.
 *  OHNE Signal schlaegt er laut fehl — genau das ist die Regressionswache. */
function haengtBisAbbruch(init?: RequestInit): Promise<Response> {
  const signal = init?.signal;
  return new Promise((_, reject) => {
    if (!signal) {
      reject(new Error("haengender RPC ohne AbortSignal — die Frist (E1) fehlt"));
      return;
    }
    if (signal.aborted) {
      reject(signal.reason);
      return;
    }
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
}

Deno.test("E1: ein feuerndes Signal bricht den Consume ab und meldet limited:false", async () => {
  resetAuthFailCacheForTests();
  const original = globalThis.fetch;
  const aufrufe: FetchAufruf[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    aufrufe.push({ url, init });
    return haengtBisAbbruch(init);
  }) as typeof globalThis.fetch;
  const log = installErrorLog();
  const signal = AbortSignal.timeout(20);
  try {
    const result = await authFailGate({ ...OPTIONS, signal });
    // Die Zusage des Helfers bleibt: er wirft nie und drosselt nie auf einen
    // Limiter-Fehler — ein Abbruch ist genau so einer.
    assertEquals(result.limited, false, "Abbruch darf nie drosseln");
    assertEquals(aufrufe.length, 1, "genau ein RPC-Aufruf");
    // Das eigentliche Pin: das Signal des Aufrufers landet am fetch. Ohne
    // diese Durchreichung liefe der Aufruf unbegrenzt weiter.
    assertEquals(aufrufe[0].init?.signal, signal, "das Signal des Aufrufers muss am fetch ankommen");
    const zeilen = log.zeilen.join("\n");
    assert(zeilen.includes("consume_edge_rate_limit"), `der Abbruch muss geloggt werden: ${zeilen}`);
    // Der Grund ist der Timeout, nicht die Wache oben: waere das Signal nicht
    // durchgereicht, stuende hier "die Frist (E1) fehlt".
    assert(
      zeilen.toLowerCase().includes("timed out") || zeilen.toLowerCase().includes("timeout"),
      `der Abbruchgrund muss diagnostizierbar sein: ${zeilen}`,
    );
    assert(!zeilen.includes("die Frist (E1) fehlt"), `das Signal erreicht den fetch nicht: ${zeilen}`);
  } finally {
    log.restore();
    globalThis.fetch = original;
  }
});

Deno.test("E1: ein bereits abgebrochenes Signal wirft nicht nach aussen", async () => {
  // Ein Aufrufer mit aufgebrauchtem Budget uebergibt ein Signal, das schon
  // gefeuert hat. Ein echter fetch rejectet dann sofort — auch das muss in der
  // Zusage "wirft nie" landen und nicht als 500 beim Nutzer.
  resetAuthFailCacheForTests();
  const original = globalThis.fetch;
  globalThis.fetch = ((_input: string | URL | Request, init?: RequestInit): Promise<Response> =>
    haengtBisAbbruch(init)) as typeof globalThis.fetch;
  const log = installErrorLog();
  const controller = new AbortController();
  controller.abort();
  try {
    const result = await authFailGate({ ...OPTIONS, signal: controller.signal });
    assertEquals(result.limited, false, "auch hier: nie drosseln, nie werfen");
    const zeilen = log.zeilen.join("\n");
    assert(zeilen.includes("consume_edge_rate_limit"), `der Abbruch muss geloggt werden: ${zeilen}`);
    // Die Wache der Attrappe: taucht ihre Zeile auf, kam das Signal nie am
    // fetch an und der Aufruf waere unbegrenzt weitergelaufen.
    assert(!zeilen.includes("die Frist (E1) fehlt"), `das Signal erreicht den fetch nicht: ${zeilen}`);
  } finally {
    log.restore();
    globalThis.fetch = original;
  }
});

Deno.test("E1: ohne Signal bleibt der Aufruf unveraendert (optional fuer Aufrufer)", async () => {
  // Die Schnittstelle ist bewusst optional: analyze-meal legt seine Frist
  // heute an der Aufrufstelle an (withDeadline), und keine Seite darf an der
  // anderen brechen.
  const fetchStub = installFetch(erlaubt());
  try {
    const result = await authFailGate(OPTIONS);
    assertEquals(result.limited, false, "Erfolgsfall bleibt Erfolgsfall");
    assertEquals(fetchStub.aufrufe[0].init?.signal, undefined, "ohne Option kein Signal am fetch");
  } finally {
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

Deno.test("shared auth-fail warning omits malformed resetAt content", async () => {
  const marker = "PRIVATE_RESET_AT_SENTINEL";
  const fetchStub = installFetch(rpcAntwort({ allowed: false, resetAt: marker }));
  const warn = installWarnLog();
  try {
    const result = await authFailGate({ ...OPTIONS, subject: "uid:anon" });
    assert(result.limited, "denial still applies");
    assert(warn.zeilen.some((line) => line.includes("uid-Bucket")), "shared bucket remains diagnosable");
    assert(!warn.zeilen.join(" ").includes(marker), "untrusted resetAt omitted from warning");
  } finally {
    warn.restore();
    fetchStub.restore();
  }
});

Deno.test("auth-fail limiter omits arbitrary exception messages and response field names", async () => {
  const marker = "PRIVATE_LIMITER_SENTINEL";
  for (const fail of [
    () => Promise.reject(new TypeError(marker)),
    rpcAntwort({ [marker]: true }),
  ]) {
    const fetchStub = installFetch(fail);
    const log = installErrorLog();
    try {
      assertEquals((await authFailGate(OPTIONS)).limited, false, "limiter fault never blocks the 401");
      assert(log.zeilen.some((line) => line.includes("consume_edge_rate_limit")), "operation remains diagnosable");
      assert(!log.zeilen.join(" ").includes(marker), "upstream data omitted from logs");
    } finally {
      log.restore();
      fetchStub.restore();
    }
  }
});

// --- P7-02 (review 2026-10-01): the in-isolate caches ----------------------
//
// The bucket answered 429 but every replay still cost a GoTrue lookup and an
// upsert. Known-bad tokens (two 401/403 within the TTL) and known-exhausted
// buckets are now remembered per isolate. Time is injected, never slept.

const TOKEN = "eyJ.widerrufen.sig";

function gesperrt(resetInMs = 1_800_000): () => Promise<Response> {
  return rpcAntwort({
    allowed: false,
    limit: 30,
    remaining: 0,
    resetAt: new Date(Date.now() + resetInMs).toISOString(),
    windowSeconds: 3600,
  });
}

async function strike(token = TOKEN, status = 401): Promise<void> {
  await authFailGate({ ...OPTIONS, rejection: { token, status } });
}

Deno.test("P7-02: unbekannter Token -> null, ohne Hash und ohne Netz", async () => {
  const fetchStub = installFetch(erlaubt());
  try {
    assertEquals(await knownAuthFailure({ ...OPTIONS, token: TOKEN }), null, "nachschlagen");
    assertEquals(fetchStub.aufrufe.length, 0, "kein Netz");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("P7-02: erst der ZWEITE 401/403 macht den Token bekannt schlecht", async () => {
  const fetchStub = installFetch(erlaubt());
  try {
    await strike();
    assertEquals(await knownAuthFailure({ ...OPTIONS, token: TOKEN }), null, "ein Strike ist ein moeglicher Flake");
    await strike(TOKEN, 403);
    const known = await knownAuthFailure({ ...OPTIONS, token: TOKEN });
    assertEquals(known?.limited, false, "bekannt schlecht, Bucket offen -> 401");
    assertEquals(
      await knownAuthFailure({ ...OPTIONS, token: `${TOKEN}x` }),
      null,
      "ein anderer (refreshter) Token bleibt unberuehrt",
    );
    assertEquals(
      await knownAuthFailure({ ...OPTIONS, scope: "andere-fn:auth-fail", token: TOKEN }),
      null,
      "pro Function getrennt",
    );
  } finally {
    fetchStub.restore();
  }
});

for (const status of [400, 404, 422, 429, 500, 503]) {
  Deno.test(`P7-02: GoTrue ${status} ist kein Strike`, async () => {
    const fetchStub = installFetch(erlaubt());
    try {
      for (let i = 0; i < 3; i++) await strike(TOKEN, status);
      assertEquals(await knownAuthFailure({ ...OPTIONS, token: TOKEN }), null, "nur 401/403 werden gemerkt");
      assertEquals(authFailCacheSizesForTests().tokens, 0, "nichts gespeichert");
    } finally {
      fetchStub.restore();
    }
  });
}

Deno.test("P7-02: ein Erfolg (forgetAuthFailure) loescht den Strike", async () => {
  const fetchStub = installFetch(erlaubt());
  try {
    await strike();
    await forgetAuthFailure(OPTIONS.scope, TOKEN);
    await strike();
    assertEquals(await knownAuthFailure({ ...OPTIONS, token: TOKEN }), null, "Flake, Erfolg, Flake sperrt nicht");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("P7-02: Strikes verfallen nach der TTL (injizierte Uhr)", async () => {
  const fetchStub = installFetch(erlaubt());
  let now = Date.parse("2026-10-01T12:00:00Z");
  setAuthFailClockForTests(() => now);
  try {
    await strike();
    await strike();
    assert((await knownAuthFailure({ ...OPTIONS, token: TOKEN })) !== null, "bekannt schlecht");
    now += AUTH_FAIL_TOKEN_TTL_MS - 1;
    assert((await knownAuthFailure({ ...OPTIONS, token: TOKEN })) !== null, "kurz vor Ablauf noch bekannt");
    now += 1;
    assertEquals(await knownAuthFailure({ ...OPTIONS, token: TOKEN }), null, "nach der TTL wieder nachschlagen");
    // An expired strike does not count towards the next one.
    await strike();
    assertEquals(await knownAuthFailure({ ...OPTIONS, token: TOKEN }), null, "abgelaufener Strike zaehlt nicht mit");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("P7-02: erschoepfter Bucket -> weitere Fehlschlaege ohne Upsert, bis resetAt", async () => {
  const fetchStub = installFetch(gesperrt(90_000));
  let now = Date.now();
  setAuthFailClockForTests(() => now);
  try {
    const first = await authFailGate(OPTIONS);
    assert(first.limited, "erste Erschoepfung kommt vom Limiter");
    const second = await authFailGate(OPTIONS);
    assert(second.limited, "zweiter Fehlschlag: weiter 429");
    if (!second.limited) return;
    assert(second.retryAfterSeconds >= 85 && second.retryAfterSeconds <= 90, `Retry-After, war ${second.retryAfterSeconds}`);
    assertEquals(fetchStub.aufrufe.length, 1, "kein zweiter Upsert");
    assertEquals(
      await knownAuthFailure({ ...OPTIONS, token: TOKEN }),
      null,
      "ein gesperrter Bucket allein kuerzt NIE vor dem Lookup ab (gueltige Tokens derselben IP)",
    );

    now += 90_000;
    await authFailGate(OPTIONS);
    assertEquals(fetchStub.aufrufe.length, 2, "nach resetAt fragt der Gate wieder");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("P7-02: der Bucket-Cache haelt hoechstens ein Fenster, auch bei fernem resetAt", async () => {
  const fetchStub = installFetch(rpcAntwort({
    allowed: false,
    limit: 30,
    remaining: 0,
    resetAt: new Date(Date.now() + 10 * 3600_000).toISOString(),
    windowSeconds: 60,
  }));
  let now = Date.now();
  setAuthFailClockForTests(() => now);
  try {
    await authFailGate(OPTIONS);
    now += 60_000;
    await authFailGate(OPTIONS);
    assertEquals(fetchStub.aufrufe.length, 2, "nach einem Fenster wird wieder gefragt");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("P7-02: unlesbares resetAt wird nicht gecacht", async () => {
  const fetchStub = installFetch(rpcAntwort({
    allowed: false,
    limit: 30,
    remaining: 0,
    resetAt: "kaputt",
    windowSeconds: 3600,
  }));
  try {
    await authFailGate(OPTIONS);
    await authFailGate(OPTIONS);
    assertEquals(fetchStub.aufrufe.length, 2, "jeder Fehlschlag fragt den Limiter");
    assertEquals(authFailCacheSizesForTests().buckets, 0, "kein Bucket gemerkt");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("P7-02: bekannter Token im bekannten Bucket -> 429 ohne Netz, Retry-After aus resetAt", async () => {
  const fetchStub = installFetch(gesperrt(120_000));
  try {
    await strike();
    await strike();
    const known = await knownAuthFailure({ ...OPTIONS, token: TOKEN });
    assert(known !== null && known.limited, "429 statt 401");
    if (known === null || !known.limited) return;
    assert(known.retryAfterSeconds >= 115 && known.retryAfterSeconds <= 120, `Retry-After, war ${known.retryAfterSeconds}`);
    assertEquals(known.remaining, 0, "remaining");
    assertEquals(fetchStub.aufrufe.length, 1, "nur der erste Fehlschlag fragte den Limiter");
    assertEquals(
      (await knownAuthFailure({ ...OPTIONS, subject: "ip:198.51.100.1", token: TOKEN }))?.limited,
      false,
      "derselbe Token aus einem anderen, offenen Bucket -> 401",
    );
  } finally {
    fetchStub.restore();
  }
});

Deno.test("P7-02: beide Caches sind gedeckelt", async () => {
  const fetchStub = installFetch(gesperrt());
  try {
    for (let i = 0; i < AUTH_FAIL_CACHE_MAX_ENTRIES + 25; i++) {
      await authFailGate({ ...OPTIONS, subject: `ip:10.0.${i >> 8}.${i & 255}`, rejection: { token: `t${i}`, status: 401 } });
    }
    const sizes = authFailCacheSizesForTests();
    assertEquals(sizes.tokens, AUTH_FAIL_CACHE_MAX_ENTRIES, "Token-Cache am Deckel");
    assertEquals(sizes.buckets, AUTH_FAIL_CACHE_MAX_ENTRIES, "Bucket-Cache am Deckel");
    // Oldest out first: token 0 is gone, the newest one is still there.
    await strike("t0");
    assertEquals(await knownAuthFailure({ ...OPTIONS, token: "t0" }), null, "aeltester Eintrag verdraengt");
    const last = `t${AUTH_FAIL_CACHE_MAX_ENTRIES + 24}`;
    await strike(last);
    assert((await knownAuthFailure({ ...OPTIONS, token: last })) !== null, "neuester Eintrag erhalten");
  } finally {
    fetchStub.restore();
  }
});

Deno.test("P7-02: der Token landet in keinem Log", async () => {
  const fetchStub = installFetch(gesperrt());
  const log = installErrorLog();
  const warn = installWarnLog();
  try {
    await authFailGate({ ...OPTIONS, subject: "uid:anon", rejection: { token: TOKEN, status: 401 } });
    await authFailGate({ ...OPTIONS, subject: "uid:anon", rejection: { token: TOKEN, status: 401 } });
    await knownAuthFailure({ ...OPTIONS, subject: "uid:anon", token: TOKEN });
    const all = [...log.zeilen, ...warn.zeilen].join("\n");
    assert(!all.includes(TOKEN), `Token im Log: ${all}`);
    assertEquals(warn.zeilen.length, 1, "die Erschoepfungs-Warnung kommt einmal, nicht pro Replay");
  } finally {
    warn.restore();
    log.restore();
    fetchStub.restore();
  }
});
