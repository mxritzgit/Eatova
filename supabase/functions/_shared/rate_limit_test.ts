// Tests for the shared consume_edge_rate_limits client (rate_limit.ts).
//
// Every limiter problem must come back as `unavailable` — never as a pass and
// never as an invented 429 — and a short answer counts only at a denial.
// Pure fetch stubs, no network, no environment.

import { consumeRateLimits, RATE_LIMIT_MAX_RESPONSE_BYTES, retryAfterSeconds } from "./rate_limit.ts";
import type { RateLimitGate, RateLimitOutcome } from "./rate_limit.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

const NOW = Date.parse("2026-10-18T12:00:00.000Z");
const SUBJECT = "11111111-1111-4111-8111-111111111111";
const GATES: RateLimitGate[] = [
  { scope: "test:ip", subject: "ip-subject-hash", limit: 120, windowSeconds: 600 },
  { scope: "test:user", subject: SUBJECT, limit: 60, windowSeconds: 3600 },
];

type Call = { url: string; init: RequestInit; body: Record<string, unknown> };
type Reply = (call: Call) => Response | Promise<Response>;

async function withFetch(
  reply: Reply,
  run: (calls: Call[], logs: string[]) => Promise<void>,
): Promise<void> {
  const originalFetch = globalThis.fetch;
  const originalError = console.error;
  const originalNow = Date.now;
  const calls: Call[] = [];
  const logs: string[] = [];
  Date.now = () => NOW;
  console.error = (...args: unknown[]) => logs.push(args.map(String).join(" "));
  globalThis.fetch = ((input: string | URL | Request, init: RequestInit = {}) => {
    const call = { url: String(input), init, body: JSON.parse(String(init.body ?? "{}")) };
    calls.push(call);
    return Promise.resolve(reply(call));
  }) as typeof fetch;
  try {
    await run(calls, logs);
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalError;
    Date.now = originalNow;
  }
}

function consume(signal: AbortSignal = AbortSignal.timeout(5_000)): Promise<RateLimitOutcome> {
  return consumeRateLimits({ supabaseUrl: "https://db.test.invalid", serviceKey: "service-key", gates: GATES, signal });
}

function verdict(gate: RateLimitGate, allowed = true): Record<string, unknown> {
  return {
    allowed,
    limit: gate.limit,
    remaining: allowed ? gate.limit - 1 : 0,
    resetAt: new Date(NOW + gate.windowSeconds * 1000).toISOString(),
    windowSeconds: gate.windowSeconds,
  };
}

Deno.test("rate_limit: all gates allowed -> verdicts by index, one call with the RPC wire shape", async () => {
  await withFetch(() => Response.json(GATES.map((gate) => verdict(gate))), async (calls) => {
    const outcome = await consume();
    assert(outcome.kind === "allowed", `allowed erwartet, war ${outcome.kind}`);
    assertEquals(outcome.verdicts.map((v) => v.limit), [120, 60], "Verdicts in Tor-Reihenfolge");
    assertEquals(calls.length, 1, "genau ein Roundtrip");
    const call = calls[0];
    assertEquals(call.url, "https://db.test.invalid/rest/v1/rpc/consume_edge_rate_limits", "RPC-URL");
    assertEquals(call.body, {
      p_gates: GATES.map((gate) => ({
        scope: gate.scope, subject: gate.subject, limit: gate.limit, window_seconds: gate.windowSeconds,
      })),
    }, "Elementform des RPC");
    const headers = new Headers(call.init.headers);
    assertEquals(headers.get("authorization"), "Bearer service-key", "Service-Bearer");
    assertEquals(headers.get("apikey"), "service-key", "apikey");
    assertEquals(call.init.redirect, "error", "Service-Key folgt keinem Redirect");
  });
});

Deno.test("rate_limit: missing numbers fall back to the gate's own values", async () => {
  await withFetch(() => Response.json([{ allowed: true }, { allowed: true }]), async () => {
    const outcome = await consume();
    assert(outcome.kind === "allowed", "allowed");
    assertEquals(outcome.verdicts[1], {
      allowed: true,
      limit: 60,
      remaining: 0,
      resetAt: new Date(NOW + 3600 * 1000).toISOString(),
      windowSeconds: 3600,
    }, "Defaults aus dem Tor");
  });
});

Deno.test("rate_limit: the first denial wins and a short answer behind it is legal", async () => {
  await withFetch(() => Response.json([verdict(GATES[0], false)]), async () => {
    const outcome = await consume();
    assert(outcome.kind === "denied", `denied erwartet, war ${outcome.kind}`);
    assertEquals(outcome.deniedIndex, 0, "Index");
    assertEquals(outcome.deniedScope, "test:ip", "Scope");
    assertEquals(outcome.denied.windowSeconds, 600, "Zahlen des ablehnenden Tors");
  });
  await withFetch(() => Response.json([verdict(GATES[0]), verdict(GATES[1], false)]), async () => {
    const outcome = await consume();
    assert(outcome.kind === "denied" && outcome.deniedIndex === 1, "zweites Tor lehnt ab");
  });
});

