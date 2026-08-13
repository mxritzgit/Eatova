// End-to-End-Tests fuer den Recipe-Mode (mode: "recipe") von handleRequest —
// fetch gestubbt, gleicher Stil wie handler_test.ts (bewusst ohne externe
// Test-Dependencies). Deckt die Spec-Zusicherungen ab:
//   * 1 Quota-Slot pro Rezept, Refund NUR bei Infra-Fehlern
//   * Bild-Fehler != Rezept-Fehler (200 ohne image_base64)
//   * JSON-Refusal kostet den Slot (wie Layer-2-Refusals im Chat)
//   * kein Classifier-Call, keine History-Query im Recipe-Mode
//   * Prefilter (Layer 1) laeuft weiterhin VOR der Quota

import { handleRequest } from "./handler.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const ASSISTANT_MSG_ID = "33333333-3333-4333-8333-333333333333";
const BASE_URL = "https://supabase.test.invalid";
const IMAGE_B64 = "aGFsbG8taWNoLWJpbi1laW4tYmlsZA==";

const RECIPE_JSON = JSON.stringify({
  title: "Huehnchenauflauf",
  description: "Cremig und proteinreich.",
  portion: "1 grosse Portion",
  ingredients: "- 250 g Haehnchenbrust\n- 150 g Brokkoli",
  preparation: "1. Ofen vorheizen.\n2. Backen.",
  calories_kcal: 520,
  protein_g: 48,
  carbs_g: 32,
  fat_g: 18,
  estimated_g: 450,
});

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("OPENROUTER_API_KEY", "test-openrouter-key");

type JsonRecord = Record<string, unknown>;

interface RecordedCall {
  url: string;
  method: string;
  body: string;
}

interface StubOptions {
  /** "ok" (Default), "exhausted" oder "forbidden" (Claim darf nie passieren). */
  quota?: "ok" | "exhausted" | "forbidden";
  /** Antwort-Content des Draft-Calls (max_tokens 900). */
  draftContent?: string;
  /** HTTP-Status des Draft-Calls (Infra-Fehler-Simulation). */
  draftStatus?: number;
  /** HTTP-Status des Bild-Calls (/api/v1/images). */
  imageStatus?: number;
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(
      `${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`,
    );
  }
}

