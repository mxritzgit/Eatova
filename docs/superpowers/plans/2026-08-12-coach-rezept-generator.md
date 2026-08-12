# Coach-Rezept-Generator (`/rezept`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/rezept <Wunsch>` im Coach erzeugt Rezept + KI-Bild als Vorschlagskarte; erst die Bestätigung im Sheet speichert es als Eigen-Rezept.

**Architecture:** Neuer `mode: "recipe"`-Zweig in der bestehenden coach-chat Edge Function (1 Quota-Slot, Refund-Pfade wie bisher, Classifier entfällt, Prefilter bleibt). Rezept kommt als geklemmtes JSON von grok-4.3, das Bild von der OpenRouter-Image-API (`POST /api/v1/images`). Client rendert eine ephemere Vorschlagskarte (ChatMessage bekommt ein NUR-lokales `recipeProposal`-Feld) und speichert nach Bestätigung über den bestehenden Pfad `RecipeImageStore.save` + `HomeStore.createUserRecipe`. Die Function erhält KEINE neuen Rechte.

**Tech Stack:** Deno Edge Function (TypeScript), OpenRouter Chat + Image API, Flutter (bestehende Muster: `part of`-Screens, ARB-i18n, EatovaSheet).

## Global Constraints

- Coach darf NIE selbst handeln: Function liefert nur Daten; Speichern ausschließlich clientseitig nach explizitem Tap (Spec §Sicherheits-Grundsatz).
- 1 `/rezept` = 1 Slot der 5 Coach-Tagesfragen (claim_chat_quota vor dem ersten bezahlten Call; refund_chat_quota bei Infra-Fehlern — Muster handler.ts:1046-1065, 1097-1110).
- Bild-Fehler ≠ Rezept-Fehler: Rezept kommt auch ohne Bild zurück.
- KI-Werte werden serverseitig GEKLEMMT (nicht abgelehnt): kcal 1..10000, Gramm 1..10000, Makros 0..1000, Titel ≤160; description ≤600, ingredients/preparation ≤2000 Zeichen.
- Keine Bild-Bytes in `chat_messages`; Historie bekommt nur Text (User-Eingabe + Zusammenfassung).
- Keine hartkodierten deutschen Strings in `lib/src/screens/coach/` (Wächter-Test) — alles über ARB de+en.
- Kein neues Flutter-Package.

## Datei-Landkarte

| Datei | Aufgabe |
|---|---|
| Create `supabase/functions/coach-chat/recipe.ts` | Pure Logik: Prompts, JSON-Parse+Klemmen, Zusammenfassungstext |
| Modify `supabase/functions/coach-chat/handler.ts` | `mode`/`locale` lesen, Recipe-Zweig (Quota, Bild-Call, Persistenz, Response) |
| Create `supabase/functions/coach-chat/recipe_test.ts` | Deno-Tests der puren Logik |
| Modify `supabase/functions/coach-chat/handler_test.ts` | End-to-End-Tests Recipe-Mode (fetch gestubbt) |
| Create `lib/src/models/coach_recipe_proposal.dart` | Proposal-Modell + `toFitnessRecipe` |
| Modify `lib/src/models/chat_message.dart` | lokales Feld `recipeProposal` |
| Modify `lib/src/services/coach_chat_service.dart` | `requestRecipe(...)` + `CoachRecipeReply` |
| Modify `lib/src/screens/coach/coach_chat_screen.dart` | Präfix-Erkennung, `_sendRecipeRequest`, `onCreateRecipe`-Param, Sheet-Handler |
| Create `lib/src/screens/coach/coach_recipe.dart` (`part of`) | `_RecipeProposalCard` + `_RecipeAddSheet` |
| Modify `lib/src/screens/coach/coach_message_list.dart` | Karten-Zweig in `_MessageView` |
| Modify `lib/src/app/eatova_home_page.dart` | `onCreateRecipe: _store.createUserRecipe` verdrahten |
| Modify `lib/l10n/app_de.arb` + `app_en.arb` | neue Coach-Recipe-Keys |
| Create `test/coach_recipe_flow_test.dart` | Flutter-Flow-Tests |

