# Favorites photos and lively list Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Favorites keep the product photo they were saved with, and the
favorites list gets photo tiles, one-tap add, macros and sorting.

**Architecture:** The photo URL becomes part of `MealAnalysisResult` and
travels in the existing jsonb payloads (no schema change). The saved-meal row
(`SavedMealHeader`) gets the new layout used by both the favorites sheet and
the add sheet's inline favorites; the favorites sheet gains sort chips fed by
a pure helper over the store's logged meals.

**Tech Stack:** Flutter 3.47.2, Dart, flutter_test; Supabase payloads
unchanged.

**Spec:** `docs/superpowers/specs/2026-10-03-favorites-photos-and-lively-list-design.md`

## Global Constraints

- Flutter `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat` 3.47.2;
  `flutter analyze --no-pub --fatal-infos --fatal-warnings` clean.
- Photo hosts: `https` on `images.openfoodfacts.org` or
  `static.openfoodfacts.org`, no user info, no port, at most 512 characters.
- No migration, no function deploy, no new dependency.
- Strings in `lib/l10n/app_en.arb` and `app_de.arb`, then `flutter gen-l10n`.
- Theme tokens only (`context.t`, `AppType`, `rChip`, `rTile`, `rCard`);
  borderless soft fills; targets at least 44 px; reduced motion respected.
- Comments short and English; existing German test names stay.

## Review Focus

1. A favorite hearted in the barcode-scan sheet: its result comes from
   `lookupBarcode`, so the photo must be set there too (Task 1 test).
2. Cached favorites and diary rows written before this change load without
   error and show the letter tile (Task 1 round-trip test with no key).
3. A synced payload with `http://`, a foreign host, user info or a port
   yields no photo (Task 1).
4. A second tap on "+" while the first add is still saving logs once (Task 4).
5. A photo that fails to load falls back to the letter tile (Task 3; the test
   HTTP client answers 400).

---

### Task 1: `MealAnalysisResult.imageUrl`

**Files:**
- Modify: `lib/src/models/meal_analysis_result.dart` (constructor, field,
  `adjustedToGrams`, `adjustedToItems`, `fromOpenFoodFacts`, new
  `withImageUrl`, new top-level `sanitizeProductImageUrl`)
- Modify: `lib/src/services/meals_sync.dart` (`mealResultToJson`,
  `mealResultFromJson`)
- Modify: `lib/src/services/open_food_facts_product_service.dart`
  (`ProductSearchResult.imageUrl` becomes `result.imageUrl`)
- Test: `test/models/meal_result_image_url_test.dart`

**Interfaces:**
- Produces: `String? MealAnalysisResult.imageUrl`;
  `MealAnalysisResult withImageUrl(String? url)`;
  `String? sanitizeProductImageUrl(Object? raw)`; JSON key `imageUrl`.

- [ ] **Step 1: Failing tests** — sanitizer accepts
  `https://images.openfoodfacts.org/images/products/400/054/000/0108/front_de.273.200.jpg`
  and the `static.` host; rejects `http://images...`, `https://evil.example/x.jpg`,
  `https://user@images.openfoodfacts.org/x.jpg`,
  `https://images.openfoodfacts.org:8443/x.jpg`, 513 characters, `''`, a
  number. `fromOpenFoodFacts` picks `image_front_small_url` over
  `image_small_url` and skips an invalid first candidate.
  `adjustedToGrams(120)` and `adjustedToItems(...)` keep the URL. Round trip
  through `mealResultToJson`/`mealResultFromJson` keeps it; a map without
  the key reads null and writes no key; a tampered `imageUrl` reads null.
  `ProductSearchResult.fromOpenFoodFacts(...).imageUrl` equals
  `result.imageUrl`.
- [ ] **Step 2:** run, expect compile failure.
- [ ] **Step 3:** implement:

```dart
const _productImageHosts = {'images.openfoodfacts.org', 'static.openfoodfacts.org'};

/// A product photo address the app may load, else null.
String? sanitizeProductImageUrl(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  if (text.isEmpty || text.length > 512) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
      uri.hasPort || !_productImageHosts.contains(uri.host)) {
    return null;
  }
  return text;
}
```

  `fromOpenFoodFacts`: first candidate of the four keys that passes the
  sanitizer. `mealResultToJson`: `if (r.imageUrl != null) 'imageUrl': r.imageUrl`.
  `mealResultFromJson`: `imageUrl: sanitizeProductImageUrl(j['imageUrl'])`.
  `withImageUrl` rebuilds the result with every field copied.
