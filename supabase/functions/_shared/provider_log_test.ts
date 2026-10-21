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

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

Deno.test("P6-04b: Vertragswerte bleiben lesbar, ein fehlender Wert bleibt fehlend", () => {
  for (const value of ["stop", "length", "content_filter", "tool_calls", "function_call", "error"]) {
    assertEquals(loggableFinishReason(value), value, `Vertragswert ${value}`);
  }
  // Missing stays missing instead of inventing 'other'.
  assertEquals(loggableFinishReason(undefined), undefined, "undefined");
  assertEquals(loggableFinishReason(null), undefined, "null");
});

// P6-04c: the point of the allowlist against the old 32-character cap: a
// truncation keeps the first n characters the provider chose.
Deno.test("P6-04b: alles andere wird zur Kategorie verdichtet, nie zitiert oder gekappt", () => {
  const leak = "Nutzerhinweis Diabetes Typ 2 seit 2019, Metformin";
  assertEquals(loggableFinishReason(leak), "other", "Fremdtext -> Kategorie");
  assertEquals(loggableFinishReason({ text: "Diabetes" }), "other", "Fremdform -> Kategorie");
  assertEquals(loggableFinishReason(7), "other", "Zahl -> Kategorie");
  assertEquals(loggableFinishReason("STOP"), "other", "Gross-/Kleinschreibung zaehlt");
  assertEquals(loggableFinishReason("stop "), "other", "kein Trimmen, kein Praefix-Match");
});
