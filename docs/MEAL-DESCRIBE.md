# Describe a meal by text or voice

Status: implemented on `feat/describe-meal` (2026-10-10); see the handoff
for delivery state. This file is the contract the implementation follows;
update it when a contract changes.

## Goal

"Nutella mit einer Scheibe Toast von Lidl" (typed or spoken) becomes a draft
meal the user checks and then adds. The AI only understands the sentence and
estimates amounts; nutrition values come from the product database whenever
a product matches. Nothing is written to the diary before the user taps Add.

## Flow

1. **Entry:** Food → add sheet → entry-method card → "Describe".
2. **Input sheet:** a text field (the keyboard's own dictation works on every
   platform) plus Eatova's mic button where `SpeechInput` is supported. The
   transcript streams into the field (iOS) or arrives at the end (Android
   system dialog). DE/EN dictation language pill as in the Coach. Slot picker
   preselected with the add sheet's slot.
3. **Parse:** `MealDescriber.describe` calls `analyze-meal` in describe mode
   (one short text call, no image). It counts against the same quota as a
   photo scan.
4. **Match:** `MealDescriptionMatcher.match` looks every item up, in this
   order: the user's favorites and recents, then `ProductLookupService
   .searchProducts` (Meilisearch mirror, OFF fallback). The AI estimate is
   always kept as a candidate, so a line never ends up empty.
5. **Draft review:** one line per item with its origin (favorite, product,
   estimate), grams and kcal. Tap a line: other candidates, gram stepper,
   remove. Footer: totals, "Edit" (opens the existing analysis sheet with the
   result) and "Add". The slot hint from the sentence preselects the slot.
6. **Add:** `MealDescriptionDraft.toResult()` builds a `MealAnalysisResult`
   with one `MealComponent` per line and is logged through the add sheet's
   existing `_logAndMirror` path.

## Wire contract: `analyze-meal` describe mode

Request, same endpoint, auth and headers as the photo scan:

```json
{ "mealText": "Nutella mit einer Scheibe Toast von Lidl", "language": "de" }
```

- `mealText` and `imageBase64` are mutually exclusive: both present → 400
  `ambiguous_input`. Neither present → 400 `missing_image` (unchanged, so old
  clients see the same code).
- `mealText` is checked like `freeTextHint`: control and bidi characters are
  rejected, not removed; whitespace is collapsed; the result must be 2–500
  UTF-16 units. Otherwise 400 `invalid_meal_text`. `mealText: null` counts
  as absent. `portionHint` and `freeTextHint` are not accepted together with
  `mealText` (400 `ambiguous_input`).
- Same gate order and scopes as the photo path (IP, user hour, body,
  user day, global) and the same provider budget `analyze_meal`.
- The text is user data, never instructions. It reaches the model as a JSON
  string field, as `foodObservations` does today.

Response 200, same envelope (`result`, `requestId`, `rateLimit`). `result`
carries every field of the photo result plus:

```json
{
  "mode": "describe",
  "slotHint": "breakfast",
  "items": [
    {
      "name": "Nutella",
      "grams": 15, "caloriesKcal": 81, "kcalPer100G": 539,
      "proteinG": 0.9, "carbsG": 8.6, "fatG": 4.6,
      "searchQuery": "Nutella",
      "brand": "Ferrero",
      "amountText": null,
      "gramsSource": "estimated"
    },
    {
      "name": "Toastbrot",
      "grams": 25, "caloriesKcal": 65, "kcalPer100G": 260,
      "proteinG": 2.0, "carbsG": 12.3, "fatG": 1.0,
      "searchQuery": "Toastbrot",
      "brand": "Lidl",
      "amountText": "1 Scheibe",
      "gramsSource": "stated"
    }
  ]
}
```

- `slotHint`: `breakfast | lunch | dinner | snack | null`, only when the
  sentence says so ("zum Frühstück", "heute Abend").
- Item macros are grams for the item's `grams`, one decimal, nullable.
- `searchQuery`: a product search term without amounts (≤ 80 chars).
  `brand`: a brand or store the user named, else null (≤ 60).
  `amountText`: the amount as said, else null (≤ 40).
  `gramsSource`: `stated` when the user gave a weight or a countable unit
  ("1 Scheibe", "2 Eier", "200 g"), else `estimated`.
- No food in the text (an empty `items` array after normalization) → 422
  `no_food_in_text`; an answer without an `items` array is broken → 502
  `provider_unusable_result`. The photo response stays byte-for-byte as
  today (no new fields on the image path).
- The model is told to give a named brand product's manufacturer as `brand`
  ("Nutella" → Ferrero) and to keep named dishes ("Döner") as one item.
- Effort: `ANALYZE_MEAL_DESCRIBE_EFFORT`, default `low`.

## Dart contracts

The feature's Dart entry points:

- `lib/src/models/described_meal.dart`: `DescribedMeal`, `DescribedFoodItem`,
  `DescribedGramsSource`, `DescribedMeal.fromJson` (the `result` object).
- `lib/src/services/meal_describer.dart`: `MealDescriber` and
  `EdgeFunctionMealDescriber` (same HTTP, auth, timeout and exception family
  as `EdgeFunctionMealAnalyzer`; `MealAnalysisException` subclasses).
- `lib/src/services/meal_description_matcher.dart`: `MealDescriptionMatcher`,
  `ProductMealDescriptionMatcher`, `MealDescriptionDraft`, `DraftFoodItem`,
  `DraftCandidate`, `DraftItemOrigin`.
- `lib/src/services/speech_input.dart`: `SpeechInput`, the shared Dart side of
  the `eatova/speech` channel (Coach and meal description).

## Speech

- iOS: the existing `EatovaSpeechPlugin`. `listen` gains two optional
  arguments, `vocabulary` (`gym` default, `food`) and `maxUnits` (default
  1000); old calls behave exactly as before.
- Android: `eatova/speech` via `RecognizerIntent.ACTION_RECOGNIZE_SPEECH`
  (the system recognizer UI). The recognizer app records, so Eatova needs no
  `RECORD_AUDIO`; the manifest keeps removing it. No partial results;
  `listen` completes with `{text, reason: "final"}` (`text: null` when the
  recognizer heard nothing, which the sheet answers with a hint), or a
  dismissed dialog with `{text: null, reason: "cancel"}`, which Dart reads
  as `SpeechEnd.dismissed` and answers with nothing: the user closed it.
  No recognizer installed → `unavailable`.
- Android `stop` and `cancel` leave the dialog alone: it sits in front of
  Flutter, always returns a result, and the app pause it causes must not drop
  speech. A pending `listen` ends with `cancel` only when the app is back in
  front without a result, or the activity goes away. The describe sheet
  therefore cancels on app pause only on iOS. While the Android dialog runs,
  the sheet ignores mic, pill and field taps and disables Send, since the
  dialog's answer is still to come.
- The describe sheet shows the DE/EN pill before listening, because the
  Android dialog covers the app. An iOS stop without an answer within 3 s
  ends the recording and keeps the text shown so far.
- The Coach keeps its current behavior (mic on iOS only) in this change.

## Matching rules

- Candidates per line: a matching favorite or recent, products from
  `searchProducts(searchQuery)` (one retry as `"$brand $searchQuery"` when no
  top hit carries a named brand) and always the AI estimate. At most four.
- A product title fits a line in one of three ways, word by word over the
  search term:
  - **close:** the title names the food: the same word (inflections
    allowed), a cut of it ("Hähnchenbrustfilet" for "Hähnchenbrust"), words
    run together ("Butter Toast" reads as "Buttertoast", "Nuss-Nougat-Creme"
    as "Nussnougatcreme"), or a store's other name for the same food
    ("Toast"/"Toastbrot").
  - **loose:** the food is in doubt: a compound around the word
    ("Buttertoast", "Vollmilch", "Hafermilch", "Milchreis" for "Milch"), or
    a plain word such as "Natur" missing from the title. Listed as an
    alternative, never chosen alone.
  - **none:** another food; dropped. Words under four letters ("Ei") only
    match whole.
- Auto-selection only for a close candidate with a loggable kcal/100 g
  within 2.5× of the estimate; a named brand ranks first, then favorites,
  then title closeness. Everything else stays a listed alternative, close
  titles before loose ones.
- A scan, recipe or manual favorite must name the same food both ways
  ("Toast Hawaii" is not "Toast"); product favorites fit like search hits.
- A stated countable amount ("1 Scheibe") uses the candidate's serving size
  from the product's serving text; a stated weight keeps the AI's grams.
- The draft's source is Open Food Facts with confidence "database" only when
  every line is product-backed; otherwise it is an AI estimate.

## Errors in the app

- `no_food_in_text` and `invalid_meal_text` are a hint under the text field;
  the user edits the sentence.
- Re-auth and quota have describe texts ("meal analyses", no photo).
- A function without describe mode answers `invalid_body` (or
  `missing_image`); the sheet shows "service unavailable", like a 413 or an
  image code, never a photo or connection text. `invalid_hint` falls back
  to the generic failure.
- Everything else reuses the photo scan's mapping
  (`mealAnalysisErrorMessage`).
- Delivery order: deploy `analyze-meal` with describe mode before a client
  with this sheet ships.

## Privacy

The description text goes to Anthropic like a photo scan's text hint; it is
neither logged nor stored by the function. Spoken audio is handled by the
platform recognizer (Apple, or the Android recognizer app), not by Eatova.
Purpose strings and `PRIVACY.md` name the meal description.

## Limits of the first version

- One description is one meal; "morgens Müsli, mittags Döner" is not split.
- The day is the add sheet's day; "gestern" in the sentence is not applied.
- "von Lidl" is a brand hint only: Lidl sells under house brands, so the user
  picks among the candidates.