---

### Task 1: Edge Function — recipe.ts (pure Logik) + Deno-Tests

**Files:**
- Create: `supabase/functions/coach-chat/recipe.ts`
- Create: `supabase/functions/coach-chat/recipe_test.ts`

**Interfaces (Produces):**
```ts
export const RECIPE_LIMITS = { kcalMin: 1, kcalMax: 10000, gramsMin: 1, gramsMax: 10000,
  macroMin: 0, macroMax: 1000, titleMaxChars: 160, descriptionMaxChars: 600, longTextMaxChars: 2000 };
export interface RecipeDraft { title: string; description: string; portion: string;
  ingredients: string; preparation: string; calories_kcal: number; protein_g: number;
  carbs_g: number; fat_g: number; estimated_g: number; }
export function recipeSystemPrompt(locale: "de" | "en"): string;      // JSON-Auftrag + __REFUSE__-Regel
export function parseRecipeDraft(raw: string): RecipeDraft | null;    // null = unlesbar (kein title / keine kcal)
export function recipeImagePrompt(draft: RecipeDraft): string;        // Food-Fotografie-Prompt
export function recipeSummary(draft: RecipeDraft, locale: "de" | "en"): string; // Text fuer Historie/Client
```

- [ ] **Step 1:** `recipe_test.ts` schreiben — Fälle: gültiges JSON roundtrippt; kcal 50000→10000, protein -5→0 geklemmt; title >160 gekappt; JSON in Markdown-Fences wird extrahiert; fehlender title ⇒ null; fehlende kcal ⇒ null; `recipeSummary` de/en enthält Titel + kcal.
- [ ] **Step 2:** Test läuft rot (`deno test supabase/functions/coach-chat/recipe_test.ts`).
- [ ] **Step 3:** `recipe.ts` implementieren. Parse-Kern: `raw.match(/\{[\s\S]*\}/)` (Muster classify handler.ts:265), Zahlen defensiv (`Number(...)`, NaN→Min), Klemmen via `Math.min/max`, Strings `String(x ?? '').trim().slice(0, cap)`. Prompt verlangt: EIN Objekt, `ingredients` als "\n- "-Zeilen, `preparation` als "\n1. "-Zeilen, Sprache = locale, kein Essensrezept ⇒ Antwort beginnt `__REFUSE__ `.
- [ ] **Step 4:** Tests grün. **Step 5:** Commit `feat(coach-fn): Rezept-Draft-Logik (Prompt, Parse, Klemmen)`.

### Task 2: Edge Function — handler.ts Recipe-Zweig + Handler-Tests

**Files:**
- Modify: `supabase/functions/coach-chat/handler.ts`
- Modify: `supabase/functions/coach-chat/handler_test.ts` (bzw. neue `handler_recipe_test.ts` im selben Stubbing-Stil)

**Interfaces (Produces — Response-Vertrag für Task 3):**
```jsonc
// 200 Erfolg:
{ "reply": "<summary>", "recipe": { ...RecipeDraft }, "image_base64": "...", "image_mime_type": "image/jpeg",
  "remaining": 3, "daily_limit": 5, "session_id": "<uuid>" }
// 200 Refusal (kein Essensrezept): wie Chat-Refusal { reply, refusal: true, refusal_reason: "model_refusal", ... }
// Fehler: bestehende Codes (429 quota_exceeded, 502/504 + Refund, 413, 401)
```