- [ ] **Step 4:** run the new test plus `test/services/meal_payload_strict_test.dart`,
  `test/wire_persisted_key_names_test.dart`; adjust only key-list
  expectations that enumerate optional keys.
- [ ] **Step 5:** commit `feat(food): carry the product photo in the meal result`.

### Task 2: Favorites keep and adopt their photo

**Files:**
- Modify: `lib/src/models/favorite_meal.dart` (static
  `MealAnalysisResult keepImage(MealAnalysisResult next, MealAnalysisResult? previous)`)
- Modify: `lib/src/app/home_store_meals.dart` (`toggleFavorite`,
  `addResultToDailyTotal`)
- Modify: `lib/src/widgets/kcal/add_meal_sheet.dart` (`_toggleAndMirror`,
  `_touchFavorite`)
- Test: `test/services/favorite_photo_store_test.dart` (store with the shared
  fake server), plus a case in `test/add_meal_sheet_favorites_inline_test.dart`

**Interfaces:**
- Consumes: Task 1 `imageUrl`, `withImageUrl`.
- Produces: `FavoriteMeal.keepImage`.

- [ ] **Step 1: Failing tests** — hearting a search result with a photo
  stores a favorite whose result has it, and the queued `favoriteUpsert`
  payload carries `imageUrl`; after reloading the cache the photo is still
  there; hearting the same barcode again (unpin, re-pin) with a photo-less
  result keeps the photo; an existing photo-less favorite hearted from a hit
  with a photo gets it; logging a photo-less result for a favorite with a
  photo keeps the photo.
- [ ] **Step 2:** run, expect failures.
- [ ] **Step 3:** implement `keepImage` (`next.imageUrl ?? previous?.imageUrl`
  via `withImageUrl` only when it changes something) and use it where the
  store and the sheet mirror rebuild or flip an entry; the flip path uses
  `old.copyWith(pinned: ..., result: keepImage(incoming, old.result))`
  (extend `copyWith` with `result`).
- [ ] **Step 4:** run new and existing favorites tests
  (`favorites_pinned_sync_test.dart`, `add_sheet_store_truth_test.dart`,
  `fixlauf_c_add_sheet_mirror_test.dart`, `atomic_store_mutations_test.dart`).
- [ ] **Step 5:** commit `feat(food): favorites keep the photo they were saved with`.

### Task 3: Rows read the photo from the result

**Files:**
- Modify: `lib/src/widgets/kcal/meal_suggestion_item.dart` (drop the
  `imageUrl` parameter; headers use `result.imageUrl`)
- Modify: `lib/src/widgets/kcal/add_meal_sheet.dart` (`_suggestionItem`)
- Modify: `lib/src/widgets/kcal/saved_meal_presentation.dart`
  (`MealItemTile` gets `size`; `SavedMealHeader` passes the photo)
- Test: `test/favorites_photo_tile_test.dart`

- [ ] **Step 1: Failing tests** — a pinned favorite, a recent and a
  favorites-sheet row whose result has a photo each render an `Image` with a
  `NetworkImage` of that URL inside the tile; a result without a photo shows
  the letter; after the test client's 400 the letter tile is visible.
- [ ] **Steps 2–4:** run, implement, run.
- [ ] **Step 5:** commit `feat(food): favorites and recents show their product photo`.

### Task 4: The lively saved-meal row with one-tap add

**Files:**
- Modify: `lib/src/widgets/kcal/saved_meal_presentation.dart`
  (`SavedMealHeader`: 48 px tile, line "Brand · 60 g · 212 kcal" with the
  kcal bold, `SavedMealNutrients` below, trailing column heart over a round
  accent `MealQuickAddButton`; `SavedMealCollection` gets `dividerInset`)
- Modify: `lib/src/widgets/kcal/meal_suggestion_item.dart` (pass
  `onQuickAdd: widget.expanded ? null : () => widget.onAdd(widget.result)`
  and `quickAddKey` to `SavedMealHeader`)
- Modify: `lib/src/widgets/kcal/add_meal_sheet.dart`,
  `lib/src/widgets/kcal/favorites_sheet.dart` (quick-add keys
  `favorite-pinned-quick-$i`, `favorites-sheet-quick-$i`; divider inset)
