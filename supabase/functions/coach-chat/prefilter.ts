// Layer 1 - deterministischer Pre-Filter fuer coach-chat.
//
// Designprinzip: Layer 1 ist NUR ein Kosten-Sparfilter fuer eindeutige
// Faelle und muss lieber zu lasch als zu scharf sein. Der eigentliche
// Schutz ist Layer 2 (LLM-Klassifizierer in index.ts), der u.a. self_harm,
// eating_disorder und medical_risk nach INTENT einstuft und alles faengt,
// was hier durchrutscht. Ein False-Positive hier trifft dagegen die
// Kernzielgruppe ("Cutting" ist im Fitness-Kontext die Definitionsphase!)
// und laesst sich nicht per Kontext korrigieren - der User bekommt ohne
// LLM-Call eine Refusal-Antwort auf eine legitime Frage.
//
// Deshalb: mehrdeutige Begriffe (cutting, ritzen, "Fasten X Tage",
// "act as", ...) nur mit eindeutigem Selbst-/Injection-Kontext matchen -
// oder gar nicht (dann entscheidet Layer 2).

export const MAX_INPUT_CHARS = 1000;

// Banned-Terms decken die Hauptmissbrauchsfaelle ab: Performance-Enhancing
// Drugs, ED-Gefahren, illegale Substanzen, Selbstverletzung,
// Hausaufgaben-/Coding-Hijack, Prompt-Injection.
//
// Bei Treffer wird die Anfrage gar nicht erst an die LLMs geschickt.
export const BANNED_PATTERNS: { pattern: RegExp; reason: string }[] = [
  // Performance Enhancing / Doping (Stems + freie Endung, weil "Anabolika"
  // gerne flektiert daherkommt).
  { pattern: /\b(steroid\w*|anabolik\w*|anabolic\w*|trenbolon\w*|sustanon|testo(steron)?\s*kur|testo\s*shot|dianabol|d-?bol|winstrol|deca\s*durabolin|sarms?|ostarin\w*|clenbuterol|ephedrin\w*|epo\b|wachstumshormon\w*|\bhgh\b|insulin\s*kur|peptid\s*kur)\b/i, reason: "doping" },
  // Crash-Diaeten / Essstoerung-Risiko.
  // "fasten \d+ tag" wurde bewusst ENTFERNT: "Fasten 3 Tage" ist eine
  // legitime Ernaehrungsfrage (Intervall-/Heilfasten). Ob eine Fasten-Frage
  // ED-adjacent ist, entscheidet Layer 2 per Intent (Kategorie
  // eating_disorder), nicht eine Zahl im Satz.
  { pattern: /\b(pro\s*ana|thinspo|magers(u|ü)cht\w*|ess.?st(o|ö)rung\w*|bulim\w*|laxativ\w*\s*missbrauch|abf(u|ü)hrmittel\w*\s*missbrauch|brechen\s*nach\s*essen)\b/i, reason: "eating_disorder" },
  // Illegale Drogen
  { pattern: /\b(kokain|heroin|crystal\s*meth|methamphetamin|amphetamin|ecstasy|mdma|lsd|cannabis\s*kaufen|gras\s*kaufen)\b/i, reason: "illegal_drugs" },
  // Selbstverletzung - NUR eindeutige Formulierungen:
  //  - "cutting" standalone ist im Fitness-Kontext die Diaetphase
  //    ("Wie viel Protein beim Cutting?") -> nur mit Selbstbezug
  //    ("cutting myself", "self-harm/self-cutting").
  //  - "ritzen" standalone ist u.a. Backhandwerk ("Brot ritzen") -> nur mit
  //    Reflexivpronomen ("mich/sich ritzen", "ritze mich", "mich geritzt").
  //  - "suizid" als Stamm (\w*), damit "Suizidgedanken" mitgefangen wird.
  // Mehrdeutige Formulierungen faengt Layer 2 (Kategorie self_harm) und
  // liefert dieselbe Krisen-Antwort mit der Telefonseelsorge-Nummer.
  { pattern: /\b(suizid\w*|selbstmord|mich\s*umbringen|sterben\s*wollen|kill\s*myself|cutting\s+myself|self[\s-]?(harm\w*|cutting)|selbstverletz\w*|(mich|mir|sich)\s+(\w+\s+){0,2}(zu\s+)?(ge)?ritz(en|t)|ritze\s+mich)\b/i, reason: "self_harm" },
  // Klassische Hausaufgaben/Coding-Hijack ("oe" als ASCII-Variante fuer "ö").
  // Standalone "hausaufgab\w*" wurde entfernt: das Wort taucht auch in
  // legitimen Kontext-Saetzen auf ("wenig Zeit wegen Hausaufgaben - wie kurz
  // kann mein Workout sein?"). Die verb-gebundenen Formen ("loese meine
  // Hausaufgabe", "schreib mir eine Hausarbeit") bleiben; den Rest stuft
  // Layer 2 als off_topic ein.
  { pattern: /\b(l(oe|o|ö)se\s*(diese|meine|mir)?\s*(gleichung|aufgabe|haus(aufgabe)?|integral|matheaufgabe)|essay\s*schreiben|aufsatz\s*schreiben|schreib\s*mir\s*(eine?n?)?\s*(code|programm|skript|essay|hausarbeit|bewerbung|email|brief)|programmier\s*mir)\b/i, reason: "off_topic_homework" },
  // Prompt-Injection Versuche.
  // "act as|act like" wurde entfernt: normale englische Ernaehrungsfragen
  // ("can a shake act as a meal replacement?") wuerden sonst als Injection
  // geblockt; echte Roleplay-Injections faengt Layer 2 (Kategorie injection).
  // "du bist jetzt" bleibt (klassischer deutscher Roleplay-Prefix), aber mit
  // Ausnahme fuer die harmlose Coach-Anrede "du bist jetzt mein (…)coach".
  { pattern: /\b(ignor(e|iere)\s*(all|alle|deine|previous|vorher|the)\s*(instruction|anweisung|prompt|rule)|system\s*prompt|du\s*bist\s*jetzt(?!\s+mein\s+\S*coach\b)|jailbreak|dan\s*mode|developer\s*mode|reveal\s*(your|the)\s*prompt|zeig\s*(mir|uns)?\s*(deinen|den)\s*system)/i, reason: "prompt_injection" },
];

export function preFilter(
  message: string,
  hasImage = false,
): { ok: true } | { ok: false; reason: string } {
  if (!hasImage && (!message || message.trim().length === 0)) {
    return { ok: false, reason: "empty" };
  }
  if (message.length > MAX_INPUT_CHARS) {
    return { ok: false, reason: "too_long" };
  }
  for (const { pattern, reason } of BANNED_PATTERNS) {
    if (pattern.test(message)) return { ok: false, reason };
  }
  return { ok: true };
}