- [ ] **Step 1:** Request-Parsing ergänzen (nach handler.ts:952): `const isRecipeMode = body?.mode === "recipe"; const locale = body?.locale === "en" ? "en" : "de";`
- [ ] **Step 2:** Konstanten: `const MODEL_IMAGE = Deno.env.get("COACH_IMAGE_MODEL") ?? "google/gemini-3.1-flash-image";` + `PROVIDER_TIMEOUTS_MS.image = 30_000`.
- [ ] **Step 3:** Recipe-Zweig NACH dem Quota-Claim (handler.ts:1065), VOR Layer 2 — `if (isRecipeMode) { ... return }`:
  - Kein Classifier, History wird nicht in den Prompt gegeben (`loadHistory` für Recipe-Mode überspringen: vor E3-Block `const history = isRecipeMode ? [] : await loadHistory(...)`).
  - Draft-Call: wie `answer()` aber messages `[system: recipeSystemPrompt(locale), user: message]`, `response_format: {type:"json_object"}`, `temperature: 0.4`, `max_tokens: 900`, Timeout `PROVIDER_TIMEOUTS_MS.answer`. `__REFUSE__`-Prefix ⇒ Refusal-Pfad (storeMessage user + assistant, touchSession, 200 mit refusal wie handler.ts:1111-1131, reason `model_refusal`).
  - Parse via `parseRecipeDraft`; `null` ⇒ `console.error`, `rpcRefundQuota`, 502 `provider_error` (Muster handler.ts:1165-1183).
  - Bild-Call in eigenem try/catch (tolerant): `POST https://openrouter.ai/api/v1/images`, Body `{model: MODEL_IMAGE, prompt: recipeImagePrompt(draft), aspect_ratio: "4:3", output_format: "jpeg", resolution: "1K", n: 1}`, `AbortSignal.timeout(PROVIDER_TIMEOUTS_MS.image)`; Erfolg ⇒ `data?.data?.[0]?.b64_json` + `media_type`; jeder Fehler ⇒ `image_base64 = null` + console.error (KEIN Refund, Rezept ist da).
  - Persistenz: `storeMessage(user, content: message)` (geprüft + Refund wie handler.ts:1142-1148), `maybeAutoTitle`, `storeMessage(assistant, content: recipeSummary(draft, locale))` best-effort, `touchSession`.
  - Response: siehe Vertrag oben (remaining-Auslassung wie handler.ts:1201).
- [ ] **Step 4:** Handler-Tests (Stubbing-Stil der bestehenden handler_test.ts): (a) Happy Path liefert recipe+reply+image; (b) Bild-Provider 500 ⇒ 200 ohne image_base64; (c) Draft-Provider 500 ⇒ 502 + genau ein Refund-RPC-Call; (d) `__REFUSE__` ⇒ 200 refusal ohne recipe; (e) quota_exceeded ⇒ 429 vor jedem Provider-Call; (f) Prefilter greift auch im Recipe-Mode.
- [ ] **Step 5:** `deno test supabase/functions/coach-chat/` grün. **Step 6:** Commit `feat(coach-fn): mode=recipe — Rezept-JSON + Bild via Image-API, 1 Quota-Slot`.

### Task 3: Client — Proposal-Modell + Service

**Files:**
- Create: `lib/src/models/coach_recipe_proposal.dart`
- Modify: `lib/src/models/chat_message.dart`
- Modify: `lib/src/services/coach_chat_service.dart`
- Test: `test/coach_recipe_flow_test.dart` (Service-Parsing-Teil)

**Interfaces (Produces):**
```dart
class CoachRecipeProposal {
  // Felder: title, description, portion, ingredients, preparation (String);
  // caloriesKcal, proteinG, carbsG, fatG, estimatedGrams (int); imageBytes (Uint8List?)
  static CoachRecipeProposal? fromJson(Map<dynamic, dynamic> json, {Uint8List? imageBytes});
  FitnessRecipe toFitnessRecipe({required String imageAsset}); // slug: FitnessRecipe.userRecipeSlug(),
                                                               // categories: ['Eigene'], userCreated: true,
                                                               // professionalHint: ''
}
// ChatMessage: + final CoachRecipeProposal? recipeProposal;  (nie aus fromRow, wie imageBytes)
// CoachChatService:
Future<CoachRecipeReply> requestRecipe(String wish, {required String sessionId,
    required String locale, String? userContext});
class CoachRecipeReply { final String reply; final bool refusal; final CoachRecipeProposal? proposal;
  final int? remaining; final int? dailyLimit; final String sessionId; }
```

