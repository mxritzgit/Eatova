// E1 (Review 2026-08-31): coach-chat haengt nicht mehr unbegrenzt an einem
// stockenden PostgREST — und der beanspruchte Kontingent-Slot geht dabei nicht
// still verloren.
//
// Der Befund: JEDER Supabase-fetch in handler.ts lief ohne AbortSignal. Nur
// die beiden Provider-Aufrufe hatten eine Frist. Stockte PostgREST NACH
// `claim_chat_quota` (storeMessage, maybeAutoTitle), blockierte die Function,
// der Client brach bei 75 s ab und zeigte eine Zeitueberschreitung, die
// Function lief weiter bis die Plattform das Isolate killte — kein catch lief
// je, also wurde der Slot nie erstattet. Die Erstattung feuert sonst nur bei
// einem Anbieter-Fehler.
//
// Die hier festgenagelte Linie nach dem Anspruch: jeder Aufruf schliesst ab,
// erreicht eine Erstattung, oder ist kosmetisch.
//
// Die Attrappe haengt NUR gegen ein Signal (haengtBisAbbruch) und schlaegt
// ohne Signal laut fehl; zusaetzlich laeuft jede Anfrage gegen eine
// Haenger-Wache, damit ein zurueckgedrehter Fix rot wird statt die Suite
// einzufrieren. `deno test --allow-env`, kein Netz.

import { handleRequest, SUPABASE_TIMEOUTS_MS } from "./handler.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const BASE_URL = "https://supabase.test.invalid";
const CLIENT_IP = "203.0.113.7";

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("OPENROUTER_API_KEY", "test-openrouter-key");

/** Frist im Test: kurz genug fuer eine schnelle Suite, lang genug, dass die
 *  sofort aufloesenden Attrappen nicht selbst in den Abbruch laufen. */
const TEST_TIMEOUT_MS = 40;
/** Wache: so lange darf eine Anfrage insgesamt brauchen. Deutlich ueber der
 *  Frist, weit unter allem, was wie ein Haenger aussieht. */
const HANG_GUARD_MS = 1_500;

type JsonRecord = Record<string, unknown>;

interface RecordedCall {
  url: string;
  method: string;
  body: string;
  /** Hat der Aufruf eine Frist mitbekommen? */
  hasSignal: boolean;
}

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
 *  beim Abbruch — wie ein echter fetch gegen einen toten Server. OHNE Signal
 *  schlaegt er laut fehl, was die Regressionswache gegen ein entferntes
 *  AbortSignal ist. */
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

/** Laesst die Anfrage gegen eine Wanduhr laufen. Ohne die Frist wuerde
 *  `handleRequest` nie aufloesen; die Wache macht daraus eine gescheiterte
 *  Zusicherung statt einer eingefrorenen Suite. */
async function ohneHaenger(work: Promise<Response>): Promise<Response> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const wache = new Promise<"HAENGT">((resolve) => {
    timer = setTimeout(() => resolve("HAENGT"), HANG_GUARD_MS);
  });
  try {
    const result = await Promise.race([work, wache]);
    assert(result !== "HAENGT", `Anfrage haengt laenger als ${HANG_GUARD_MS} ms — die Frist (E1) greift nicht`);
    return result as Response;
  } finally {
    clearTimeout(timer);
  }
}

interface StubOptions {
  /** URL-Fragment, dessen Aufruf haengt. */
  stall?: string;
  /** Nur POSTs auf `stall` haengen lassen (chat_messages: POST = storeMessage,
   *  GET = loadHistory). */
  stallMethod?: string;
  /** Scope, dessen consume_edge_rate_limit haengt. */
  stallGateScope?: string;
  /** HTTP-Status des /auth/v1/user-Lookups. */
  authStatus?: number;
}

interface FetchStub {
  calls: RecordedCall[];
  callsTo(fragment: string): RecordedCall[];
  gateScopes(): string[];
  restore(): void;
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const original = globalThis.fetch;