Deno.test("rate_limit: every unreadable answer is an outage, never a pass or an invented 429", async () => {
  const cases: { was: string; reply: () => Response; reason: string }[] = [
    { was: "HTTP 500", reply: () => new Response("{}", { status: 500 }), reason: "http_status" },
    { was: "HTTP 404 (RPC fehlt)", reply: () => new Response("{}", { status: 404 }), reason: "http_status" },
    { was: "kein JSON", reply: () => new Response("<html>", { status: 200 }), reason: "body" },
    { was: "leerer Body", reply: () => new Response(null, { status: 200 }), reason: "body" },
    { was: "zu gross", reply: () => new Response("[" + " ".repeat(RATE_LIMIT_MAX_RESPONSE_BYTES) + "]"), reason: "body" },
    { was: "Objekt statt Array", reply: () => Response.json({ allowed: true }), reason: "shape" },
    { was: "leeres Array", reply: () => Response.json([]), reason: "shape" },
    { was: "mehr Elemente als Tore", reply: () => Response.json([...GATES, GATES[0]].map((gate) => verdict(gate))), reason: "shape" },
    { was: "kurz ohne Ablehnung", reply: () => Response.json([verdict(GATES[0])]), reason: "incomplete" },
    { was: "null-Element", reply: () => Response.json([verdict(GATES[0]), null]), reason: "shape" },
  ];
  // Truthy foreign types are the dangerous half: a truthiness check reads them as allowed.
  for (const allowed of [undefined, "true", "false", 1, 0, null, {}]) {
    cases.push({
      was: `allowed=${JSON.stringify(allowed)}`,
      reply: () => Response.json([verdict(GATES[0]), { ...verdict(GATES[1]), allowed }]),
      reason: "shape",
    });
  }
  for (const fall of cases) {
    await withFetch(fall.reply, async () => {
      const outcome = await consume();
      assertEquals(outcome, { kind: "unavailable", reason: fall.reason }, fall.was);
    });
  }
});

Deno.test("rate_limit: a short answer without a denial names the missing gates in the log", async () => {
  await withFetch(() => Response.json([verdict(GATES[0])]), async (_calls, logs) => {
    await consume();
    assert(logs.some((line) => line.includes("nur 1/2 Tore")), `Log: ${logs.join(" | ")}`);
  });
});

Deno.test("rate_limit: transport failure, timeout and caller abort are outages", async () => {
  await withFetch(() => { throw new TypeError("connection refused to https://db.test.invalid"); }, async (_calls, logs) => {
    assertEquals(await consume(), { kind: "unavailable", reason: "transport" }, "Transport");
    assert(!logs.join(" ").includes("connection refused"), "Ausnahmetext bleibt aus dem Log");
  });
  await withFetch(({ init }) => new Promise<Response>((_resolve, reject) => {
    init.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
  }), async (_calls, logs) => {
    assertEquals(await consume(AbortSignal.timeout(5)), { kind: "unavailable", reason: "timeout" }, "Timeout");
    assert(logs.some((line) => line.includes("timeout")), "Timeout wird gemeldet");
  });
  await withFetch(({ init }) => new Promise<Response>((_resolve, reject) => {
    init.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
  }), async (_calls, logs) => {
    const controller = new AbortController();
    const pending = consume(controller.signal);
    controller.abort();
    assertEquals(await pending, { kind: "unavailable", reason: "aborted" }, "Abbruch durch den Aufrufer");
    assertEquals(logs.length, 0, "ein Abbruch des Aufrufers ist kein Limiter-Befund");
  });
});

Deno.test("rate_limit: a 200 whose body stalls ends at the deadline as an outage", async () => {
  // The stub ignores the signal on purpose; the client must cancel the read itself.
  await withFetch(() => new Response(new ReadableStream<Uint8Array>({ pull: () => new Promise(() => {}) })), async () => {
    assertEquals(await consume(AbortSignal.timeout(10)), { kind: "unavailable", reason: "timeout" }, "stockender Body");
  });
});

Deno.test("rate_limit: an error answer does not wait for a stalled body cancellation", async () => {
  const stalled = () => new Response(new ReadableStream<Uint8Array>({ cancel: () => new Promise<void>(() => {}) }), { status: 503 });
  await withFetch(stalled, async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const outcome = await Promise.race([
        consume(),
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error("wartete auf body.cancel()")), 1000);
        }),
      ]);
      assertEquals(outcome, { kind: "unavailable", reason: "http_status" }, "Status");
    } finally {
      clearTimeout(timer);
    }
  });
});

Deno.test("rate_limit: diagnostics carry scopes and statuses, never response values or subjects", async () => {
  const marker = "PRIVATE_LIMITER_RESPONSE_SENTINEL";
  for (const reply of [
    () => Response.json([verdict(GATES[0]), { allowed: marker }]),
    () => new Response(marker, { status: 500 }),
    () => new Response(marker, { status: 200 }),
  ]) {
    await withFetch(reply, async (_calls, logs) => {
      await consume();
      const text = logs.join(" ");
      assert(text.includes("consume_edge_rate_limits"), "Operation bleibt erkennbar");
      assert(!text.includes(marker), `Antwortwert im Log: ${text}`);
      assert(!text.includes(SUBJECT), `Subject im Log: ${text}`);
    });
  }
});

Deno.test("retryAfterSeconds: seconds to reset, at least 1, fallback and optional ceiling", () => {
  const now = NOW;
  assertEquals(retryAfterSeconds(new Date(now + 90_500).toISOString(), 600, Infinity, now), 91, "aufgerundet");
  assertEquals(retryAfterSeconds(new Date(now - 5_000).toISOString(), 600, Infinity, now), 1, "nie unter 1");
  assertEquals(retryAfterSeconds("kein Datum", 600, Infinity, now), 600, "Fallback");
  assertEquals(retryAfterSeconds(new Date(now + 3 * 86_400_000).toISOString(), 600, 86_400, now), 86_400, "Deckel");
});
