// Tests fuer den defensiven Env-Parser (env.ts).
//
// Der eigentliche Regressionstest steht unter "REGRESSION: Werte ueber der
// RPC-Obergrenze": die alte Fassung pruefte nur "> 0" und reichte damit z. B.
// ein versehentliches ANALYZE_MEAL_USER_LIMIT=100000 an
// consume_edge_rate_limit durch. Deren SQL-Guard wirft ueber 10000, PostgREST
// antwortet 500 - also genau der Totalausfall, den dieses Modul laut seinem
// eigenen Kopf verhindern soll.
//
// Bewusst ohne externe Test-Dependencies (gleicher Stil wie client_ip_test.ts).
// Die CI faehrt `deno test --allow-env`; die Variablennamen tragen ein eigenes
// Praefix, damit sie mit keiner anderen Testdatei im selben Prozess kollidieren.

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

/** Setzt VAR fuer die Dauer des Aufrufs und raeumt danach wieder auf. */
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
  // 10000 ist der Guard aus consume_edge_rate_limit (p_limit > 10000 wirft).
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
  // p_window_seconds darf bis 86400 (24 h) gehen; ohne explizites max greift
  // der engere Default-Deckel.
  assertEquals(EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS, 86400, "Fenster-Guard aus der Migration");
  assertEquals(parsed("86400", EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS), 86400, "24 h erlaubt");
  assertEquals(
    parsed("86401", EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS),
    FALLBACK,
    "eine Sekunde ueber 24 h wirft in der RPC",
  );
  assertEquals(parsed("86400"), FALLBACK, "ohne explizites max greift der engere Deckel");
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
  // Jenseits von Number.MAX_SAFE_INTEGER: parseInt rundet still, der Wert
  // waere danach nicht mehr der konfigurierte.
  assertEquals(parsed("9".repeat(30)), FALLBACK, "kein sicherer Integer");
});
