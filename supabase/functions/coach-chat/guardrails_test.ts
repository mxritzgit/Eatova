// Tests fuer die Layer-2-Weichen (guardrails.ts).
//
// Der wichtigste Test hier ist der Regressionstest: bis 2026-08-07 war der
// komplette Layer-2-Block in index.ts in ein `if (!hasImage)` gewickelt.
// "irgendein Bild + Text" hat den Klassifizierer damit uebersprungen und
// genau self_harm/eating_disorder ausgehebelt - die beiden Kategorien, an
// denen die Krisen-Antwort mit der Telefonseelsorge-Nummer haengt.
//
// Bewusst ohne externe Test-Dependencies (gleicher Stil wie prefilter_test.ts).

import {
  type ClassifierCategory,
  IMAGE_REFUSAL_CATEGORIES,
  REFUSAL_CATEGORIES,
  refusalCategoriesFor,
  shouldRunClassifier,
} from "./guardrails.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

Deno.test("Regression: der Klassifizierer laeuft unabhaengig von hasImage", () => {
  // Kern der Regression: ein Bild darf Layer 2 NICHT abschalten. Die Weiche
  // haengt allein am Text.
  assert(
    shouldRunClassifier("ich will nicht mehr aufwachen"),
    "Text mit Bild muss klassifiziert werden",
  );
  assert(
    shouldRunClassifier("Wie viel Protein brauche ich?"),
    "Text ohne Bild muss klassifiziert werden",
  );
  // ... und die aktiven Kategorien haengen zwar am Bild, aber nie so, dass
  // eine Sicherheits-Kategorie verschwindet (siehe Test unten).
  for (const hasImage of [true, false]) {
    const active = refusalCategoriesFor(hasImage);
    assert(
      active.has("self_harm") && active.has("eating_disorder"),
      `self_harm/eating_disorder fehlen bei hasImage=${hasImage}`,
    );
  }
});

Deno.test("Klassifizierer wird NUR bei leerem/whitespace-Text uebersprungen", () => {
  assert(!shouldRunClassifier(""), "leerer Text darf nicht klassifiziert werden");
  assert(!shouldRunClassifier("   "), "Whitespace darf nicht klassifiziert werden");
  assert(!shouldRunClassifier("\n\t  \r\n"), "Whitespace darf nicht klassifiziert werden");
  assert(shouldRunClassifier("hi"), "kurzer Text muss klassifiziert werden");
  assert(shouldRunClassifier("  hi  "), "getrimmter Text muss klassifiziert werden");
});

Deno.test("Bildpfad refused alle vier Sicherheits-Kategorien", () => {
  const active = refusalCategoriesFor(true);
  for (const category of ["self_harm", "eating_disorder", "medical_risk", "injection"] as const) {
    assert(active.has(category), `Bildpfad muss "${category}" ablehnen`);
  }
  assert(active.size === 4, `Bildpfad-Set hat ${active.size} statt 4 Kategorien`);
});

Deno.test("Bildpfad schliesst off_topic aus (Layer 3 entscheidet ueber Bilder)", () => {
  const active = refusalCategoriesFor(true);
  assert(
    !active.has("off_topic"),
    "off_topic im Bildpfad wuerde jede deiktische Caption ('was ist das?') " +
      "und bei einem Klassifizierer-Ausfall (fail-closed -> off_topic) sogar " +
      "jede Bildanfrage ablehnen",
  );
  assert(active === IMAGE_REFUSAL_CATEGORIES, "hasImage=true muss das Bild-Set liefern");
});

Deno.test("Textpfad unveraendert: alle fuenf Kategorien", () => {
  const active = refusalCategoriesFor(false);
  for (
    const category of [
      "self_harm",
      "eating_disorder",
      "medical_risk",
      "off_topic",
      "injection",
    ] as const
  ) {
    assert(active.has(category), `Textpfad muss "${category}" ablehnen`);
  }
  assert(active.size === 5, `Textpfad-Set hat ${active.size} statt 5 Kategorien`);
  assert(active === REFUSAL_CATEGORIES, "hasImage=false muss das Text-Set liefern");
});

Deno.test("Bild-Set ist echte Teilmenge des Text-Sets", () => {
  // Schuetzt gegen eine spaeter nur EINEM Set hinzugefuegte Kategorie: eine
  // neue Sicherheits-Kategorie, die nur im Textpfad steht, waere lautlos ein
  // zweiter Bypass wie der 2026-08-07 gefixte.
  for (const category of IMAGE_REFUSAL_CATEGORIES) {
    assert(
      REFUSAL_CATEGORIES.has(category),
      `"${category}" ist im Bild-Set, fehlt aber im Text-Set`,
    );
  }
  assert(
    IMAGE_REFUSAL_CATEGORIES.size < REFUSAL_CATEGORIES.size,
    "Bild-Set muss echte Teilmenge sein (aktuell: Text-Set minus off_topic)",
  );
  const missing: ClassifierCategory[] = [];
  for (const category of REFUSAL_CATEGORIES) {
    if (!IMAGE_REFUSAL_CATEGORIES.has(category)) missing.push(category);
  }
  assert(
    missing.length === 1 && missing[0] === "off_topic",
    `Nur off_topic darf im Bildpfad fehlen, tatsaechlich fehlt: ${missing.join(", ")}`,
  );
});

Deno.test("Sets sind nicht dieselbe Instanz (kein versehentliches Aliasing)", () => {
  assert(
    IMAGE_REFUSAL_CATEGORIES !== REFUSAL_CATEGORIES,
    "beide Sets zeigen auf dieselbe Instanz - eine Aenderung wuerde beide Pfade treffen",
  );
});
