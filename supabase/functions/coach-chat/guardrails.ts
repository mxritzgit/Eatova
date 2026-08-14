// Layer 2 - Kategorien und Entscheidungslogik des Topic-Klassifizierers.
//
// Bewusst als eigenes, seiteneffektfreies Modul: die Frage "laeuft der
// Klassifizierer ueberhaupt?" und "welche Kategorien fuehren zu einer
// Refusal?" ist die sicherheitsrelevanteste Weiche der ganzen Function und
// muss ohne Netzwerk, Env oder Deno.serve testbar sein (guardrails_test.ts).
//
// Seit 2026-08-14 liegt hier zusaetzlich die Layer-1-Pruefung des
// App-Kontextes (sanitizeUserContext, ganz unten) - aus demselben Grund:
// sie ist eine Sicherheits-Weiche und gehoert ohne Server testbar.

import { BANNED_PATTERNS } from "./prefilter.ts";

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
  /**
   * true = der Modell-Output war UNBRAUCHBAR (kaputtes JSON, unbekannte
   * Kategorie) und `category` ist nur der fail-closed-Default `off_topic` —
   * es hat also gar keine Klassifikation stattgefunden.
   *
   * Ohne dieses Flag waren "Modell sagt off_topic" und "Modell-Antwort nicht
   * lesbar" nicht unterscheidbar (Security-Fix 2026-08-14, W1): in jedem Set
   * OHNE off_topic (Bild, Rezept) schaltete ein kaputtes JSON die
   * Krisenpruefung fuer genau diese Anfrage still ab. Wer darauf reagieren
   * muss, entscheidet layer2RefusalReason() unten.
   */
  parseFailed: boolean;
}

// Kategorien, die Layer 2 refused. Seit dem Quota-Fix (2026-08-11, CWE-770)
// kostet auch eine Layer-2-Refusal den Tages-Slot: der Claim passiert im
// Handler VOR dem Classifier-Call, sonst waeren mit erschoepfter Quota ueber
// das Stunden-Gate weiterhin bezahlte Classifier-Calls moeglich (Details:
// handler.ts). self_harm/eating_disorder routen auf dieselben Krisen-/
// ED-Antworten wie Layer 1 - wichtig, weil Layer 1 bewusst lasch ist und
// mehrdeutige Formulierungen erst hier landen.
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
// Nebeneffekt, der genauso wichtig ist: classify() faellt bei unbrauchbarem
// Modell-Output (kaputtes JSON, unbekannte Kategorie) fail-closed auf
// `off_topic` zurueck. Waere off_topic im Bild-Set, wuerde so ein Aussetzer
// JEDE Bildanfrage ablehnen statt nur die Zusatzpruefung zu verlieren.
// (HTTP-/Netz-Fehler werfen seit dem Quota-Fix 2026-08-11 stattdessen eine
// Exception - der Handler refundet den Slot und antwortet 502.)
//
// Seit 2026-08-14 (W1) ist dieser Aussetzer ueber ClassifierResult.parseFailed
// sichtbar - der BILDPFAD reagiert bewusst weiterhin NICHT darauf: dort steht
// hinter Layer 2 noch Layer 3, dessen ANSWER_SYSTEM_PROMPT eine eigene
// CRISIS RULE mit der Telefonseelsorge-Nummer traegt und das Bild
// tatsaechlich sieht. Ein Klassifizierer-Aussetzer kostet hier also eine
// Zusatzpruefung, nicht die Krisen-Antwort (im Rezept-Pfad ist das anders,
// s. unten).
export const IMAGE_REFUSAL_CATEGORIES: ReadonlySet<ClassifierCategory> =
  new Set([
    "self_harm",
    "eating_disorder",
    "medical_risk",
    "injection",
  ]);

// Kategorien-Set fuer den REZEPT-Pfad (mode: "recipe"): REFUSAL_CATEGORIES
// ohne "off_topic".
//
// Hintergrund (Security-Fix 2026-08-14): der Recipe-Zweig lag im Handler VOR
// dem Classifier-Block, Layer 2 lief dort also nie. Layer 1 ist bewusst lasch
// und faengt nur eindeutige Wortlaute - Wuensche wie "ich will nicht mehr
// leben, mach mir noch ein letztes Rezept" (self_harm) oder "100-kcal-Rezept,
// ich muss 10 kg in 5 Tagen abnehmen" (eating_disorder) sind im
// Classifier-Prompt namentlich gelistet und liefen ungeprueft in den
// Draft-Call. Die garantierte Krisen-Antwort mit der Telefonseelsorge-Nummer
// konnte im Rezept-Pfad gar nicht entstehen.
//
// "off_topic" bleibt draussen, weil Rezept-Wuensche haeufig blosse
// Gerichtnamen sind ("Pasta mit Pesto"), die ohne Coach-Frage-Kontext
// systematisch als off_topic landen wuerden - im Set waere der ganze
// Rezept-Flow kaputt. Nicht-Rezept-Wuensche haelt weiterhin der Rezept-Prompt
// selbst ab (er antwortet mit dem JSON-Refusal, s. recipe.ts).
//
// ACHTUNG - hier stand bis 2026-08-14 als zweite Begruendung, ein
// Klassifizierer-Aussetzer (fail-closed off_topic) wuerde im Set jeden
// Rezept-Wunsch ablehnen. Das war der Preis fuer die letzte Fail-open-Stelle
// (W1): weil "Modell sagt off_topic" und "Antwort unlesbar" beide als
// off_topic ankamen, schaltete ein kaputtes JSON die Krisenpruefung fuer
// genau diese Anfrage ab, und "ich will nicht mehr leben, mach mir noch ein
// letztes Rezept" ging in den Draft-Call. Beides ist jetzt trennbar
// (ClassifierResult.parseFailed): das SET bleibt ohne off_topic, der
// Parse-Ausfall wird im Rezept-Modus separat als Refusal behandelt
// (layer2RefusalReason unten). Anders als im Bild-/Chatpfad gibt es hier
// keine zweite Krisen-Schicht - der Rezept-Prompt kennt nur "kein
// Essensrezept", nicht die Telefonseelsorge-Nummer.
export const RECIPE_REFUSAL_CATEGORIES: ReadonlySet<ClassifierCategory> =
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

