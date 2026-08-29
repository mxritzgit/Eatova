// The request budget is one half of a contract with the Flutter client. The
// other half lives in lib/src/services/eatova_http.dart
// (HttpTimeoutPolicy.mealAnalysis) and is pinned from the Dart side by
// test/services/eatova_http_test.dart, which reads the DEFAULT out of
// handler.ts. This file guards the other number in the same call: the env
// ceiling. Without it an operator could raise the budget past what the client
// waits for, and no test in either language would notice — the function would
// keep working on a request nobody is listening to, while the caller sees a
// timeout and the provider slot stays spent.

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

const handlerQuelle = await Deno.readTextFile(
  new URL('./handler.ts', import.meta.url),
);

/** Beide Zahlen aus `positiveIntFromEnv(<name>, <standard>, <obergrenze>)`. */
function budgetAufruf(): { standard: number; obergrenze: number | null } {
  const treffer = handlerQuelle.match(
    /REQUEST_BUDGET_MS\s*=\s*positiveIntFromEnv\(\s*['"]ANALYZE_MEAL_REQUEST_BUDGET_MS['"]\s*,\s*([\d_]+)\s*(?:,\s*([\d_]+)\s*)?,?\s*\)/,
  );
  assert(
    treffer !== null,
    'ANALYZE_MEAL_REQUEST_BUDGET_MS wird in handler.ts nicht mehr ueber ' +
      'positiveIntFromEnv gelesen. Der Waechter findet die Zahlen nicht mehr — ' +
      'er ist damit blind, nicht zufrieden.',
  );
  const zahl = (s: string) => Number.parseInt(s.replaceAll('_', ''), 10);
  return {
    standard: zahl(treffer![1]),
    obergrenze: treffer![2] === undefined ? null : zahl(treffer![2]),
  };
}

Deno.test('das Budget laesst sich nicht ueber die Client-Toleranz heben', () => {
  const { standard, obergrenze } = budgetAufruf();
  assert(
    obergrenze !== null,
    'Der dritte Parameter fehlt. Ohne Obergrenze gilt der Vorgabewert aus ' +
      'env.ts (EDGE_RATE_LIMIT_MAX_LIMIT), und der hat mit der Wartezeit des ' +
      'Clients nichts zu tun.',
  );
  assertEquals(
    obergrenze,
    standard,
    'Die Obergrenze liegt ueber dem Standard. Damit kann ein Betreiber per ' +
      'Umgebungsvariable ein Budget setzen, auf das der Client gar nicht mehr ' +
      'wartet: HttpTimeoutPolicy.mealAnalysis gibt nach 75 s auf, davon gehen ' +
      '15 s Verbindungsaufbau und 5 s Antwort-Transfer ab. Die Function ' +
      'arbeitet dann an einer Anfrage weiter, der niemand mehr zuhoert, der ' +
      'Nutzer sieht eine Zeitueberschreitung UND der Provider-Slot ist ' +
      'verbraucht. Kuerzen bleibt erlaubt (jeder Wert unter dem Standard ' +
      'greift) — verlaengern muss ueber den Client gehen',
  );
});

Deno.test('der Standard passt zu dem, was der Client uebrig laesst', () => {
  const { standard } = budgetAufruf();
  // 75 s Gesamtfrist - 15 s connect - 5 s Antwort-Transfer. Die Zahlen stehen
  // in eatova_http.dart; die Dart-Seite prueft die Beziehung gegen genau den
  // hier gelesenen Standard. Diese Zusicherung faengt nur ein grobes
  // Abrutschen, damit ein Tippfehler nicht erst in der Dart-Suite auffaellt.
  assertEquals(
    standard,
    55_000,
    'Der Standard ist nicht mehr 55 s. Das ist erlaubt — aber dann muss ' +
      'HttpTimeoutPolicy.mealAnalysis.total in lib/src/services/eatova_http.dart ' +
      'mitwandern (total >= 15 s + Budget + 5 s), sonst schneidet der Client ' +
      'eine noch laufende Analyse ab. test/services/eatova_http_test.dart liest ' +
      'diesen Wert und wird rot, wenn nur eine Seite bewegt wurde',
  );
});
