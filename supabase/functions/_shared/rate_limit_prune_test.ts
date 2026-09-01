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
// A6 (performance audit 2026-09-01) added sampling, so every case below states
// its draw explicitly. Nothing here may depend on Math.random: with the default
// divisor of 20, an assertion about the outgoing call would otherwise hold in
// one run out of twenty.
//
// No external test dependencies and no network: globalThis.fetch is replaced.

import {
  PRUNE_SAMPLE_RATE,
  PRUNE_SAMPLE_RATE_ENV,
  PRUNE_SAMPLE_RATE_MAX,
  pruneRateLimits,
} from "./rate_limit_prune.ts";

const SUPABASE_URL = "https://supabase.test.invalid";
const SERVICE_KEY = "test-service-role-key-0123456789";

/** Draws the pruning slot at every rate (0 * rate floors to 0). */
const SAMPLER_IMMER = () => 0;
/** Loses at every rate above 1 — the highest draw Math.random can produce. */
const SAMPLER_NIE = () => 0.999999;

/** The pre-A6 default of every case that asserts the outgoing call. */
const OPTIONS = { supabaseUrl: SUPABASE_URL, serviceKey: SERVICE_KEY, sampler: SAMPLER_IMMER };
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

/** Captures console.warn, which positiveIntFromEnv uses for a set-but-unusable
 *  value. Same reason as installErrorLog: contract, not test output. */
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

/** Sets PRUNE_SAMPLE_RATE for the duration of `fn` and restores the previous
 *  state — deleting it again if it was unset.
 *
 *  Mandatory (P5-08b): the whole Deno suite runs in ONE isolate, so a leaked
 *  variable would silently reconfigure every sibling file that comes after. */