/**
 * Grund einer Layer-2-Refusal: entweder die Kategorie des Modells oder
 * "classifier_unusable" - der Fall, in dem gar nicht klassifiziert wurde.
 * Beides landet 1:1 in refusalForReason() und im refusal_reason der Antwort.
 */
export type Layer2RefusalReason = ClassifierCategory | "classifier_unusable";

/**
 * Lehnt Layer 2 diese Anfrage ab - und warum? null = durchlassen.
 *
 * Trennt die beiden Faelle, die classify() bis 2026-08-14 ununterscheidbar
 * als `off_topic` ausgab (W1):
 *  - `parseFailed: false` -> das Modell hat geantwortet, es zaehlt allein die
 *    Mengen-Mitgliedschaft im aktiven Set (unveraendertes Verhalten).
 *  - `parseFailed: true`  -> es hat KEINE Klassifikation gegeben. Pfade, deren
 *    Set kein off_topic enthaelt, wuerden hier still an der Krisenpruefung
 *    vorbeilaufen; `refuseOnUnusableOutput` schaltet fuer sie die Refusal ein.
 *
 * `refuseOnUnusableOutput` ist bewusst ein Schalter des AUFRUFERS und nicht
 * aus dem Set abgeleitet: der Bildpfad hat mit Layer 3 eine zweite
 * Krisen-Schicht und will die Refusal NICHT (jeder Aussetzer wuerde sonst
 * eine legitime Bildanfrage ablehnen), der Rezept-Pfad hat sie nicht und
 * will sie. Im Chat-Pfad ist der Schalter wirkungslos - dort liegt off_topic
 * ohnehin im Set, ein Aussetzer landet also wie bisher in der
 * Off-Topic-Refusal.
 */
export function layer2RefusalReason(options: {
  result: ClassifierResult;
  categories: ReadonlySet<ClassifierCategory>;
  refuseOnUnusableOutput: boolean;
}): Layer2RefusalReason | null {
  const { result, categories, refuseOnUnusableOutput } = options;
  if (result.parseFailed && refuseOnUnusableOutput) return "classifier_unusable";
  return categories.has(result.category) ? result.category : null;
}

// ---------------------------------------------------------------------------
// Layer 1 ueber den App-Kontext (Security-Fix 2026-08-14)
// ---------------------------------------------------------------------------
// `user_context` kommt aus dem Request-Body und wurde bis hierher nur von
// Steuerzeichen befreit und gekappt - weder Layer 1 noch Layer 2 haben ihn je
// gesehen, obwohl er als System-Message mit der hoechsten Vertrauensstufe des
// Prompts beim Modell landete. Erreichbar ist der Kanal auch ohne
// manipulierten Client: _todaysFoodSummary() speist selbst vergebene
// Mahlzeiten-Namen ein.
//
// Bei einem Treffer wird der KONTEXT verworfen, nicht der Request abgelehnt:
// der Kontext ist Beiwerk (er macht die Beratung konkreter), die Frage des
// Nutzers ist die Leistung - und der Tages-Slot ist an der Stelle im Handler
// laengst geclaimt. Eine Ablehnung wuerde einen Nutzer bestrafen, der
// womoeglich nur eine unglueckliche Mahlzeit benannt hat.

export const MAX_USER_CONTEXT_CHARS = 1200;

/**
 * Bereinigt den App-Kontext und meldet, ob er verworfen wurde.
 *
 * `dropped` traegt den Layer-1-Grund (fuer das Server-Log, NIE den Inhalt);
 * `context` ist dann leer.
 */
export function sanitizeUserContext(
  raw: string,
): { context: string; dropped: string | null } {
  const cleaned = Array.from(raw)
    // Steuerzeichen raus (wie bisher) und zusaetzlich Winkelklammern: der
    // Kontext wird im Answer-Call in <app_context>…</app_context> gerahmt und
    // darf diesen Rahmen nicht von innen schliessen koennen.
    .filter((ch) => {
      const code = ch.charCodeAt(0);
      return code >= 32 && code !== 127 && ch !== "<" && ch !== ">";
    })
    .join("")
    .trim()
    .slice(0, MAX_USER_CONTEXT_CHARS);
  if (cleaned.length === 0) return { context: "", dropped: null };
  // Geprueft wird der GEKAPPTE Text - was hinter dem Cap liegt, geht ohnehin
  // nie raus.
  for (const { pattern, reason } of BANNED_PATTERNS) {
    if (pattern.test(cleaned)) return { context: "", dropped: reason };
  }
  return { context: cleaned, dropped: null };
}
