// Tests for clipUtf16 (text_clip.ts), free of external test dependencies.

import { clipUtf16 } from "./text_clip.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

Deno.test("clipUtf16 kappt nie zwischen den Haelften eines Emojis", () => {
  assertEquals(clipUtf16("ab😀", 3), "ab", "halbes Emoji faellt weg");
  assertEquals(clipUtf16("ab😀", 4), "ab😀", "ganzes Emoji bleibt");
  assertEquals(clipUtf16("ab😀c", 10), "ab😀c", "kuerzerer Text bleibt unveraendert");
  assertEquals(clipUtf16("abc", 2), "ab", "einfacher Text wird wie mit slice gekappt");
  assertEquals(clipUtf16("😀", 1), "", "nur ein halbes Emoji ergibt einen leeren Text");
  assertEquals(clipUtf16("", 5), "", "leerer Text");
});

Deno.test("clipUtf16 liefert fuer jede Grenze wohlgeformten Text innerhalb des Limits", () => {
  const text = "x🍝y💪z👩‍🍳";
  for (let max = 0; max <= text.length + 1; max++) {
    const cut = clipUtf16(text, max);
    assert(cut.isWellFormed(), `max ${max}: halbes Emoji`);
    assert(cut.length <= max, `max ${max}: Limit ueberschritten (${cut.length})`);
    assert(text.startsWith(cut), `max ${max}: kein Praefix`);
    assert(cut.length >= Math.min(max, text.length) - 1, `max ${max}: mehr als eine Einheit verloren`);
  }
});