- Modify: `lib/l10n/app_en.arb`, `app_de.arb`:
  `foodFavoriteQuickAdd` "Add {name}, {kcal} kcal, to {slot}" /
  "{name} mit {kcal} kcal zu {slot} hinzufügen"; `foodFavoriteQuickAddUnknown`
  "Add {name} to {slot}" / "{name} zu {slot} hinzufügen".
- Test: `test/favorites_quick_add_test.dart`

**Interfaces:**
- Produces: `MealQuickAddButton({required VoidCallback? onPressed, required String semanticLabel, Key? key})`.

- [ ] **Step 1: Failing tests** — in the favorites sheet "+" calls `onAdd`
  once with the favorite's own result instance and the sheet's slot, shows
  the toast and the tile check; a second tap while the first add is pending
  adds nothing; expanding the row hides the row "+" (the panel's add stays);
  the inline favorite "+" in the add sheet logs into the selected slot; the
  "+" reads "Add Protein bar, 212 kcal, to Lunch"; heart and "+" are at least
  44 px; no overflow at 320 px with 2x text in de and en.
- [ ] **Steps 2–4:** run, implement, `flutter gen-l10n`, run.
- [ ] **Step 5:** commit `feat(food): a livelier favorites row with one-tap add`.

### Task 5: Sorting the favorites sheet

**Files:**
- Modify: `lib/src/services/favorites_view.dart`:
  `enum FavoriteSort { recent, frequent, alphabetical }`,
  `Map<String, int> favoriteUseCounts(Iterable<LoggedMeal> meals, {required DateTime now, int days = 35})`
  (key `FavoriteMeal.idFor(meal.result)`, only `loggedAt` within the window),
  `List<FavoriteMeal> sortFavorites(List<FavoriteMeal> pinnedByRecency, FavoriteSort sort, {Map<String, int> useCounts = const {}, required String Function(FavoriteMeal) nameOf})`
  (frequent: count desc, ties keep recency; alphabetical: case- and
  diacritics-insensitive `nameOf`).
- Modify: `lib/src/widgets/kcal/favorites_sheet.dart` (chips row
  `favorites-sheet-sort-recent|frequent|alphabetical`, compact slot line,
  `AnimatedSwitcher` cross-fade keyed by sort, `useCounts` parameter)
- Modify: `lib/src/widgets/kcal/add_meal_sheet.dart` (`FoodStoreScope`
  optional supplier `favoriteUseCounts`; `AddMealSheet.favoriteUseCounts`;
  passed to `showFavoritesSheet`)
- Modify: `lib/src/app/eatova_home_page.dart` (supplier from
  `_store.loggedMeals` and `clock.now()`)
- Modify: ARB: `foodFavoritesSortRecent` "Recent"/"Zuletzt",
  `foodFavoritesSortFrequent` "Frequent"/"Häufig",
  `foodFavoritesSortAlphabetical` "A–Z"/"A–Z", `foodFavoritesSortLabel`
  "Sort favorites"/"Favoriten sortieren"; drop the use of
  `foodFavoritesSheetSubtitle`.
- Test: `test/services/favorites_view_test.dart` (extend),
  `test/favorites_sheet_test.dart` (extend)

- [ ] **Step 1: Failing tests** — counts ignore meals older than 35 days and
  key by barcode or name; frequent orders by count with recency ties;
  alphabetical treats "Äpfel" next to "Apfel" and ignores case; the chips
  reorder the visible rows and keep the search filter; the selected chip is
  announced as selected.
- [ ] **Steps 2–4:** run, implement, run.
- [ ] **Step 5:** commit `feat(food): sort favorites by recent, frequent or name`.

### Task 6: Privacy, docs, visual check, delivery

- [ ] `PRIVACY.md`: the OpenFoodFacts bullet names the image server and the
  IP address it sees when product photos load.
- [ ] `docs/FAVORITES-DESIGN.md`: short dated section for the lively list and
  photos; handoff section in `docs/PROJECT_HANDOFF.md`.
- [ ] Update `test/design/add_items_polish_capture_test.dart` and
  `add_sheet_polish_capture_test.dart` expectations, render with
  `--dart-define=DARK_REDESIGN_CAPTURE=true`, look at the shots.
- [ ] Strict analysis, full suite with coverage (floor 88 %), mutation
  checks on: host check, keepImage, quick-add single call, frequent order.
- [ ] Fresh reviewer over the whole branch; fix findings.
- [ ] PR, `pr_gate.py wait`, merge after green CI (owner approval given).