  function route(
    url: string,
    method: string,
    body: string,
    signal: AbortSignal | null | undefined,
  ): Response | Promise<Response> {
    if (
      options.stall !== undefined && url.includes(options.stall) &&
      (options.stallMethod === undefined || options.stallMethod === method)
    ) {
      return haengtBisAbbruch(signal);
    }
    if (url.includes("/auth/v1/user")) {
      if (options.authStatus !== undefined) return jsonRes({ message: "invalid token" }, options.authStatus);
      return jsonRes({ id: USER_ID });
    }
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
      const params = JSON.parse(body) as JsonRecord;
      if (options.stallGateScope !== undefined && params.p_scope === options.stallGateScope) {
        return haengtBisAbbruch(signal);
      }
      return jsonRes({
        allowed: true,
        limit: 120,
        remaining: 119,
        resetAt: new Date(Date.now() + 600_000).toISOString(),
        windowSeconds: 600,
      });
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) return new Response(null, { status: 204 });
    if (url.includes("/rest/v1/rpc/ensure_default_chat_session")) return jsonRes(SESSION_ID);
    if (url.includes("/rest/v1/rpc/touch_chat_session")) return new Response(null, { status: 204 });
    if (url.includes("/rest/v1/rpc/claim_chat_quota")) return jsonRes([{ used: 1, remaining: 4 }]);
    if (url.includes("/rest/v1/rpc/refund_chat_quota")) return new Response(null, { status: 204 });
    if (url.includes("openrouter.ai")) {
      const parsed = JSON.parse(body) as JsonRecord;
      // Klassifizierer und Antwort trennen sich am Token-Budget (50 vs. 800).
      if (parsed.max_tokens === 50) {
        return jsonRes({
          choices: [{ message: { content: JSON.stringify({ category: "fitness", confidence: "high" }) } }],
        });
      }
      return jsonRes({
        choices: [{ message: { content: "Klar, machen wir." }, finish_reason: "stop" }],
      });
    }
    if (url.includes("/rest/v1/chat_messages")) {
      if (method === "POST") return new Response(null, { status: 201 });
      return jsonRes([]);
    }
    if (url.includes("/rest/v1/chat_sessions")) {
      if (method === "PATCH") return new Response(null, { status: 204 });
      if (url.includes("select=title")) return jsonRes([{ title: "Neue Unterhaltung" }]);
      return jsonRes([]);
    }
    throw new Error(`Unerwarteter fetch im Test: ${method} ${url}`);
  }

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const method = (init?.method ?? "GET").toUpperCase();
    const body = typeof init?.body === "string" ? init.body : "";
    calls.push({ url, method, body, hasSignal: Boolean(init?.signal) });
    try {
      return Promise.resolve(route(url, method, body, init?.signal));
    } catch (e) {
      return Promise.reject(e);
    }
  }) as typeof globalThis.fetch;

  return {
    calls,
    callsTo: (fragment: string) => calls.filter((call) => call.url.includes(fragment)),
    gateScopes: () =>
      calls
        .filter((call) => call.url.includes("consume_edge_rate_limit"))
        .map((call) => String((JSON.parse(call.body) as JsonRecord).p_scope)),
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

function makeRequest(payload: JsonRecord = { message: "wie viele kalorien hat eine banane" }): Request {
  return new Request("https://edge.test.invalid/coach-chat", {
    method: "POST",
    headers: {
      "authorization": "Bearer test-user-jwt",
      "content-type": "application/json",
      "cf-connecting-ip": CLIENT_IP,
    },
    body: JSON.stringify(payload),
  });
}

/** Kuerzt die Frist fuer einen Fall und stellt sie danach wieder her. */
async function mitKurzerFrist(run: () => Promise<void>): Promise<void> {
  const original = SUPABASE_TIMEOUTS_MS.call;
  SUPABASE_TIMEOUTS_MS.call = TEST_TIMEOUT_MS;
  try {
    await run();
  } finally {
    SUPABASE_TIMEOUTS_MS.call = original;
  }
}

// ---------------------------------------------------------------------------
// Nach dem Anspruch: der Slot darf nicht still verloren gehen
// ---------------------------------------------------------------------------

Deno.test("E1: haengendes storeMessage NACH dem Anspruch gibt den Slot zurueck", async () => {
  // Der teure Fall aus dem Befund. Der Slot ist beansprucht, die Antwort ist
  // noch nicht bezahlt — bleibt der INSERT haengen, muss die Erstattung
  // greifen statt das Isolate bis zum Plattform-Kill zu blockieren.
  await mitKurzerFrist(async () => {
    const stub = installFetch({ stall: "/rest/v1/chat_messages", stallMethod: "POST" });
    try {
      const res = await ohneHaenger(handleRequest(makeRequest()));
      assertEquals(res.status, 500, "Status");
      assertEquals((await res.json() as JsonRecord).error, "store_failed", "Fehlercode");
      assertEquals(stub.callsTo("claim_chat_quota").length, 1, "ein Anspruch");
      assertEquals(stub.callsTo("refund_chat_quota").length, 1, "der Slot kommt zurueck");
    } finally {
      stub.restore();
    }
  });
});

Deno.test("E1: ein haengender Auto-Titel kostet weder die Antwort noch den Slot", async () => {
  // Bewusste Grenzziehung: der Auto-Titel laeuft NACH dem Anspruch, ist aber
  // kosmetisch. Er wird geschluckt, nicht erstattet — der Slot bezahlt die
  // Antwort, und die kommt. Vorher hing die ganze Anfrage an dieser Stelle.
  await mitKurzerFrist(async () => {
    const stub = installFetch({ stall: "select=title" });
    try {
      const res = await ohneHaenger(handleRequest(makeRequest()));
      assertEquals(res.status, 200, "Status");
      const body = await res.json() as JsonRecord;
      assertEquals(body.reply, "Klar, machen wir.", "die Antwort wird ausgeliefert");
      assertEquals(body.remaining, 4, "der Slot ist verbraucht und wird als solcher gemeldet");
      assertEquals(stub.callsTo("refund_chat_quota").length, 0, "keine Erstattung fuer Kosmetik");
    } finally {
      stub.restore();
    }
  });
});

Deno.test("E1: ein haengender Anspruch endet als 500, ohne Erstattung auf Verdacht", async () => {
  // Umgekehrte Richtung: die Antwort der atomaren RPC geht verloren, also ist
  // unbekannt, ob die Zeile geschrieben wurde. Eine Erstattung auf Verdacht
  // waere ein Freislot pro Schluckauf, deshalb bleibt sie aus — festgenagelt,
  // damit die Entscheidung nicht spaeter versehentlich kippt.
  await mitKurzerFrist(async () => {
    const stub = installFetch({ stall: "claim_chat_quota" });
    try {
      const res = await ohneHaenger(handleRequest(makeRequest()));
      assertEquals(res.status, 500, "Status");
      assertEquals((await res.json() as JsonRecord).error, "rpc_unavailable", "Fehlercode");
      assertEquals(stub.callsTo("refund_chat_quota").length, 0, "keine Erstattung auf Verdacht");
      assertEquals(stub.callsTo("openrouter.ai").length, 0, "kein bezahlter Aufruf hinter dem Anspruch");
    } finally {
      stub.restore();
    }
  });
});

// ---------------------------------------------------------------------------
// Vor dem Anspruch: die Tore fallen geschlossen, die 401 bleibt ehrlich
// ---------------------------------------------------------------------------

Deno.test("E1: ein haengendes IP-Tor faellt geschlossen statt durchzulassen", async () => {
  await mitKurzerFrist(async () => {
    const stub = installFetch({ stallGateScope: "coach-chat:ip" });
    try {
      const res = await ohneHaenger(handleRequest(makeRequest()));
      assertEquals(res.status, 500, "Status");
      assertEquals((await res.json() as JsonRecord).error, "rate_limit_unavailable", "Fehlercode");
      // Ein stockender Limiter ist ein Ausfall, kein gemessenes Limit — und er
      // darf die Anfrage nicht an den bezahlten Aufrufen vorbeilassen.
      assertEquals(stub.callsTo("claim_chat_quota").length, 0, "kein Anspruch hinter dem offenen Tor");
      assertEquals(stub.callsTo("openrouter.ai").length, 0, "kein bezahlter Aufruf");
    } finally {
      stub.restore();
    }
  });
});

Deno.test("E1: ein haengender Auth-Lookup meldet 503 statt den Nutzer abzumelden", async () => {
  await mitKurzerFrist(async () => {
    const stub = installFetch({ stall: "/auth/v1/user" });
    try {
      const res = await ohneHaenger(handleRequest(makeRequest()));
      // 401 waere die falsche Antwort: der Client liest 401/403 als "Sitzung
      // vorbei" und meldet ab, obwohl der Auth-Server das Problem hat.
      assertEquals(res.status, 503, "Status");
      assertEquals((await res.json() as JsonRecord).error, "auth_unavailable", "Fehlercode");
      // Und ein langsamer Auth-Server darf nicht das Fail-Bucket fuellen, sonst
      // beantwortet er fremde 401 mit 429.
      assertEquals(stub.gateScopes().join(","), "", "kein Consume auf dem Ausfall-Pfad");
    } finally {
      stub.restore();
    }
  });
});

Deno.test("E1: ein haengendes Fail-Bucket blockiert die ehrliche 401 nicht", async () => {
  // Der Daempfer aus _shared/auth_fail_gate.ts bekommt dieselbe Frist. Ein
  // Abbruch meldet "nicht gedrosselt" — die 401 muss trotzdem kommen.
  await mitKurzerFrist(async () => {
    const stub = installFetch({ authStatus: 401, stallGateScope: "coach-chat:auth-fail" });
    try {
      const res = await ohneHaenger(handleRequest(makeRequest()));
      assertEquals(res.status, 401, "Status");
      assertEquals((await res.json() as JsonRecord).error, "Unauthorized", "Fehlercode");
      assertEquals(stub.gateScopes().join(","), "coach-chat:auth-fail", "der Consume wurde versucht");
      // Explizit, weil der Helfer JEDEN Fehler schluckt: ohne diese Zusicherung
      // saehe eine entfernte Frist genauso aus wie eine wirksame.
      const gateCall = stub.calls.find((call) => call.body.includes("coach-chat:auth-fail"));
      assertEquals(gateCall?.hasSignal, true, "der geteilte Gate bekommt die Frist des Aufrufers");
    } finally {
      stub.restore();
    }
  });
});

Deno.test("E1: eine haengende Sitzungspruefung landet nicht in der Standard-Unterhaltung", async () => {
  // E4 mit Frist: ein Timeout ist ein voruebergehender Fehler, nicht "nicht
  // deine Sitzung". Durchfallen wuerde die Nachricht in eine fremde
  // Unterhaltung schreiben.
  await mitKurzerFrist(async () => {
    const stub = installFetch({ stall: "select=id" });
    try {
      const res = await ohneHaenger(handleRequest(makeRequest({
        message: "wie viele kalorien hat eine banane",
        session_id: SESSION_ID,
      })));
      assertEquals(res.status, 500, "Status");
      assertEquals((await res.json() as JsonRecord).error, "session_unavailable", "Fehlercode");
      assertEquals(stub.callsTo("ensure_default_chat_session").length, 0, "kein Durchfallen in die Standard-Sitzung");
      assertEquals(stub.callsTo("claim_chat_quota").length, 0, "kein Anspruch");
    } finally {
      stub.restore();
    }
  });
});

Deno.test("E1: JEDER ausgehende Aufruf einer erfolgreichen Anfrage traegt eine Frist", async () => {
  // Wache gegen den naechsten fetch, der ohne Frist dazukommt: die Faelle
  // oben pruefen einzelne Stellen, dieser deckt den ganzen Durchlauf ab —
  // Auth, beide Tore, Aufraeumen, Sitzung, Verlauf, Anspruch, Klassifizierer,
  // Speichern, Titel, Antwort und touch.
  const stub = installFetch();
  try {
    const res = await ohneHaenger(handleRequest(makeRequest()));
    assertEquals(res.status, 200, "Status");
    const ohneFrist = stub.calls.filter((call) => !call.hasSignal);
    assertEquals(
      ohneFrist.map((call) => `${call.method} ${call.url}`).join("\n"),
      "",
      "Aufrufe ohne AbortSignal",
    );
    // Damit die Zusicherung nicht still leerlaeuft, wenn der Pfad sich aendert.
    assert(stub.calls.length >= 8, `zu wenige Aufrufe im Durchlauf: ${stub.calls.length}`);
  } finally {
    stub.restore();
  }
});
