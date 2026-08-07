// Layer 2 - Kategorien und Entscheidungslogik des Topic-Klassifizierers.
//
// Bewusst als eigenes, seiteneffektfreies Modul: die Frage "laeuft der
// Klassifizierer ueberhaupt?" und "welche Kategorien fuehren zu einer
// Refusal?" ist die sicherheitsrelevanteste Weiche der ganzen Function und
// muss ohne Netzwerk, Env oder Deno.serve testbar sein (guardrails_test.ts).

export const CLASSIFIER_CATEGORIES = [
  "fitness",
  "nutrition",
  "smalltalk",
  "self_harm",
  "eating_disorder",
  "medical_risk",
  "off_topic",
  "injection",
] as const;

export type ClassifierCategory = (typeof CLASSIFIER_CATEGORIES)[number];

export interface ClassifierResult {
  category: ClassifierCategory;
  confidence: "low" | "medium" | "high";
}

// Kategorien, die Layer 2 ohne Quota-Abzug refused. self_harm/eating_disorder
// routen dabei auf dieselben Krisen-/ED-Antworten wie Layer 1 - wichtig, weil
// Layer 1 bewusst lasch ist und mehrdeutige Formulierungen erst hier landen.
export const REFUSAL_CATEGORIES: ReadonlySet<ClassifierCategory> = new Set([
  "self_harm",
  "eating_disorder",
  "medical_risk",
  "off_topic",
  "injection",
]);

// Kategorien-Set fuer den BILD-Pfad: REFUSAL_CATEGORIES ohne "off_topic".
//
// Begruendung: der Klassifizierer sieht ausschliesslich den TEXT, nie das
// Bild (classify() schickt `content` als reinen String). Legitime
// Bild-Captions sind aber kurz und deiktisch - "was ist das?", "und das
// hier?", "wie viele kcal?" - und wuerden ohne Bildkontext systematisch als
// off_topic eingestuft. Mit off_topic im Bild-Set waere der komplette
// Vision-Flow kaputt.
//
// Off-TOPIC-BILDER sind stattdessen Aufgabe von Layer 3: der
// ANSWER_SYSTEM_PROMPT weist das Vision-Modell an, bei fitness-fremden oder
// unzulaessigen Bildinhalten mit dem `__REFUSE__`-Marker zu antworten - dort
// liegt das Bild tatsaechlich vor.
//
// Nebeneffekt, der genauso wichtig ist: classify() faellt bei jedem Fehler
// fail-closed auf `off_topic` zurueck. Waere off_topic im Bild-Set, wuerde ein
// Ausfall des Klassifizierer-Modells JEDE Bildanfrage ablehnen statt nur die
// Zusatzpruefung zu verlieren.
export const IMAGE_REFUSAL_CATEGORIES: ReadonlySet<ClassifierCategory> =
  new Set([
    "self_harm",
    "eating_disorder",
    "medical_risk",
    "injection",
  ]);

/**
 * Laeuft Layer 2 fuer diese Anfrage?
 *
 * Einziges Ausschlusskriterium ist leerer Text - NICHT das Vorhandensein
 * eines Bildes. Ein Bild-Upload ohne Begleittext hat schlicht nichts zu
 * klassifizieren; ein blindes classify(key, "") wuerde im fail-closed
 * `off_topic`-Default landen und damit jeden legitimen Bild-Upload ablehnen.
 *
 * Im Textpfad ist die Bedingung immer wahr: Layer 1 lehnt leere Nachrichten
 * ohne Bild bereits als "empty" ab.
 */
export function shouldRunClassifier(message: string): boolean {
  return message.trim().length > 0;
}

/** Aktives Refusal-Set fuer die Anfrage (Bild -> ohne off_topic, siehe oben). */
export function refusalCategoriesFor(
  hasImage: boolean,
): ReadonlySet<ClassifierCategory> {
  return hasImage ? IMAGE_REFUSAL_CATEGORIES : REFUSAL_CATEGORIES;
}
