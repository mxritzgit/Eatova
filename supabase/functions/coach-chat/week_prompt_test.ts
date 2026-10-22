// The answer prompt's rules for the app data (C2, 2026-10-18).
//
// USING APP DATA tells the model what the app context holds and how the app
// reads it: the same facts the Coach info sheet shows every user. An English
// answer that explains them ("your daily goal comes from the app's calorie
// model") copies seven-word runs of those lines, so the section is exempt from
// the prompt-leak table like YOUR SCOPE; until 2026-10-22 such answers became
// the leak refusal and still cost the daily slot. A recital of the prompt
// still trips on the persona, language, refusal and style lines.
//
// `deno test --allow-env`; no network.

import { PROMPT_LEAK_GUARD } from "./handler.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

Deno.test("C2: Antworten, die die App-Daten erklaeren, loesen das Leck-Netz nicht aus", () => {
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
      // Each of these tripped the net before the exemption.
      "Your daily goal comes from the app's calorie model, so I won't calculate a new one.",
      "I can see your profile, today's targets, what is still open, a summary of the last 7 days " +
      "and the foods you logged today.",
      "Two of those days are under 50 % of the goal, so they are probably incomplete and stay out " +
      "of the averages.",
      "Your weight trend is a 21-day slope of about -0.3 kg per week; a rate within the band counts " +
      "as stable.",
      "The weekly check compares intake with the weight trend and proposes any adjustment in the app.",
      "Dein Wochen-Check sammelt noch Daten, es fehlen noch Wiegungen. Fuer heute Abend hast du die " +
      "Lachs-Bowl geplant; sie passt gut in die 640 kcal, die noch offen sind.",
      "Your weekly check is still collecting data, so there is no estimate yet. You planned the salmon " +
      "bowl for dinner tonight, and it fits the calories you have left. If you already ate, log it with " +
      "/meal 2 eggs and toast style, and review the entry before you add it to today's diary.",
    ]
  ) {
    assert(!PROMPT_LEAK_GUARD.leaks(answer), `falscher Leck-Treffer: ${answer}`);
  }
});
