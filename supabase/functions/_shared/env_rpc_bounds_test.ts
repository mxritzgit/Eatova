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

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

/** console.warn lines of the most recent withValue() call (P6-03). */
let warnings: string[] = [];

/** Sets VAR for the duration of the call, records console.warn and cleans up
 *  afterwards. */
function withValue(value: string | null, run: () => void): void {
  if (value === null) Deno.env.delete(VAR);
  else Deno.env.set(VAR, value);
  warnings = [];
  const originalWarn = console.warn;
  console.warn = (...args: unknown[]) => {
    warnings.push(args.map((arg) => JSON.stringify(arg)).join(" "));
  };
  try {
    run();
  } finally {
    console.warn = originalWarn;
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

// ---------------------------------------------------------------------------
// P6-03 (review 2026-08-29): a value that IS set but gets discarded must say
// so. The silent fallback was the real trap — an operator who sets a day
// window to tighten a paid limit gets the looser code default back and has
// nothing to notice it by.
// ---------------------------------------------------------------------------

Deno.test("P6-03: ein gesetzter, verworfener Wert wird geloggt", () => {
  assertEquals(parsed("86400"), FALLBACK, "Tagesfenster ohne explizites max faellt zurueck");
  const joined = warnings.join("\n");
  assertEquals(warnings.length, 1, `genau eine Warnung erwartet, waren: ${joined}`);
  assert(joined.includes(VAR), `Variablenname fehlt: ${joined}`);
  assert(joined.includes(String(FALLBACK)), `der wirksame Default fehlt: ${joined}`);
  assert(joined.includes(String(EDGE_RATE_LIMIT_MAX_LIMIT)), `die verletzte Grenze fehlt: ${joined}`);
  // E2: der Wert selbst steht NICHT mehr drin (siehe unten), aber die Zeile
  // muss weiter sagen, WARUM verworfen wurde und wie gross der Wert war.
  assert(joined.includes("out of range"), `der Grund fehlt: ${joined}`);
  assert(joined.includes("valueLength"), `die Laenge fehlt: ${joined}`);
});

Deno.test("P6-03: auch unbrauchbare Formate warnen", () => {
  for (const value of ["abc", "20x", "2.5", "-5", "0", "9".repeat(30)]) {
    assertEquals(parsed(value), FALLBACK, value);
    assertEquals(warnings.length, 1, `keine Warnung fuer ${value}`);
  }
});

Deno.test("P6-03: nicht gesetzt, leer und gueltig bleiben still", () => {
  // Every deployment without overrides runs through here; warning would drown
  // the real signal.
  for (const value of [null, "", "   "]) {
    assertEquals(parsed(value), FALLBACK, JSON.stringify(value));
    assertEquals(warnings.length, 0, `stiller Fall hat gewarnt: ${warnings.join("|")}`);
  }
  assertEquals(parsed("3600"), 3600, "gueltiger Wert");
  assertEquals(warnings.length, 0, `gueltiger Wert hat gewarnt: ${warnings.join("|")}`);
  assertEquals(parsed("86400", EDGE_RATE_LIMIT_MAX_WINDOW_SECONDS), 86400, "gueltig mit weiterem max");
  assertEquals(warnings.length, 0, `gueltiger Wert hat gewarnt: ${warnings.join("|")}`);
});

// ---------------------------------------------------------------------------
// E2 (Review 2026-08-31), CWE-532: der verworfene Wert darf NICHT im Klartext
// in die Logzeile. Der Zweig feuert bei jedem Kaltstart aller drei Functions
// und genau dann, wenn in einem Zahlen-Slot keine Zahl steht — also im Fall
// des vertippten oder verrutschten Secrets.
// ---------------------------------------------------------------------------

/** JWT-Attrappe, zur Laufzeit zusammengesetzt: ein Literal mit den Punkten
 *  drin faellt in die gitleaks-JWT-Regel, und die prueft die HISTORIE. */
const FAKE_JWT = [
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
  "eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UifQ",
  "c2lnbmF0dXItYXR0cmFwcGU",
].join(".");

Deno.test("E2: ein in einen Zahlen-Slot gerutschtes Secret steht nicht im Log", () => {
  // `supabase secrets set ANALYZE_MEAL_USER_LIMIT=<service-role JWT>` durch
  // eine verrutschte Zeile: die alte Zeile schrieb 32 Zeichen davon — Header
  // plus Anfang der Nutzlast — bei JEDEM Isolate-Start in function_logs.
  assertEquals(parsed(FAKE_JWT), FALLBACK, "unbrauchbarer Wert faellt auf den Default");
  const joined = warnings.join("\n");
  assertEquals(warnings.length, 1, `genau eine Warnung erwartet: ${joined}`);
  assert(!joined.includes(FAKE_JWT), `der Rohwert steht im Log: ${joined}`);
  assert(!joined.includes(FAKE_JWT.slice(0, 32)), `die alten 32 Zeichen stehen im Log: ${joined}`);
  assert(!joined.includes(FAKE_JWT.slice(0, 12)), `ein Praefix steht im Log: ${joined}`);
  // Kein Fenster von 12 Zeichen aus dem Wert darf auftauchen — auch nicht aus
  // der Mitte, falls jemand statt slice(0, n) irgendwann anders kuerzt.
  for (let i = 0; i + 12 <= FAKE_JWT.length; i++) {
    assert(
      !joined.includes(FAKE_JWT.slice(i, i + 12)),
      `ein Fragment ab Position ${i} steht im Log: ${joined}`,
    );
  }
});

Deno.test("E2: der diagnostische Wert bleibt vollstaendig erhalten", () => {
  assertEquals(parsed(FAKE_JWT), FALLBACK, "Default greift");
  const joined = warnings.join("\n");
  // Was der Betreiber braucht: WELCHE Variable, WARUM verworfen, was
  // stattdessen gilt, und wie gross der Wert war.
  assert(joined.includes(VAR), `Variablenname fehlt: ${joined}`);
  assert(joined.includes("not a plain integer"), `Grund fehlt: ${joined}`);
  assert(joined.includes(String(FAKE_JWT.length)), `Laenge fehlt: ${joined}`);
  assert(joined.includes(String(FALLBACK)), `wirksamer Default fehlt: ${joined}`);
  assert(joined.includes(String(EDGE_RATE_LIMIT_MAX_LIMIT)), `Grenze fehlt: ${joined}`);
});

Deno.test("E2: der Fingerabdruck ist stabil und unterscheidet Werte", () => {
  // Dafuer ist er da: der Betreiber sieht nach dem Nachziehen des Secrets, ob
  // wirklich ein ANDERER Wert ankommt — ohne dass der Wert selbst im Log steht.
  function fingerabdruck(value: string): string {
    parsed(value);
    const match = warnings.join("\n").match(/"valueFingerprint":"([0-9a-f]{8})"/);
    assert(match !== null, `kein Fingerabdruck in: ${warnings.join("\n")}`);
    return match![1];
  }
  const ersterLauf = fingerabdruck(FAKE_JWT);
  assertEquals(fingerabdruck(FAKE_JWT), ersterLauf, "gleicher Wert, gleicher Abdruck");
  assert(fingerabdruck(`${FAKE_JWT}x`) !== ersterLauf, "anderer Wert, anderer Abdruck");
  assert(fingerabdruck("abc") !== fingerabdruck("abd"), "kleine Aenderung faellt auf");
});

Deno.test("E2: auch eine reine Zahl ueber der Grenze wird nicht ausgeschrieben", () => {
  // Die Grenzziehung ist bewusst nicht "nur Nicht-Zahlen schwaerzen": eine
  // Regel mit Ausnahme ist eine Regel, die beim naechsten Umbau kippt. Name,
  // Grund, Grenze und Default reichen dem Betreiber auch hier.
  assertEquals(parsed("999999999"), FALLBACK, "offensichtlicher Unsinn");
  const joined = warnings.join("\n");
  assert(!joined.includes("999999999"), `der Rohwert steht im Log: ${joined}`);
  assert(joined.includes("out of range"), `Grund fehlt: ${joined}`);
  assert(joined.includes('"valueLength":9'), `Laenge fehlt: ${joined}`);
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
