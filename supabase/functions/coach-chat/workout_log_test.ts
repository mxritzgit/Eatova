// Pure /log contract: the shared fixture, the command token, the server-side
// transform of the model's extraction and the localized texts.
import {
  acceptableLocalDate,
  decodeWorkoutLogExtraction,
  isCalendarDate,
  LOG_REFUSAL_REASONS,
  parseWorkoutLog,
  parseWorkoutLogCommand,
  transformExtraction,
  WORKOUT_LOG_SAFETY_LINE,
  workoutLogRefusalText,
  workoutLogSummary,
  workoutLogSystemPrompt,
} from "./workout_log.ts";
// A module import, not a file read: CI runs these tests with --allow-env only.
import CASES from "./fixtures/workout_log_cases.json" with { type: "json" };

type Row = Record<string, unknown>;

const FIXTURE = CASES as unknown as { valid: Row[]; invalid: { reason: string; value: unknown }[] };
const LOCAL_DATE = "2026-10-03";

function assert(condition: unknown, label: string): asserts condition {
  if (!condition) throw new Error(label);
}

function equal(actual: unknown, expected: unknown, label: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

/** The model's view of a stored log: unit per exercise, no schema version. */
function extraction(log: Row, unit = "kg"): Row {
  const { schema_version: _version, exercises, ...workout } = log;
  return {
    status: "ok", refuse_reason: null,
    workout: {
      ...workout,
      exercises: (exercises as Row[]).map((exercise) => ({
        name: exercise.name, kind: exercise.kind, duration_seconds: exercise.duration_seconds, weight_unit: unit,
        sets: (exercise.sets as Row[]).map((set) => ({ reps: set.reps, weight: set.weight_kg })),
      })),
    },
  };
}

function withWeight(weight: unknown, unit = "kg"): Row {
  const raw = extraction(FIXTURE.valid[0], unit);
  ((raw.workout as Row).exercises as Row[])[0].sets = [{ reps: 20, weight }];
  return raw;
}

Deno.test("fixture: the shared file holds the agreed case counts", () => {
  assert(FIXTURE.valid.length >= 12, "at least 12 valid logs");
  assert(FIXTURE.invalid.length >= 20, "at least 20 invalid logs");
  const reasons = new Set(FIXTURE.invalid.map((entry) => entry.reason));
  equal(reasons.size, FIXTURE.invalid.length, "every invalid case has its own reason");
});

Deno.test("fixture: every valid log is accepted unchanged", () => {
  FIXTURE.valid.forEach((log, index) => {
    equal(parseWorkoutLog(log), log, `valid #${index}`);
  });
});

Deno.test("fixture: every invalid log is rejected", () => {
  for (const { reason, value } of FIXTURE.invalid) {
    equal(parseWorkoutLog(value), null, reason);
  }
});

Deno.test("validator: the result is a copy, not the caller's object", () => {
  const input = structuredClone(FIXTURE.valid[0]);
  const parsed = parseWorkoutLog(input)!;
  (input.exercises as Row[])[0].name = "changed";
  equal(parsed.exercises[0].name, "Barbell", "detached copy");
});

Deno.test("command: only the exact /log token selects the workout wish", () => {
  equal(parseWorkoutLogCommand("/log today squats"), "today squats", "plain token");
  equal(parseWorkoutLogCommand(" /LOG\t heute Kniebeugen 3x10 "), "heute Kniebeugen 3x10", "case and whitespace");
  equal(parseWorkoutLogCommand("/LOG"), "", "empty wish");
  equal(parseWorkoutLogCommand("/log\n\nbench 5x5"), "bench 5x5", "newline separator");
  equal(parseWorkoutLogCommand("/logbook"), null, "longer word stays chat");
  equal(parseWorkoutLogCommand("/log/bench"), null, "no separator");
  equal(parseWorkoutLogCommand("log bench"), null, "no slash");
  equal(parseWorkoutLogCommand("/plan legs"), null, "other command");
});

Deno.test("dates: calendar format only, and the client day within one day of the server", () => {
  for (const value of ["2026-10-03", "2024-02-29", "2026-12-31"]) assert(isCalendarDate(value), value);
  for (const value of ["2026-02-30", "2025-02-29", "2026-13-01", "2026-10-00", "2026-10-3", "03.10.2026", "2026-10-03T00:00:00Z", 20261003, null]) {
    assert(!isCalendarDate(value), String(value));
  }
  const now = Date.parse("2026-10-04T00:00:10Z");
  for (const value of ["2026-10-03", "2026-10-04", "2026-10-05"]) assert(acceptableLocalDate(value, now), value);
  for (const value of ["2026-10-02", "2026-10-06", "2026-02-30", "", undefined]) assert(!acceptableLocalDate(value, now), String(value));
});

Deno.test("transform: a kg extraction becomes the stored log with schema_version and without units", () => {
  // The first 18 valid logs are the eval shapes E1-E22 relative to LOCAL_DATE.
  FIXTURE.valid.slice(0, 18).forEach((log, index) => {
    equal(transformExtraction(extraction(log), LOCAL_DATE), { kind: "log", log }, `valid #${index}`);
  });
});

Deno.test("transform: pounds become kilograms rounded to 0.01", () => {
  const result = transformExtraction(withWeight(225, "lb"), LOCAL_DATE);
  assert(result?.kind === "log", "converted log");
  equal(result.log.exercises[0].sets[0].weight_kg, 102.06, "225 lb");
  const exact = transformExtraction(withWeight(2000, "lb"), LOCAL_DATE);
  assert(exact?.kind === "log", "2000 lb is in range");
  equal(exact.log.exercises[0].sets[0].weight_kg, 907.18, "2000 lb");
  const kg = transformExtraction(withWeight(102.058), LOCAL_DATE);
  assert(kg?.kind === "log", "kg rounded");
  equal(kg.log.exercises[0].sets[0].weight_kg, 102.06, "102.058 kg");
  equal(transformExtraction(withWeight(5000, "lb"), LOCAL_DATE), null, "2267.96 kg is out of range");
  equal(transformExtraction(withWeight(-5), LOCAL_DATE), null, "negative weight");
  equal(transformExtraction(withWeight("80"), LOCAL_DATE), null, "string weight");
  equal(transformExtraction(withWeight(80, "stone"), LOCAL_DATE), null, "unknown unit");
});

Deno.test("transform: performed_on outside [local_date - 30, local_date] becomes null", () => {
  const cases: [string, string | null][] = [
    ["2026-10-03", "2026-10-03"], ["2026-09-03", "2026-09-03"], ["2026-09-02", null],
    ["2026-10-04", null], ["2027-10-03", null], ["2026-02-30", null], ["yesterday", null],
  ];
  for (const [performed, expected] of cases) {
    const raw = extraction(FIXTURE.valid[0]);
    (raw.workout as Row).performed_on = performed;
    const result = transformExtraction(raw, LOCAL_DATE);
    assert(result?.kind === "log", performed);
    equal(result.log.performed_on, expected, performed);
  }
  const typed = extraction(FIXTURE.valid[0]);
  (typed.workout as Row).performed_on = 20261003;
  equal(transformExtraction(typed, LOCAL_DATE), null, "a non-string date is a schema violation");
});

Deno.test("transform: refusals map to the reason enum; inconsistent envelopes are invalid", () => {
  for (const reason of LOG_REFUSAL_REASONS) {
    equal(transformExtraction({ status: "refuse", refuse_reason: reason, workout: null }, LOCAL_DATE),
      { kind: "refusal", reason }, reason);
  }
  const ok = extraction(FIXTURE.valid[0]);
  for (const [label, raw] of [
    ["unknown reason", { status: "refuse", refuse_reason: "boring", workout: null }],
    ["refusal with workout", { status: "refuse", refuse_reason: "unsafe", workout: ok.workout }],
    ["ok with reason", { ...ok, refuse_reason: "unsafe" }],
    ["ok without workout", { ...ok, workout: null }],
    ["unknown status", { ...ok, status: "maybe" }],
    ["extra envelope key", { ...ok, note: "x" }],
    ["missing envelope key", { status: "ok", workout: ok.workout }],
    ["stored shape instead of extraction", { status: "ok", refuse_reason: null, workout: FIXTURE.valid[0] }],
    ["not an object", "ok"],
  ] as [string, unknown][]) {
    equal(transformExtraction(raw, LOCAL_DATE), null, label);
  }
  const extraSet = extraction(FIXTURE.valid[0]);
  (((extraSet.workout as Row).exercises as Row[])[0].sets as Row[])[0].rpe = 8;
  equal(transformExtraction(extraSet, LOCAL_DATE), null, "extra set key");
  const missingUnit = extraction(FIXTURE.valid[0]);
  delete ((missingUnit.workout as Row).exercises as Row[])[0].weight_unit;
  equal(transformExtraction(missingUnit, LOCAL_DATE), null, "missing unit");
  const tooManyReps = withWeight(100);
  (((tooManyReps.workout as Row).exercises as Row[])[0].sets as Row[])[0].reps = 1001;
  equal(transformExtraction(tooManyReps, LOCAL_DATE), null, "validated after transform");
});

Deno.test("decode: one JSON object, one optional fence, bounded size", () => {
  const raw = JSON.stringify(extraction(FIXTURE.valid[0]));
  equal(decodeWorkoutLogExtraction(raw, LOCAL_DATE)?.kind, "log", "plain");
  equal(decodeWorkoutLogExtraction("```json\n" + raw + "\n```", LOCAL_DATE)?.kind, "log", "fenced");
  equal(decodeWorkoutLogExtraction("Here you go: " + raw, LOCAL_DATE), null, "prose");
  equal(decodeWorkoutLogExtraction(raw + raw, LOCAL_DATE), null, "two objects");
  equal(decodeWorkoutLogExtraction(raw.replace('"note":""', '"note":"' + " ".repeat(300 * 1024) + '"'), LOCAL_DATE), null, "oversized");
});

Deno.test("summary: localized, never claims a save, safety line last for medical mentions", () => {
  const log = parseWorkoutLog(FIXTURE.valid[1])!;
  const de = workoutLogSummary(log, "de");
  const en = workoutLogSummary(parseWorkoutLog(FIXTURE.valid[0])!, "en");
  assert(de.includes("Beintag") && de.includes("3 Übungen") && de.includes("2026-10-02"), de);
  assert(en.includes("Workout") && en.includes("2 exercises") && en.includes("2026-10-03"), en);
  for (const text of [de, en]) {
    assert(!/saved|gespeichert|hinzugefügt|added|logged/i.test(text), `no save claim: ${text}`);
  }
  assert(workoutLogSummary(parseWorkoutLog(FIXTURE.valid[3])!, "en").includes("1 exercise,"), "singular");
  assert(workoutLogSummary(parseWorkoutLog(FIXTURE.valid[16])!, "en").includes("3 exercises,"), "plural");
  const omitted = workoutLogSummary(parseWorkoutLog(FIXTURE.valid[8])!, "en");
  assert(/only the most recent day/i.test(omitted), omitted);
  const undated = workoutLogSummary(parseWorkoutLog(FIXTURE.valid[12])!, "de");
  assert(/Datum/.test(undated) && !/null/.test(undated), undated);
  for (const locale of ["de", "en"] as const) {
    const safe = workoutLogSummary(log, locale, { medicalRisk: true });
    assert(safe.endsWith(WORKOUT_LOG_SAFETY_LINE[locale]), `${locale}: ${safe}`);
    assert(!workoutLogSummary(log, locale).includes(WORKOUT_LOG_SAFETY_LINE[locale]), "only when flagged");
  }
  assert(/doctor|physio/i.test(WORKOUT_LOG_SAFETY_LINE.en) && /ärztlich|physio/i.test(WORKOUT_LOG_SAFETY_LINE.de), "fixed safety wording");
});

Deno.test("refusal texts: one fixed text per reason and language", () => {
  const seen = new Set<string>();
  for (const reason of LOG_REFUSAL_REASONS) {
    const de = workoutLogRefusalText(reason, "de");
    const en = workoutLogRefusalText(reason, "en");
    assert(de.length > 20 && en.length > 20 && de !== en, reason);
    assert(!/[äöüß]/i.test(en), `${reason}: English text`);
    seen.add(de).add(en);
  }
  equal(seen.size, LOG_REFUSAL_REASONS.length * 2, "distinct texts");
});

Deno.test("prompt: language, the 8-day calendar, all 19 rules and the extraction schema", () => {
  const en = workoutLogSystemPrompt("en", LOCAL_DATE);
  const de = workoutLogSystemPrompt("de", LOCAL_DATE);
  assert(en.includes("in English") && !en.includes("in German"), "English text fields");
  assert(de.includes("in German") && !de.includes("in English"), "German text fields");
  assert(en.includes("2026-10-03") && /2026-10-03[^\n]*Saturday[^\n]*today/.test(en), "today with weekday");
  assert(/2026-10-02[^\n]*Friday[^\n]*yesterday/.test(en), "yesterday");
  assert(/2026-10-01[^\n]*Thursday[^\n]*vorgestern/.test(en), "vorgestern");
  assert(/2026-09-26[^\n]*Saturday/.test(en), "seven days back");
  assert(!en.includes("2026-09-25"), "exactly eight days");
  for (let rule = 1; rule <= 19; rule++) assert(en.includes(`\n${rule}. `), `rule ${rule}`);
  assert(!en.includes("\n20. "), "no extra rule");
  for (const key of ["status", "refuse_reason", "not_a_workout", "not_completed", "too_large", "unsafe", "weight_unit", "other_days_omitted", "duration_seconds"]) {
    assert(en.includes(key), key);
  }
  assert(/never invent/i.test(en) && /data/i.test(en), "data-only, no invention");
});
