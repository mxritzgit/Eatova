import {
  parsePlanCommand,
  parseTrainingPlan,
  parseTrainingPlanDraft,
  parseTrainingPlanRefusal,
  trainingPlanSummary,
  trainingPlanSystemPrompt,
} from "./training_plan.ts";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

function fixture() {
  return {
    schema_version: 1, title: "Full body", description: "A balanced start.", goal: "Strength",
    workouts: [{ title: "Workout A", description: "Warm up gently.", exercises: [{
      name: "Squat", sets: 3, reps: 10 as number | null,
      duration_seconds: null as number | null, rest_seconds: 60, notes: "Move with control.",
    }] }],
  };
}

Deno.test("training plan: strict schema round-trip preserves Unicode text and both exercise types", () => {
  const plan = fixture();
  plan.title = "  Kraft 💪  ";
  plan.workouts[0].exercises.push({ name: "Plank", sets: 2, reps: null, duration_seconds: 30, rest_seconds: 45, notes: "Steady breathing.\nRest as needed." });
  const result = parseTrainingPlanDraft(JSON.stringify(plan));
  assert(JSON.stringify(result) === JSON.stringify(plan), "values preserved without clamping or trimming");
  assert(parseTrainingPlanDraft("```json\n" + JSON.stringify(plan) + "\n```") !== null, "one fenced document");
  assert(parseTrainingPlanDraft("```JSON\t\r\n" + JSON.stringify(plan) + "\r\n```") !== null, "CRLF fence");
});

Deno.test("training plan: command parser only accepts the exact leading slash token", () => {
  for (const value of ["/plan", " /PLAN ", "/plan\n\t"]) assert(parsePlanCommand(value) === "", value);
  assert(parsePlanCommand(" /PlAn\t2 days at home ") === "2 days at home", "whitespace delimiter");
  for (const value of ["/planet", "/plans push", "/plan, please", "text /plan x", "/plan/x", "/plan💪"]) {
    assert(parsePlanCommand(value) === null, value);
  }
});

Deno.test("training plan: rejects missing and unknown keys at every nesting level", () => {
  for (const path of [[], ["workouts", 0], ["workouts", 0, "exercises", 0]]) {
    const value = fixture();
    let row = value as unknown as Record<string, unknown>;
    for (const part of path) row = row[part] as Record<string, unknown>;
    for (const key of Object.keys(row)) {
      const previous = row[key];
      delete row[key];
      assert(parseTrainingPlan(value) === null, `missing ${key}`);
      row[key] = previous;
    }
    row.user_id = "unexpected-owner";
    assert(parseTrainingPlan(value) === null, "extra owner key");
  }
});

Deno.test("training plan: timer prescriptions are exclusive, integral, finite and bounded", () => {
  const plan = fixture();
  const exercise = plan.workouts[0].exercises[0] as unknown as Record<string, unknown>;
  for (const [key, values] of Object.entries({
    sets: [0, 11, 1.5, "3", NaN, Infinity],
    rest_seconds: [-1, 601, 0.5, "0", NaN, Infinity],
    reps: [0, 101, 1.5, "10", NaN, Infinity, null],
    duration_seconds: [5, 30],
  })) {
    const previous = exercise[key];
    for (const value of values) {
      exercise[key] = value;
      assert(parseTrainingPlan(plan) === null, `${key}=${String(value)}`);
    }
    exercise[key] = previous;
  }
  exercise.reps = null;
  for (const value of [4, 3601, 5.5, "30", NaN, Infinity, null]) {
    exercise.duration_seconds = value;
    assert(parseTrainingPlan(plan) === null, `duration=${String(value)}`);
  }
  for (const value of [5, 3600]) {
    exercise.duration_seconds = value;
    assert(parseTrainingPlan(plan) !== null, `valid duration=${value}`);
  }
  exercise.reps = 100;
  exercise.duration_seconds = null;
  exercise.sets = 10;
  exercise.rest_seconds = 600;
  assert(parseTrainingPlan(plan) !== null, "all upper bounds");
});