function jsonRes(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

interface FetchStub {
  calls: RecordedCall[];
  callsTo(fragment: string): RecordedCall[];
  restore(): void;
}

function installFetch(options: StubOptions = {}): FetchStub {
  const calls: RecordedCall[] = [];
  const original = globalThis.fetch;

  function route(url: string, method: string, _body: string): Response {
    if (url.includes("/auth/v1/user")) return jsonRes({ id: USER_ID });
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
      return jsonRes({
        allowed: true,
        limit: 120,
        remaining: 119,
        resetAt: new Date(Date.now() + 600_000).toISOString(),
        windowSeconds: 600,
      });
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) {
      return new Response(null, { status: 204 });
    }
    if (url.includes("/rest/v1/rpc/ensure_default_chat_session")) {
      return jsonRes(SESSION_ID);
    }
    if (url.includes("/rest/v1/rpc/touch_chat_session")) {
      return new Response(null, { status: 204 });
    }
    if (url.includes("/rest/v1/rpc/claim_chat_quota")) {
      const mode = options.quota ?? "ok";
      if (mode === "forbidden") {
        throw new Error(
          "claim_chat_quota wurde auf einem Pfad aufgerufen, der die Quota nicht anfassen darf",
        );
      }
      if (mode === "exhausted") {
        return jsonRes({ message: "EX_QUOTA_EXCEEDED" }, 400);
      }
      return jsonRes([{ used: 1, remaining: 4 }]);
    }
    if (url.includes("/rest/v1/rpc/refund_chat_quota")) {
      return new Response(null, { status: 204 });
    }
    if (url.includes("openrouter.ai/api/v1/images")) {
      if (options.imageStatus !== undefined) {
        return new Response("image upstream down", { status: options.imageStatus });
      }
      return jsonRes({
        data: [{ b64_json: IMAGE_B64, media_type: "image/jpeg" }],
      });
    }
    if (url.includes("openrouter.ai/api/v1/chat/completions")) {
      if (options.draftStatus !== undefined) {
        return new Response("upstream unavailable", { status: options.draftStatus });
      }
      return jsonRes({
        choices: [{ message: { content: options.draftContent ?? RECIPE_JSON } }],
      });
    }
    if (url.includes("/rest/v1/chat_messages")) {
      if (method === "POST") {
        // Die Rezept-Assistant-Zeile (traegt das recipe-JSON) wird mit
        // return=representation eingefuegt — der Handler braucht ihre id
        // fuer assistant_message_id (Reload-Karte, Nachtrag 2026-08-13).
        if (_body.includes('"recipe"')) {
          return jsonRes([{ id: ASSISTANT_MSG_ID }], 201);
        }
        return new Response(null, { status: 201 });
      }
      // GET = loadHistory — darf im Recipe-Mode nie passieren; die Tests
      // pruefen das ueber callsTo, deshalb hier kein Wurf.
      return jsonRes([]);
    }
    if (url.includes("/rest/v1/chat_sessions")) {
      if (method === "PATCH") return new Response(null, { status: 204 });
      if (url.includes("select=title")) return jsonRes([{ title: "Neue Unterhaltung" }]);
      return jsonRes([]);
    }
    throw new Error(`Unerwarteter fetch im Test: ${method} ${url}`);
  }

  globalThis.fetch = ((
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    const method = (init?.method ?? "GET").toUpperCase();
    const body = typeof init?.body === "string" ? init.body : "";
    calls.push({ url, method, body });
    return Promise.resolve(route(url, method, body));
  }) as typeof globalThis.fetch;

  return {
    calls,
    callsTo: (fragment: string) => calls.filter((call) => call.url.includes(fragment)),
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

function makeRecipeRequest(payload: JsonRecord = {}): Request {
  return new Request("https://edge.test.invalid/coach-chat", {
    method: "POST",
    headers: {
      "authorization": "Bearer test-user-jwt",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      message: "Huehnchenauflauf mit Brokkoli",
      mode: "recipe",
      locale: "de",
      ...payload,
    }),
  });
}

// ---------------------------------------------------------------------------

Deno.test("Recipe-Mode Happy Path: Rezept + Bild + Summary, 1 Slot", async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRecipeRequest());
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;

    const recipe = body.recipe as JsonRecord;
    assertEquals(recipe.title, "Huehnchenauflauf", "recipe.title");
    assertEquals(recipe.calories_kcal, 520, "recipe.kcal");
    assertEquals(body.image_base64, IMAGE_B64, "image_base64");
    assertEquals(body.image_mime_type, "image/jpeg", "image_mime_type");
    assert(
      String(body.reply).includes("Huehnchenauflauf"),
      `Summary nennt den Titel, war: ${String(body.reply)}`,
    );
    assertEquals(body.remaining, 4, "remaining aus dem Claim");
    assertEquals(body.daily_limit, 5, "daily_limit");
    assertEquals(body.session_id, SESSION_ID, "session_id");

    assertEquals(stub.callsTo("claim_chat_quota").length, 1, "genau ein Claim");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund");
    // Genau ZWEI OpenRouter-Calls: Draft + Bild. KEIN Classifier.
    assertEquals(stub.callsTo("chat/completions").length, 1, "genau ein Draft-Call");
    const draftBody = JSON.parse(stub.callsTo("chat/completions")[0].body) as JsonRecord;
    assertEquals(draftBody.max_tokens, 900, "Draft-Call, kein Classifier/Answer");
    assertEquals(
      (draftBody.response_format as JsonRecord)?.type,
      "json_object",
      "response_format erzwingt JSON",
    );
    assertEquals(stub.callsTo("api/v1/images").length, 1, "genau ein Bild-Call");
    // Keine History-Query im Recipe-Mode.
    const historyReads = stub.calls.filter((c) =>
      c.url.includes("/rest/v1/chat_messages") && c.method === "GET"
    );
    assertEquals(historyReads.length, 0, "keine History-Query");
    // Verlauf: User-Wunsch + Assistant-Summary MIT Rezept-JSON (Reload-Karte).
    const stores = stub.calls.filter((c) =>
      c.url.includes("/rest/v1/chat_messages") && c.method === "POST"
    );
    assertEquals(stores.length, 2, "User + Summary persistiert");
    assert(
      stores[1].body.includes("Rezeptvorschlag"),
      "Assistant-Zeile ist die Summary",
    );
    assert(
      stores[1].body.includes('"recipe"') &&
        stores[1].body.includes('"Huehnchenauflauf"'),
      "Assistant-Zeile traegt das Rezept-JSON",
    );
    assertEquals(
      body.assistant_message_id,
      ASSISTANT_MSG_ID,
      "assistant_message_id fuer die lokale Bild-Ablage",
    );
  } finally {
    stub.restore();
  }
});