- [ ] **Step 1:** Test: `requestRecipe`-Parsing über einen Fake-FunctionsClient ist unhandlich — stattdessen `CoachRecipeProposal.fromJson`-Unit-Tests (Klemm-frei, 1:1-Übernahme; fehlender title ⇒ null; base64-Bytes werden durchgereicht) + Flow-Test in Task 5 deckt den Rest.
- [ ] **Step 2:** rot laufen lassen, implementieren, grün. `requestRecipe` invoket `coach-chat` mit `{'message': wish, 'mode': 'recipe', 'locale': locale, 'session_id': sessionId, 'user_context'?}` und nutzt DIESELBEN `on Functions*`-Arme wie `send` (Fehler-Mapping `_failureForStatus` wiederverwenden). `image_base64` ⇒ `base64Decode` in try/catch (kaputtes Base64 ⇒ Proposal ohne Bild).
- [ ] **Step 3:** Commit `feat(coach): requestRecipe-Service + Proposal-Modell (nur Daten, keine Rechte)`.

### Task 4: ARB-Keys (de+en) + gen-l10n

**Files:** Modify `lib/l10n/app_de.arb`, `lib/l10n/app_en.arb`

- [ ] **Step 1:** Keys ergänzen (Bereich hinter den coach*-Keys):

| Key | de | en |
|---|---|---|
| coachRecipeEmptyHint | Sag mir, was für ein Rezept du willst — z. B. „/rezept Hühnchenauflauf mit Bild". | Tell me what recipe you want — e.g. "/recipe chicken casserole with a photo". |
| coachRecipeCardEyebrow | REZEPTVORSCHLAG | RECIPE IDEA |
| coachRecipeAddButton | Rezept hinzufügen | Add recipe |
| coachRecipeAddedLabel | Hinzugefügt | Added |
| coachRecipeSheetTitle | Rezept hinzufügen | Add recipe |
| coachRecipeSheetConfirm | Hinzufügen | Add |

  Für kcal/Protein-Zeile, Portion/Zutaten/Zubereitung-Labels und Abbrechen die BESTEHENDEN Keys wiederverwenden (recipesKcalProteinSummary, Detail-Sektions-Keys, commonUndo/cancel — beim Implementieren nachschlagen, KEINE Duplikate anlegen).
- [ ] **Step 2:** `flutter gen-l10n`. **Step 3:** Commit `feat(i18n): Coach-Rezept-Texte de+en`.

### Task 5: Coach-UI — Präfix, Karte, Sheet, Speichern

**Files:**
- Modify: `lib/src/screens/coach/coach_chat_screen.dart`
- Create: `lib/src/screens/coach/coach_recipe.dart` (`part of 'coach_chat_screen.dart'`)
- Modify: `lib/src/screens/coach/coach_message_list.dart`
- Modify: `lib/src/app/eatova_home_page.dart`
- Test: `test/coach_recipe_flow_test.dart`

**Interfaces:**
- Consumes: `CoachChatService.requestRecipe`, `CoachRecipeProposal.toFitnessRecipe`, `RecipeImageStore.instance.save`, `HomeStore.createUserRecipe` (Signatur `Future<SyncDelivery> Function(FitnessRecipe)`).
- Produces: `CoachChatScreen.onCreateRecipe` (`Future<SyncDelivery> Function(FitnessRecipe)?`, null ⇒ Button speichert nicht, Karte trotzdem sichtbar); Widget-Keys `coach-recipe-card`, `coach-recipe-add`, `coach-recipe-sheet`, `coach-recipe-sheet-confirm`.

- [ ] **Step 1 (Test zuerst):** `test/coach_recipe_flow_test.dart` mit Fake-Service (Muster `_FakeCoach` aus coach_design_test.dart, zusätzlich `requestRecipe`-Override + Zähler):
  - `/rezept Auflauf` senden ⇒ genau 1 requestRecipe-Call (kein send-Call), Karte `coach-recipe-card` erscheint mit Titel.
  - `/rezept` ohne Text ⇒ 0 Calls, Fehlerbanner mit coachRecipeEmptyHint.
  - `/recipe casserole` ⇒ requestRecipe mit wish 'casserole'.
  - Tap `coach-recipe-add` ⇒ Sheet; Tap `coach-recipe-sheet-confirm` ⇒ onCreateRecipe genau 1x, FitnessRecipe: slug startsWith 'user_', userCreated true, categories ['Eigene'], title/kcal aus Proposal; Button zeigt coachRecipeAddedLabel und ist disabled.
  - Refusal-Antwort ⇒ normale Textblase, keine Karte.
