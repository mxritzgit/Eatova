// Gemeinsame, defensive Env-Parser fuer alle Edge Functions.
//
// Warum das ein eigenes Modul ist: ein falsch gesetztes Function-Secret darf
// nie zu einem Totalausfall fuehren. `Number(Deno.env.get('X') ?? '20')`
// liefert fuer einen nicht-numerischen Wert NaN; NaN wird von JSON.stringify
// zu `null` serialisiert, die RPC consume_edge_rate_limit bekommt dann
// p_limit = null, der SQL-Guard wirft, PostgREST antwortet 500 und JEDER
// Request der Function scheitert mit `rate_limit_unavailable`. Ein Tippfehler
// im Secret legt damit die komplette Function lahm.
//
// Deshalb: nicht gesetzt / leer / kein reines Integer / <= 0 / kein sicherer
// Integer -> Fallback auf den Code-Default.
//
// Das `_`-Prefix des Verzeichnisses haelt die Supabase-CLI davon ab, _shared
// als eigene deploybare Function zu behandeln; relative Imports werden beim
// Deploy mitgebundelt.

/** Liest `name` aus der Environment und gibt nur eine positive Ganzzahl zurueck. */
export function positiveIntFromEnv(name: string, fallback: number): number {
  const raw = Deno.env.get(name)?.trim();
  if (!raw || !/^\d+$/.test(raw)) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