Deno.test("Bild-Fehler != Rezept-Fehler: 200 ohne image_base64, kein Refund", async () => {
  const stub = installFetch({ imageStatus: 500 });
  try {
    const res = await handleRequest(makeRecipeRequest());
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals((body.recipe as JsonRecord).title, "Huehnchenauflauf", "Rezept da");
    assert(!("image_base64" in body), "image_base64 fehlt (kein erfundenes Bild)");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund");
  } finally {
    stub.restore();
  }
});

Deno.test("Draft-Infra-Fehler: 502 + genau ein Refund, kein Bild-Call", async () => {
  const stub = installFetch({ draftStatus: 500 });
  try {
    const res = await handleRequest(makeRecipeRequest());
    assertEquals(res.status, 502, "Status");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "genau ein Refund");
    assertEquals(stub.callsTo("api/v1/images").length, 0, "kein Bild-Call");
  } finally {
    stub.restore();
  }
});

Deno.test("Unlesbarer Draft (kein JSON): 502 + Refund", async () => {
  const stub = installFetch({ draftContent: "Hier ist dein Rezept: viel Spass!" });
  try {
    const res = await handleRequest(makeRecipeRequest());
    assertEquals(res.status, 502, "Status");
    assertEquals(stub.callsTo("refund_chat_quota").length, 1, "genau ein Refund");
  } finally {
    stub.restore();
  }
});

Deno.test("JSON-Refusal: 200 refusal ohne recipe, Slot kostet (kein Refund)", async () => {
  const stub = installFetch({
    draftContent: JSON.stringify({ refuse: "Ich erstelle nur Essensrezepte." }),
  });
  try {
    const res = await handleRequest(makeRecipeRequest({
      message: "Schreib mir einen Aufsatz ueber Goethe",
    }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.reply, "Ich erstelle nur Essensrezepte.", "Refusal-Satz");
    assert(!("recipe" in body), "kein recipe-Feld");
    assertEquals(stub.callsTo("refund_chat_quota").length, 0, "kein Refund");
    assertEquals(stub.callsTo("api/v1/images").length, 0, "kein Bild-Call");
  } finally {
    stub.restore();
  }
});

Deno.test("Tageslimit erschoepft: 429 VOR jedem Provider-Call", async () => {
  const stub = installFetch({ quota: "exhausted" });
  try {
    const res = await handleRequest(makeRecipeRequest());
    assertEquals(res.status, 429, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.error, "quota_exceeded", "error");
    assertEquals(stub.callsTo("openrouter.ai").length, 0, "keine Provider-Calls");
  } finally {
    stub.restore();
  }
});

Deno.test("Prefilter (Layer 1) greift auch im Recipe-Mode — ohne Quota-Claim", async () => {
  const stub = installFetch({ quota: "forbidden" });
  try {
    const res = await handleRequest(makeRecipeRequest({ message: "" }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assertEquals(body.refusal, true, "refusal");
    assertEquals(body.refusal_reason, "empty", "Layer-1-Grund");
    assertEquals(stub.callsTo("openrouter.ai").length, 0, "keine Provider-Calls");
  } finally {
    stub.restore();
  }
});

Deno.test("locale=en: Summary ist englisch", async () => {
  const stub = installFetch();
  try {
    const res = await handleRequest(makeRecipeRequest({ locale: "en" }));
    assertEquals(res.status, 200, "Status");
    const body = await res.json() as JsonRecord;
    assert(
      String(body.reply).startsWith("Recipe idea:"),
      `Summary englisch, war: ${String(body.reply)}`,
    );
  } finally {
    stub.restore();
  }
});