- [ ] **Step 2:** rot. **Step 3:** implementieren:
  - `_recipeWishFrom(String text)`: `^/(rezept|recipe)(\s+(.*))?$` case-insensitive ⇒ Gruppe 3 getrimmt ('' wenn leer), sonst null.
  - `_send`: ganz oben nach `text`-Bildung: Präfix-Match ⇒ delegiere an `_sendRecipeRequest(wish, displayText: text)` und return.
  - `_sendRecipeRequest`: Spiegel von `_send` (Quota-Guard, optimistische User-Blase mit Originaltext, `_sending`, gleiche catch-Arme) mit `svc.requestRecipe(wish, sessionId:…, locale: l10n.localeName, userContext: widget.userContext)`; Erfolg ⇒ assistant-ChatMessage mit `content: res.reply`, `recipeProposal: res.proposal`, Quota-Update wie in `_send`.
  - `coach_recipe.dart`: `_RecipeProposalCard` (Eyebrow, `Image.memory` 160px `BoxFit.cover` bzw. `ImagePlaceholder`, Titel `AppType.display(18)`, `recipesKcalProteinSummary`, `PrimaryActionButton` bzw. Added-Zustand) + `_RecipeAddSheet` (Scrollbare Vorschau: Bild, Titel, Makro-Zeile, Portion/Zutaten/Zubereitung-Sektionen, Confirm-Button) + `_addProposalToRecipes(ChatMessage msg)` im State: Sheet öffnen ⇒ bei true: `RecipeImageStore.instance.save` (nur wenn Bytes; null-Ergebnis ⇒ imageAsset '' + Foto-Fehler-Snack), `proposal.toFitnessRecipe(imageAsset: …)`, `await widget.onCreateRecipe!(recipe)`, `_addedRecipeMessageIds.add(msg.id)`, Erfolgs-Snack `recipesSavedSuccess(title)` mit `deliveryHint` (Muster recipes_screen.dart:252-281).
  - `_MessageView`: `message.recipeProposal != null` ⇒ Karte statt Text-Inhalt (Blase behält surf-Fläche), `part`-Eintrag in coach_chat_screen.dart ergänzen.
  - `eatova_home_page._coachTab`: `onCreateRecipe: widget.sync == null ? null : _store.createUserRecipe` (Selector-Slice unverändert — der Callback ist stabil).
- [ ] **Step 4:** Tests grün (inkl. bestehender coach_design/hartkodierung/arb_parity). **Step 5:** Commit `feat(coach): /rezept — Vorschlagskarte, Bestätigungs-Sheet, Speichern über Eigen-Rezept-Pfad`.

### Task 6: Verifikation + Deploy + PR

- [ ] **Step 1:** `deno test supabase/functions/coach-chat/` + `flutter analyze` + volle `flutter test`-Suite grün.
- [ ] **Step 2:** Function deployen (Management-API-Weg aus Memory `eatova-i18n`; kein neues Secret nötig — COACH_IMAGE_MODEL hat Code-Default).
- [ ] **Step 3:** Branch pushen, PR mit Spec-Link erstellen, CI abwarten.

## Self-Review (erledigt)

- Spec-Abdeckung: Quota (T2), Klemmen (T1), Bild-tolerant (T2), Historie ohne Bild (T2), Karte+Sheet+Keys (T4/T5), Speicherpfad (T5), Sicherheit (kein neuer Schreibpfad — T2/T5), Fehlerfälle (T2/T5), Tests (T1/T2/T3/T5). `/rezept` ohne Text: T5.
- Typkonsistenz: `RecipeDraft` (snake_case, Server) vs. `CoachRecipeProposal` (camelCase, Client) — Mapping in `fromJson` (T3). `onCreateRecipe`-Signatur == `HomeStore.createUserRecipe`.