async function mitSampleRate(wert: string | undefined, fn: () => Promise<void>): Promise<void> {
  const vorher = Deno.env.get(PRUNE_SAMPLE_RATE_ENV);
  if (wert === undefined) Deno.env.delete(PRUNE_SAMPLE_RATE_ENV);
  else Deno.env.set(PRUNE_SAMPLE_RATE_ENV, wert);
  try {
    await fn();
  } finally {
    if (vorher === undefined) Deno.env.delete(PRUNE_SAMPLE_RATE_ENV);
    else Deno.env.set(PRUNE_SAMPLE_RATE_ENV, vorher);
  }
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

// ---------------------------------------------------------------------------
// A6 (performance audit 2026-09-01): the prune is sampled.
//
// The cases below pin the two halves of that: the drawn call must look exactly
// like the pre-A6 one, and the skipped call must be indistinguishable from a
// successful one to the CALLER — same resolved promise, no log, no isolate-
// killing rejection. The second half is the one that matters, because every
// call site is `void`-ed and would never notice a broken skip path.
// ---------------------------------------------------------------------------

Deno.test("A6: ohne Los geht kein fetch raus und das Promise resolved trotzdem", async () => {
  // The stub would REJECT if it were reached — so this also proves the skip
  // happens before the network, not after a swallowed error.
  const fetchStub = installFetch(netzfehler);
  const log = installErrorLog();
  try {
    assertEquals(
      await ausgang(pruneRateLimits({ ...OPTIONS, sampler: SAMPLER_NIE })),
      "resolved",
      "ein uebersprungener Aufruf muss genauso still resolven wie ein erfolgreicher",
    );
    assertEquals(fetchStub.aufrufe.length, 0, "ein verlorenes Los darf nichts senden");
    assertEquals(
      log.zeilen.length,
      0,
      `ein uebersprungener Aufruf ist der Normalfall und wird nicht geloggt: ${JSON.stringify(log.zeilen)}`,
    );
  } finally {
    log.restore();
    fetchStub.restore();
  }
});

Deno.test("A6: auch der uebersprungene fire-and-forget-Aufruf erzeugt keine unhandled rejection", async () => {
  // Same guard as the regression test above, for the path that did not exist
  // before A6. `void` haelt das Promise nicht — auch das leere muss halten.
  const fetchStub = installFetch(netzfehler);
  const gesammelt: string[] = [];
  const listener = (event: Event) => {
    event.preventDefault();
    const grund = (event as Event & { reason?: unknown }).reason;
    gesammelt.push(grund instanceof Error ? grund.message : String(grund));
  };
  globalThis.addEventListener("unhandledrejection", listener);
  try {
    void pruneRateLimits({ ...OPTIONS, sampler: SAMPLER_NIE });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await new Promise((resolve) => setTimeout(resolve, 0));
    assertEquals(gesammelt.length, 0, `unbehandelte Rejection(s): ${JSON.stringify(gesammelt)}`);
    assertEquals(fetchStub.aufrufe.length, 0, "ein verlorenes Los darf nichts senden");
  } finally {
    globalThis.removeEventListener("unhandledrejection", listener);
    fetchStub.restore();
  }
});

Deno.test("A6: die Grenze liegt exakt bei 1/PRUNE_SAMPLE_RATE", async () => {
  // Numerically pinned, not "roughly every 20th": a divisor that silently
  // became 1 again would still pass every other case in this file.
  const knappDrunter = (1 / PRUNE_SAMPLE_RATE) - 0.001;
  const genauDrauf = 1 / PRUNE_SAMPLE_RATE;
  const faelle: [number, number][] = [[knappDrunter, 1], [genauDrauf, 0]];
  for (const [los, erwartet] of faelle) {
    const fetchStub = installFetch(() => Promise.resolve(new Response(null, { status: 204 })));
    try {
      await pruneRateLimits({ ...OPTIONS, sampler: () => los });
      assertEquals(fetchStub.aufrufe.length, erwartet, `Los ${los} bei Rate ${PRUNE_SAMPLE_RATE}`);
    } finally {
      fetchStub.restore();
    }
  }
});

Deno.test("A6: Fehler werden in beiden Modi geschluckt", async () => {
  // (c) of the A6 brief. "Swallowed" means something different per mode: with
  // the slot drawn, the rejecting fetch and the 500 land in the catch; without
  // it, there is nothing to swallow and the silence must be complete.
  const antworten: (() => Promise<Response>)[] = [
    netzfehler,
    () => Promise.resolve(new Response("boom", { status: 500 })),
  ];
  for (const antwort of antworten) {
    for (const sampler of [SAMPLER_IMMER, SAMPLER_NIE]) {
      const gezogen = sampler === SAMPLER_IMMER;
      const fetchStub = installFetch(antwort);
      const log = installErrorLog();
      try {
        assertEquals(
          await ausgang(pruneRateLimits({ ...OPTIONS, sampler })),
          "resolved",
          `resolved (Los gezogen: ${gezogen})`,
        );
        assertEquals(fetchStub.aufrufe.length, gezogen ? 1 : 0, `fetches (Los gezogen: ${gezogen})`);
        assertEquals(
          log.zeilen.length,
          gezogen ? 1 : 0,
          `nur der gesendete Aufruf diagnostiziert: ${JSON.stringify(log.zeilen)}`,
        );
      } finally {
        log.restore();
        fetchStub.restore();
      }
    }
  }
});

Deno.test("A6: PRUNE_SAMPLE_RATE aus der Umgebung entscheidet mit", async () => {
  // Same draw, two environments: only the env var can explain the difference,
  // so this fails if the variable is ignored or read once at module load.
  const los = () => 0.1;
  const faelle: [string | undefined, number][] = [
    ["5", 1], // 0.1 * 5 = 0.5 -> Los gezogen
    [undefined, 0], // 0.1 * 20 = 2.0 -> Los verloren
  ];
  for (const [wert, erwartet] of faelle) {
    await mitSampleRate(wert, async () => {
      const fetchStub = installFetch(() => Promise.resolve(new Response(null, { status: 204 })));
      try {
        await pruneRateLimits({ ...OPTIONS, sampler: los });
        assertEquals(fetchStub.aufrufe.length, erwartet, `${PRUNE_SAMPLE_RATE_ENV}=${wert}`);
      } finally {
        fetchStub.restore();
      }
    });
  }
});

Deno.test(`A6: ${PRUNE_SAMPLE_RATE_ENV}=1 stellt das Verhalten vor A6 wieder her`, async () => {
  // The documented escape hatch: an operator who wants every request to prune
  // again, and the way a suite outside _shared pins the call without the
  // sampler seam. Must beat even the worst possible draw.
  await mitSampleRate("1", async () => {
    const fetchStub = installFetch(() => Promise.resolve(new Response(null, { status: 204 })));
    try {
      await pruneRateLimits({ supabaseUrl: SUPABASE_URL, serviceKey: SERVICE_KEY, sampler: SAMPLER_NIE });
      assertEquals(fetchStub.aufrufe.length, 1, "Rate 1 prunt jeden Aufruf");
    } finally {
      fetchStub.restore();
    }
  });
});

Deno.test("A6: ein unbrauchbarer PRUNE_SAMPLE_RATE schaltet das Aufraeumen nicht ab", async () => {
  // The failure direction that matters: a fat-fingered secret must fall back to
  // the code default, not to "never prune again". Both values are unique in
  // this suite so the parse is not served from the memo of an earlier case.
  const faelle = ["zwanzig", String(PRUNE_SAMPLE_RATE_MAX + 1)];
  for (const wert of faelle) {
    await mitSampleRate(wert, async () => {
      const fetchStub = installFetch(() => Promise.resolve(new Response(null, { status: 204 })));
      const warn = installWarnLog();
      try {
        // 0.01 * 20 = 0.2 -> gezogen, wenn wirklich der Default 20 gilt.
        await pruneRateLimits({ ...OPTIONS, sampler: () => 0.01 });
        assertEquals(fetchStub.aufrufe.length, 1, `Default greift bei ${PRUNE_SAMPLE_RATE_ENV}=${wert}`);
        assert(
          warn.zeilen.some((zeile) => zeile.includes(PRUNE_SAMPLE_RATE_ENV)),
          `ein ignorierter Wert muss den Operator warnen, Zeilen: ${JSON.stringify(warn.zeilen)}`,
        );
        assert(
          !warn.zeilen.some((zeile) => zeile.includes(wert)),
          `der Wert selbst gehoert nicht ins Log (CWE-532): ${JSON.stringify(warn.zeilen)}`,
        );
      } finally {
        warn.restore();
        fetchStub.restore();
      }
    });
  }
});

Deno.test("A6: ein unbrauchbares Los prunt, statt still nie wieder aufzuraeumen", async () => {
  // Math.floor(NaN) is never 0, so an injected source that is not
  // Math.random-shaped would otherwise turn the cleanup off permanently —
  // invisibly, because nobody reads the result.
  for (const los of [Number.NaN, Number.POSITIVE_INFINITY, 1.5, -0.5]) {
    const fetchStub = installFetch(() => Promise.resolve(new Response(null, { status: 204 })));
    try {
      await pruneRateLimits({ ...OPTIONS, sampler: () => los });
      assertEquals(fetchStub.aufrufe.length, 1, `unbrauchbares Los ${los} prunt trotzdem`);
    } finally {
      fetchStub.restore();
    }
  }
});

Deno.test("A6: ein werfender Sampler bricht die Immer-resolved-Zusage nicht", async () => {
  const fetchStub = installFetch(() => Promise.resolve(new Response(null, { status: 204 })));
  const log = installErrorLog();
  try {
    assertEquals(
      await ausgang(pruneRateLimits({
        ...OPTIONS,
        sampler: () => {
          throw new Error("sampler kaputt");
        },
      })),
      "resolved",
      "auch fremder Code im Sampler darf den Isolate nicht mitnehmen",
    );
    assertEquals(fetchStub.aufrufe.length, 0, "nach einem Wurf wird nicht gesendet");
  } finally {
    log.restore();
    fetchStub.restore();
  }
});
