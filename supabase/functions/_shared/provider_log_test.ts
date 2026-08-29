// Tests for the finish_reason allowlist (provider_log.ts).
//
// P6-04c (review 2026-08-29): the rule used to exist twice — as an allowlist
// in analyze-meal/normalize.ts and as a 32-character cap in
// coach-chat/handler.ts. The cap is what this file rules out: 32
// provider-chosen characters are still provider-chosen characters, and
// `finish_reason` is a free string that the model can fill with anything it
// read in the photo or the user hint (CWE-532).
//
// Deliberately without external test dependencies, same style as the other
// files here; the module is pure, so no environment is needed.

import { loggableFinishReason } from "./provider_log.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

Deno.test("P6-04b: Vertragswerte bleiben lesbar", () => {
  for (const value of ["stop", "length", "content_filter", "tool_calls", "function_call", "error"]) {
    assertEquals(loggableFinishReason(value), value, `Vertragswert ${value}`);
  }
});

Deno.test("P6-04b: fehlender Wert bleibt fehlend, statt 'other' zu erfinden", () => {
  assertEquals(loggableFinishReason(undefined), undefined, "undefined");
  assertEquals(loggableFinishReason(null), undefined, "null");
});

Deno.test("P6-04b: alles andere wird zur Kategorie verdichtet, nie zitiert", () => {
  assertEquals(loggableFinishReason("Nutzerhinweis: Diabetes"), "other", "Fremdtext -> Kategorie");
  assertEquals(loggableFinishReason({ text: "Diabetes" }), "other", "Fremdform -> Kategorie");
  assertEquals(loggableFinishReason(7), "other", "Zahl -> Kategorie");
  assertEquals(loggableFinishReason("STOP"), "other", "Gross-/Kleinschreibung zaehlt");
  assertEquals(loggableFinishReason("stop "), "other", "kein Trimmen, kein Praefix-Match");
});

// P6-04c: the point of the allowlist against the old cap. A truncation keeps
// the first n characters the provider chose; the first 32 characters of a
// user's hint are still the user's hint.
Deno.test("P6-04c: Kappen ist kein Ersatz — kein Praefix des Fremdtexts ueberlebt", () => {
  const leak = "Nutzerhinweis Diabetes Typ 2 seit 2019, Metformin";
  const logged = loggableFinishReason(leak);
  assertEquals(logged, "other", "Kategorie statt Inhalt");
  assert(
    !leak.slice(0, 32).includes(String(logged)),
    `ein Praefix des Fremdtexts steht im Log: ${String(logged)}`,
  );
  // The value must not grow with the input either — a length-carrying
  // category would still be a side channel on the hint.
  assertEquals(loggableFinishReason(leak + leak), "other", "Laenge faerbt nicht ab");
});
