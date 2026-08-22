// Tests for the opportunistic table hygiene (rate_limit_prune.ts).
//
// The regression: `void pruneRateLimits()` against a version WITHOUT try/catch
// turned a rejecting fetch into an unhandled rejection that killed the isolate,
// in analyze-meal mid paid model call.
//
// Two things are measured:
//  1. the hardened version's promise resolves while the OLD one (naiverPrune,
//     a faithful replica) rejects — an unheld rejecting promise IS the
//     unhandled rejection.
//  2. the fire-and-forget call really raises no "unhandledrejection" event.
//
// No external test dependencies and no network: globalThis.fetch is replaced.

import { pruneRateLimits } from "./rate_limit_prune.ts";

const SUPABASE_URL = "https://supabase.test.invalid";
const SERVICE_KEY = "test-service-role-key-0123456789";
const OPTIONS = { supabaseUrl: SUPABASE_URL, serviceKey: SERVICE_KEY };
const RPC_URL = `${SUPABASE_URL}/rest/v1/rpc/prune_edge_rate_limits`;

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

/** Captures console.error: the diagnostic line is part of the contract but
 *  should not clutter the test output. */
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

/** Faithful replica of the pre-fix version. Control sample only: it proves the
 *  failure case below really produces a rejecting fetch. */
async function naiverPrune(): Promise<void> {
  await fetch(RPC_URL, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      authorization: `Bearer ${SERVICE_KEY}`,
      "content-type": "application/json",
    },
    body: "{}",
  });
}

/** "resolved" / "rejected", without ever leaving the rejection unhandled. */
async function ausgang(promise: Promise<unknown>): Promise<string> {
  return await promise.then(() => "resolved", () => "rejected");
}

const netzfehler = () => Promise.reject(new TypeError("error sending request for url"));

Deno.test("REGRESSION: ein rejectender fetch schlaegt nicht nach aussen durch", async () => {
  const fetchStub = installFetch(netzfehler);
  const log = installErrorLog();
  try {
    assertEquals(
      await ausgang(pruneRateLimits(OPTIONS)),
      "resolved",
      "ein Netzwerkfehler beim Aufraeumen darf nie nach aussen durchschlagen — " +
        "`void pruneRateLimits(...)` haelt das Promise nicht, die Rejection " +
        "beendet den Isolate mitten im laufenden Request",
    );
    // Control sample: same stub against the old version. If it does not reject
    // here, the assertion above measures nothing.
    assertEquals(
      await ausgang(naiverPrune()),
      "rejected",
      "die alte, ungeschuetzte Fassung muss in diesem Aufbau rejecten",
    );
    assertEquals(fetchStub.aufrufe.length, 2, "beide Fassungen haben gefetcht");
    assert(
      log.zeilen.some((zeile) => zeile.includes("prune_edge_rate_limits failed")),
      `der geschluckte Fehler muss geloggt werden, Zeilen: ${JSON.stringify(log.zeilen)}`,
    );
  } finally {
    log.restore();
    fetchStub.restore();
  }
});

Deno.test("REGRESSION: der fire-and-forget-Aufruf erzeugt keine unhandled rejection", async () => {
  const fetchStub = installFetch(netzfehler);
  const log = installErrorLog();
  const gesammelt: string[] = [];
  const listener = (event: Event) => {
    // Without preventDefault() the test run would end here; in production it
    // is the isolate.
    event.preventDefault();
    const grund = (event as Event & { reason?: unknown }).reason;
    gesammelt.push(grund instanceof Error ? grund.message : String(grund));
  };
  globalThis.addEventListener("unhandledrejection", listener);
  try {
    // Exactly the call from analyze-meal/search-key.
    void pruneRateLimits(OPTIONS);
    // The runtime reports an unhandled rejection only after the microtask
    // checkpoint of its tick — wait two macrotasks.
    await new Promise((resolve) => setTimeout(resolve, 0));
    await new Promise((resolve) => setTimeout(resolve, 0));
    assertEquals(
      gesammelt.length,
      0,
      `unbehandelte Rejection(s) aus dem fire-and-forget-Aufruf: ${JSON.stringify(gesammelt)}`,
    );
  } finally {
    globalThis.removeEventListener("unhandledrejection", listener);
    log.restore();
    fetchStub.restore();
  }
});

Deno.test("ein HTTP-Fehlerstatus wird geschluckt, aber mit Status geloggt", async () => {
  // fetch does not throw on 5xx — without an explicit check a permanently
  // broken RPC would be invisible.
  const fetchStub = installFetch(() => Promise.resolve(new Response("boom", { status: 500 })));
  const log = installErrorLog();
  try {
    assertEquals(
      await ausgang(pruneRateLimits(OPTIONS)),
      "resolved",
      "ein Fehlerstatus der RPC darf den Request nicht anfassen",
    );
    assert(
      log.zeilen.some((zeile) => zeile.includes("prune_edge_rate_limits failed: HTTP 500")),
      `Status 500 muss diagnostizierbar sein, Zeilen: ${JSON.stringify(log.zeilen)}`,
    );
  } finally {
    log.restore();
    fetchStub.restore();
  }
});

Deno.test("der Service-Key steht nie in der Fehlerzeile", async () => {
  const faelle: (() => Promise<Response>)[] = [
    () => Promise.reject(new TypeError(`error sending request for ${RPC_URL}`)),
    () => Promise.resolve(new Response(SERVICE_KEY, { status: 401 })),
  ];
  for (const fall of faelle) {
    const fetchStub = installFetch(fall);
    const log = installErrorLog();
    try {
      await pruneRateLimits(OPTIONS);
      const zeilen = log.zeilen.join("\n");
      assert(!zeilen.includes(SERVICE_KEY), `der Service-Key ist im Log gelandet: ${zeilen}`);
    } finally {
      log.restore();
      fetchStub.restore();
    }
  }
});

Deno.test("Erfolgsfall: POST auf die RPC, Service-Key in beiden Headern, leerer JSON-Body", async () => {
  const fetchStub = installFetch(() => Promise.resolve(new Response(null, { status: 204 })));
  const log = installErrorLog();
  try {
    await pruneRateLimits(OPTIONS);
    assertEquals(fetchStub.aufrufe.length, 1, "genau ein Aufruf");
    const [aufruf] = fetchStub.aufrufe;
    assertEquals(aufruf.url, RPC_URL, "RPC-URL");
    assertEquals(aufruf.init?.method, "POST", "Methode");
    assertEquals(aufruf.init?.body, "{}", "Body");
    const headers = new Headers(aufruf.init?.headers);
    // The RPC is granted to service_role only (migration
    // 20260517220000_security_hardening.sql); PostgREST needs apikey AND
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
