// Tests for the defensive env parser (env.ts).
//
// The real regression is the "over the RPC bound" case: a ">= 0"-only check
// passed e.g. ANALYZE_MEAL_USER_LIMIT=100000 to consume_edge_rate_limit, whose
// SQL guard throws above 10000 and makes PostgREST answer 500.
//
// Deliberately without external test dependencies. CI runs
// `deno test --allow-env`; the variable names carry their own prefix so they
// cannot collide with other test files in the same process.

import {
  EDGE_RATE_LIMIT_MAX_LIMIT,
  EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS,
  positiveIntFromEnv,
} from "./env.ts";

const VAR = "ENV_RPC_BOUNDS_TEST_VALUE";
const FALLBACK = 20;

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

/** Sets VAR for the duration of the call and cleans up afterwards. */
function withValue(value: string | null, run: () => void): void {
  if (value === null) Deno.env.delete(VAR);
  else Deno.env.set(VAR, value);
  try {
    run();
  } finally {
    Deno.env.delete(VAR);
  }
}

function parsed(value: string | null, max?: number): number {
  let result = FALLBACK;
  withValue(value, () => {
    result = max === undefined
      ? positiveIntFromEnv(VAR, FALLBACK)
      : positiveIntFromEnv(VAR, FALLBACK, max);
  });
  return result;
}

Deno.test("REGRESSION: Werte ueber der RPC-Obergrenze fallen auf den Default", () => {
  // 10000 is the guard in consume_edge_rate_limit (p_limit > 10000 throws).
  assertEquals(EDGE_RATE_LIMIT_MAX_LIMIT, 10000, "Obergrenze muss dem SQL-Guard entsprechen");
  assertEquals(parsed("10001"), FALLBACK, "eins ueber der Grenze");
  assertEquals(parsed("100000"), FALLBACK, "Tippfehler mit einer Null zu viel");
  assertEquals(parsed("999999999"), FALLBACK, "offensichtlicher Unsinn");
});

Deno.test("Werte innerhalb der RPC-Grenzen kommen unveraendert durch", () => {
  assertEquals(parsed("1"), 1, "unterster erlaubter Wert");
  assertEquals(parsed("60"), 60, "typischer Wert");
  assertEquals(parsed("10000"), 10000, "exakt die Obergrenze bleibt erlaubt");
  assertEquals(parsed(" 3600 "), 3600, "Whitespace wird getrimmt");
});

Deno.test("Fenster-Aufrufer koennen die weitere Grenze explizit uebergeben", () => {
  // p_window_seconds may go up to 86400 (24 h); without an explicit max the
  // narrower default cap applies.
  assertEquals(EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS, 86400, "Fenster-Guard aus der Migration");
  assertEquals(parsed("86400", EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS), 86400, "24 h erlaubt");
  assertEquals(
    parsed("86401", EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS),
    FALLBACK,
    "eine Sekunde ueber 24 h wirft in der RPC",
  );
  assertEquals(parsed("86400"), FALLBACK, "ohne explizites max greift der engere Deckel");
});

Deno.test("F9-01: Tagesfenster-Werte ueber 10000 s brauchen das explizite max", () => {
  // The footgun behind analyze-meal's day caps: a day window read via
  // positiveIntFromEnv WITHOUT max silently becomes the fallback — with a
  // day-long fallback the operator would never notice the override is dead.
  const DAY_FALLBACK = 86400;
  let withMax = 0;
  let withoutMax = 0;
  withValue("43200", () => {
    withMax = positiveIntFromEnv(VAR, DAY_FALLBACK, EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS);
    withoutMax = positiveIntFromEnv(VAR, DAY_FALLBACK);
  });
  assertEquals(withMax, 43200, "12 h mit explizitem Fenster-max kommt durch");
  assertEquals(withoutMax, DAY_FALLBACK, "12 h ohne max faellt still auf den Tages-Default");
  assertEquals(parsed("86400", EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS), 86400, "voller Tag erlaubt");
  assertEquals(parsed("172800", EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS), FALLBACK, "zwei Tage wirft in der RPC");
});

Deno.test("bisheriges Verhalten bleibt: unbrauchbare Werte -> Default", () => {
  assertEquals(parsed(null), FALLBACK, "nicht gesetzt");
  assertEquals(parsed(""), FALLBACK, "leer");
  assertEquals(parsed("   "), FALLBACK, "nur Whitespace");
  assertEquals(parsed("abc"), FALLBACK, "nicht numerisch");
  assertEquals(parsed("20x"), FALLBACK, "Ziffern mit Anhang");
  assertEquals(parsed("2.5"), FALLBACK, "kein Integer");
  assertEquals(parsed("-5"), FALLBACK, "negativ");
  assertEquals(parsed("0"), FALLBACK, "Null waere ein Totalblock");
  // Beyond Number.MAX_SAFE_INTEGER parseInt rounds silently, so the value
  // would no longer be the configured one.
  assertEquals(parsed("9".repeat(30)), FALLBACK, "kein sicherer Integer");
});
