// Layer 1 - deterministic pre-filter for coach-chat.
//
// Layer 1 is ONLY a cost saver for unambiguous cases and must err on the lax
// side: layer 2 (the LLM classifier in index.ts) judges by INTENT and catches
// what slips through, while a false positive here refuses a legitimate
// question without any LLM call ("cutting" is a fitness diet phase).
//
// Therefore ambiguous terms only match with unambiguous self-harm/injection
// context — or not at all, leaving the decision to layer 2.

export const MAX_INPUT_CHARS = 1000;

// Banned terms cover the main abuse cases: doping, ED risk, illegal drugs,
// self-harm, homework/coding hijack, prompt injection. A hit means the request
// never reaches the LLMs.
export const BANNED_PATTERNS: { pattern: RegExp; reason: string }[] = [
  // Performance enhancing / doping (stems with open endings, because these
  // words are frequently inflected).
  { pattern: /\b(steroid\w*|anabolik\w*|anabolic\w*|trenbolon\w*|sustanon|testo(steron)?\s*kur|testo\s*shot|dianabol|d-?bol|winstrol|deca\s*durabolin|sarms?|ostarin\w*|clenbuterol|ephedrin\w*|epo\b|wachstumshormon\w*|\bhgh\b|insulin\s*kur|peptid\s*kur)\b/i, reason: "doping" },
  // Crash diets / eating-disorder risk. No "fasten \d+ tag" pattern: fasting
  // for N days is a legitimate nutrition question, and whether it is
  // ED-adjacent is layer 2's call by intent, not a number in the sentence.
  { pattern: /\b(pro\s*ana|thinspo|magers(u|ü)cht\w*|ess.?st(o|ö)rung\w*|bulim\w*|laxativ\w*\s*missbrauch|abf(u|ü)hrmittel\w*\s*missbrauch|brechen\s*nach\s*essen)\b/i, reason: "eating_disorder" },
  // Illegal drugs
  { pattern: /\b(kokain|heroin|crystal\s*meth|methamphetamin|amphetamin|ecstasy|mdma|lsd|cannabis\s*kaufen|gras\s*kaufen)\b/i, reason: "illegal_drugs" },
  // Self-harm - ONLY unambiguous phrasings: "cutting" and "ritzen" alone are
  // a diet phase and a baking term, so both need a self-reference or a
  // reflexive pronoun; "suizid" matches as a stem. Ambiguous phrasings go to
  // layer 2, which returns the same crisis answer with the helpline number.
  { pattern: /\b(suizid\w*|selbstmord|mich\s*umbringen|sterben\s*wollen|kill\s*myself|cutting\s+myself|self[\s-]?(harm\w*|cutting)|selbstverletz\w*|(mich|mir|sich)\s+(\w+\s+){0,2}(zu\s+)?(ge)?ritz(en|t)|ritze\s+mich)\b/i, reason: "self_harm" },
  // Homework/coding hijack ("oe" as the ASCII variant of "ö"). Standalone
  // "hausaufgab\w*" is excluded because it also appears in legitimate context
  // sentences; only verb-bound forms match, the rest is layer 2's off_topic.
  { pattern: /\b(l(oe|o|ö)se\s*(diese|meine|mir)?\s*(gleichung|aufgabe|haus(aufgabe)?|integral|matheaufgabe)|essay\s*schreiben|aufsatz\s*schreiben|schreib\s*mir\s*(eine?n?)?\s*(code|programm|skript|essay|hausarbeit|bewerbung|email|brief)|programmier\s*mir)\b/i, reason: "off_topic_homework" },
  // Prompt injection. No "act as|act like": it would block normal English
  // nutrition questions, and real roleplay injections are layer 2's job.
  // "du bist jetzt" stays, minus the harmless "du bist jetzt mein …coach".
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