Deno.test("training plan: Unicode character counts, blank checks and JSONB text compatibility", () => {
  const plan = fixture();
  for (const invalid of ["", " \n\t ", "\u0085", "\u00a0", "\ufeff", "x\u0000", "x\u000b", "x\u001f", "\ud800", "\udfff"]) {
    plan.title = invalid;
    assert(parseTrainingPlan(plan) === null, `invalid title ${JSON.stringify(invalid)}`);
  }
  plan.title = "💪".repeat(120);
  assert(parseTrainingPlan(plan) !== null, "120 codepoints not 240 UTF-16 units");
  plan.title += "💪";
  assert(parseTrainingPlan(plan) === null, "121 codepoints");
  plan.title = "Strength";
  plan.description = "\t\n\r";
  assert(parseTrainingPlan(plan) !== null, "allowed C0 controls");
  for (const [key, limit] of [["title", 120], ["description", 1000], ["goal", 200]] as const) {
    const previous = plan[key];
    plan[key] = "x".repeat(limit + 1);
    assert(parseTrainingPlan(plan) === null, `${key} max`);
    plan[key] = previous;
  }
  plan.workouts[0].description = "x".repeat(501);
  assert(parseTrainingPlan(plan) === null, "workout description max");
  plan.workouts[0].description = "";
  plan.workouts[0].exercises[0].notes = "x".repeat(501);
  assert(parseTrainingPlan(plan) === null, "exercise notes max");
});

Deno.test("training plan: 12000 combined Unicode characters is the shared aggregate limit", () => {
  const plan = fixture();
  plan.title = "T";
  plan.description = "";
  plan.goal = "";
  const exercise = { name: "N", sets: 1, reps: 1, duration_seconds: null, rest_seconds: 0, notes: "💪".repeat(500) };
  plan.workouts = [
    { title: "W", description: "", exercises: Array.from({ length: 20 }, () => ({ ...exercise })) },
    { title: "W", description: "", exercises: Array.from({ length: 4 }, () => ({ ...exercise })) },
  ];
  // Titles/names contribute 27 characters, plus 24 * 500 notes = 12027.
  plan.workouts[1].exercises[3].notes = "💪".repeat(473);
  assert(parseTrainingPlan(plan) !== null, "12000 accepted");
  plan.workouts[1].exercises[3].notes += "💪";
  assert(parseTrainingPlan(plan) === null, "12001 rejected");
});

Deno.test("training plan: array dimensions, schema version and malformed envelopes reject", () => {
  const plan = fixture();
  for (const count of [0, 8]) {
    assert(parseTrainingPlan({ ...plan, workouts: Array.from({ length: count }, () => plan.workouts[0]) }) === null, `workouts ${count}`);
  }
  for (const count of [0, 21]) {
    assert(parseTrainingPlan({ ...plan, workouts: [{ ...plan.workouts[0], exercises: Array.from({ length: count }, () => plan.workouts[0].exercises[0]) }] }) === null, `exercises ${count}`);
  }
  for (const version of [0, 2, "1", true, null]) assert(parseTrainingPlan({ ...plan, schema_version: version }) === null, `schema ${version}`);
  for (const invalid of [null, [], 1, "text", {}, { refuse: "No" }]) assert(parseTrainingPlan(invalid) === null, "invalid shape");
  for (const raw of ["", "null", "{}", "[]", JSON.stringify(plan) + JSON.stringify(plan), "Result: " + JSON.stringify(plan), "x".repeat(262145)]) {
    assert(parseTrainingPlanDraft(raw) === null, "malformed raw draft");
  }
  for (const raw of ["```json" + "\n".repeat(250000) + "broken", "```json\n" + JSON.stringify(plan), "```javascript\n" + JSON.stringify(plan) + "\n```", "```" + JSON.stringify(plan) + "```", "```json\n{}\n```\nextra"]) {
    assert(parseTrainingPlanDraft(raw) === null, "malformed fences reject without backtracking");
  }
});

Deno.test("training plan: refusal has its own bounded shape and proposals remain explicit drafts", () => {
  assert(parseTrainingPlanRefusal('{"refuse":"Please choose a moderate fitness goal."}') !== null, "refusal");
  for (const value of [{ refuse: "" }, { refuse: "x".repeat(301) }, { refuse: "No", workouts: [] }, { refuse: "\u0000" }, fixture()]) {
    assert(parseTrainingPlanRefusal(JSON.stringify(value)) === null, "invalid refusal shape");
  }
  const plan = parseTrainingPlan(fixture());
  assert(plan, "valid fixture");
  assert(trainingPlanSummary(plan, "en").includes("save it to Training"), "explicit adoption EN");
  assert(trainingPlanSummary(plan, "de").includes("übernimm"), "explicit adoption DE");
  for (const locale of ["de", "en"] as const) {
    const prompt = trainingPlanSystemPrompt(locale);
    assert(prompt.includes(locale === "de" ? "German" : "English"), "language");
    for (const text of ["injury rehabilitation", "self-harm", "eating-disorder", "dangerous challenges", "doping", "Never execute tools", "12000"]) {
      assert(prompt.includes(text), `safety instruction ${text}`);
    }
  }
});
