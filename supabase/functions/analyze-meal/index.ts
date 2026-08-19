// Eatova Foto-Kalorienanalyse Edge Function - Entrypoint.
//
// Bewusst nur die Deno.serve-Verdrahtung: die komplette Request-Logik (Auth,
// die beiden Rate-Limit-Gates, Bild-Pruefung, Provider-Call) liegt in
// handler.ts, damit sie in handler_test.ts end-to-end getestet werden kann,
// ohne einen Server zu starten. Solange `Deno.serve` hier auf Modulebene mit
// der ganzen Logik zusammenstand, war jeder Import gleichbedeutend mit einem
// laufenden Server — deshalb gab es fuer die Fehlerpfade dieser Function
// keinen einzigen Test. Gleiche Aufteilung wie bei coach-chat.
//
//   handler.ts   - handleRequest() + alle HTTP-/Supabase-/Provider-Helfer
//   normalize.ts - Normalisierung der Modell-Antwort (rein, testbar)

import { handleRequest } from './handler.ts';

Deno.serve(handleRequest);
