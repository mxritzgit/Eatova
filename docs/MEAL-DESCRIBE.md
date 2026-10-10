# Describe a meal by text or voice

Status: in implementation on `feat/describe-meal` (2026-10-10). This file is
the contract the implementation follows; update it when a contract changes.

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
- `mealText` is sanitized like `freeTextHint` (control characters removed,
  whitespace collapsed) and must then be 2–500 characters, else 400
  `invalid_meal_text`. `portionHint` and `freeTextHint` are not accepted
  together with `mealText` (400 `ambiguous_input`).
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
- No food in the text → 422 `no_food_in_text`. The photo response stays
  byte-for-byte as today (no new fields on the image path).

## Dart contracts

The files below were created as stubs on the branch; their owners fill them.

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
  `listen` completes with `{text, reason: "final"}`, a dismissed dialog with
  `{text: null, reason: "cancel"}`. No recognizer installed → `unavailable`.
- The Coach keeps its current behavior (mic on iOS only) in this change.

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
