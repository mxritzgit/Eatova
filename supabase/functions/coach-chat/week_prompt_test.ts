// The answer prompt's rules for the seven-day block (C2, 2026-10-18).
//
// The new USING APP DATA lines join the prompt-leak table like every other
// non-exempt line: a recital trips the net, while ordinary answers about the
// week must not. One shared seven-word run would turn a good answer into the
// leak refusal, so the matrix uses the words such answers actually reach for.
//
// `deno test --allow-env`; no network.

import { PROMPT_LEAK_GUARD } from "./handler.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

Deno.test("C2: die Wochenregeln stehen im Prompt und sind gegen Rezitieren geschuetzt", () => {
  for (
    const recital of [
      "Reading the 7-day block: it covers the seven days before today.",
      "Unlogged days are missing data, never zero intake; days under 50 % of the goal are probably incomplete.",
      "Its weight trend is a 21-day slope in kg per week with a noise band.",
      "Do not compute your own maintenance or target: the daily goal comes from the app's calorie model.",
    ]
  ) {
    assert(PROMPT_LEAK_GUARD.leaks(recital), `keine Leck-Erkennung fuer: ${recital}`);
  }
});

Deno.test("C2: normale Antworten zur Woche loesen das Leck-Netz nicht aus", () => {
  for (
    const answer of [
      "In den letzten 7 Tagen hast du 3 von 7 Tagen erfasst, an einem davon nur ein Fruehstueck. " +
      "An den zwei vollstaendigen Tagen lagst du mit rund 2100 kcal genau im Ziel. Dein Gewichtstrend " +
      "ueber 21 Tage liegt bei -0,1 kg pro Woche, das ist noch im Rauschen. Erfasse ein paar Tage " +
      "komplett und wieg dich morgens, dann sieht man mehr; der Wochen-Check der App passt dein Ziel " +
      "bei Bedarf selbst an.",
      "Looking at the last 7 days, you logged 3 of 7 days, so I only see part of the week. On the " +
      "days you logged fully you averaged about 2,050 kcal against your goal of 2,100. Your weight " +
      "trend over the last 21 days is -0.35 kg per week, which is clearly outside its noise band, so " +
      "you are losing weight. The days without entries are simply missing data, so I can't tell what " +
      "happened there. Try to log every day and weigh in each morning; the app's weekly check will " +
      "suggest a new goal if your intake and weight trend call for it.",
      "Your weight is stable within the noise right now. With only 2 weigh-ins in 21 days there is no " +
      "reliable rate yet, so weigh yourself a few mornings a week before we change anything.",
    ]
  ) {
    assert(!PROMPT_LEAK_GUARD.leaks(answer), `falscher Leck-Treffer: ${answer}`);
  }
});
